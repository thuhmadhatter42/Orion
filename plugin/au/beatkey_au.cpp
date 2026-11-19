/*
 * beatkey_au.cpp: Beat Key, AUv2 shim on Apple's AudioUnitSDK (plan step 8).  Host glue only.
 *
 * An effect (aufx) that passes audio through untouched; analysis is the instance layer's
 * (plugin/shared/bkp.h).  The shim knows host types and nothing of the core: it calls bkp_* only.
 * State: the instance layer's blob rides in the ClassInfo dictionary under kStateKey.
 *
 * Threads: the constructor, Initialize, SaveState, RestoreState, GetProperty and the destructor run on the
 * host's threads; ProcessBufferLists runs on the audio thread and calls bkp_set_bypass,
 * bkp_set_host_tempo and bkp_process only (no lock, no allocation, no log).
 *
 * BKP_MIDI=1 builds the MIDI variant (plan step 15) from this same file: Beat Key MIDI, a music effect
 * (aumf BtKM FLRc) with the same pass-through and face, plus one MIDI output (kAudioUnitProperty_
 * MIDIOutputCallbackInfo / _MIDIOutputCallback).  After each render the instance layer says which notes
 * changed (bkp_midi_process) and they go to the host's callback; a host that set no callback is told
 * so on the face.
 */
#include <AudioUnitSDK/AUBase.h>
#include <AudioUnitSDK/AUEffectBase.h>
#include <AudioToolbox/AudioUnitProperties.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cstdint>
#ifndef BKP_MIDI
#define BKP_MIDI 0
#endif
#if BKP_MIDI
#include <AudioUnitSDK/AUMIDIEffectBase.h>
#include <CoreMIDI/MIDIServices.h>
#include <atomic>
#endif

#include "../shared/bkp.h"
#include "../shared/bkp_view.h"

#ifndef BKP_VERSION
#error "BKP_VERSION is not defined: build with plugin/build.sh"
#endif
#if BKP_MIDI
#define BEATKEY_AU_BUNDLE_ID "com.jshriver.orion.plugin.midi.au"
#define BEATKEY_AU_FORMAT "AU-MIDI"
#define BEATKEY_AU_VIEW_FACTORY "BeatKeyMIDIAUViewFactory"
#define BEATKEY_AU_CLASS BeatKeyMIDIAU   /* the factory export is <class>Factory: BeatKeyMIDIAUFactory */
using BeatKeyAUBase = ausdk::AUMIDIEffectBase;
#define BEATKEY_AU_FACTORY ausdk::AUMIDIEffectFactory   /* the MIDI selectors (MusicDeviceMIDIEvent) are dispatched */
#else
#define BEATKEY_AU_BUNDLE_ID "com.jshriver.orion.plugin.au"
#define BEATKEY_AU_FORMAT "AU"
#define BEATKEY_AU_VIEW_FACTORY "BeatKeyAUViewFactory"
#define BEATKEY_AU_CLASS BeatKeyAU
using BeatKeyAUBase = ausdk::AUEffectBase;
#define BEATKEY_AU_FACTORY ausdk::AUBaseFactory
#endif
/* Private property: the face's token, read by the Cocoa view factory (beatkey_au_view.m). */
constexpr AudioUnitPropertyID kBeatKeyPropViewToken = 64001;
#define kStateKey CFSTR("beatKeyState")
constexpr UInt32 kMaxChannels = 256;   // pointer arrays on the audio thread's stack

class BEATKEY_AU_CLASS final : public BeatKeyAUBase {
	using Base = BeatKeyAUBase;

public:
	explicit BEATKEY_AU_CLASS(AudioComponentInstance ci) : Base{ ci, true }
	{
		CreateElements();
		bkp_config cfg = { BEATKEY_AU_FORMAT, BEATKEY_AU_BUNDLE_ID, nullptr, nullptr };
		mInst = bkp_create(&cfg);
		mViewToken = bkp_view_register(mInst);
#if BKP_MIDI
		bkp_view_midi_enable(mInst); // the face's chords; a refusal is logged and the face says no MIDI
#endif
	}

	~BEATKEY_AU_CLASS() override
	{
		bkp_view_unregister(mViewToken); // before the instance goes: an open face stops reading it
		bkp_destroy(mInst);
	}

	OSStatus Initialize() override
	{
		const OSStatus st = Base::Initialize();
		if (st != noErr) {
			bkp_log(mInst, "AU Initialize: the SDK refused (OSStatus %d)", static_cast<int>(st));
			return st;
		}
		bkp_prepare(mInst, GetSampleRate()); // a refusal is logged inside; audio still passes through
		return noErr;
	}

	// ---- state: the instance's blob in the ClassInfo dictionary ----
	OSStatus SaveState(CFPropertyListRef* outData) override
	{
		const OSStatus st = Base::SaveState(outData);
		if (st != noErr) {
			bkp_log(mInst, "AU SaveState: base SaveState failed (OSStatus %d)", static_cast<int>(st));
			return st;
		}
		std::uint8_t buf[BKP_STATE_CAP];
		const std::size_t n = bkp_state_save(mInst, buf, sizeof buf);
		if (n == 0) {
			return noErr; // logged by the layer; the host keeps a ClassInfo without our blob (a fresh instance)
		}
		CFDataRef data = CFDataCreate(nullptr, buf, static_cast<CFIndex>(n));
		if (!data) {
			bkp_log(mInst, "AU SaveState: could not make the state data (%zu bytes); saved without it", n);
			return noErr;
		}
		CFDictionarySetValue(const_cast<CFMutableDictionaryRef>(static_cast<CFDictionaryRef>(*outData)), kStateKey, data);
		CFRelease(data);
		return noErr;
	}

	OSStatus RestoreState(CFPropertyListRef plist) override
	{
		const OSStatus st = Base::RestoreState(plist);
		if (st != noErr) {
			bkp_log(mInst, "AU RestoreState: base RestoreState refused the ClassInfo (OSStatus %d)", static_cast<int>(st));
			return st;
		}
		const void* v = CFDictionaryGetValue(static_cast<CFDictionaryRef>(plist), kStateKey);
		if (!v) {
			return noErr; // a ClassInfo without our blob (a preset saved before any state): nothing to restore
		}
		if (CFGetTypeID(v) != CFDataGetTypeID()) {
			bkp_log(mInst, "REFUSED: AU RestoreState: %s is not data; kept what the instance had", "beatKeyState");
			return kAudioUnitErr_InvalidPropertyValue;
		}
		CFDataRef d = static_cast<CFDataRef>(v);
		char err[256];
		if (bkp_state_load(mInst, CFDataGetBytePtr(d), static_cast<size_t>(CFDataGetLength(d)), err, sizeof err) != 0) {
			return kAudioUnitErr_InvalidPropertyValue; // logged by the layer; the instance is unchanged
		}
		return noErr;
	}

	// ---- the face ----
	OSStatus GetPropertyInfo(AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement,
		UInt32& outDataSize, bool& outWritable) override
	{
		if (inScope == kAudioUnitScope_Global && inID == kAudioUnitProperty_CocoaUI) {
			outDataSize = sizeof(AudioUnitCocoaViewInfo);
			outWritable = false;
			return noErr;
		}
		if (inScope == kAudioUnitScope_Global && inID == kBeatKeyPropViewToken) {
			outDataSize = sizeof(std::uint64_t);
			outWritable = false;
			return noErr;
		}
#if BKP_MIDI
		if (inScope == kAudioUnitScope_Global && inID == kAudioUnitProperty_MIDIOutputCallbackInfo) {
			outDataSize = sizeof(CFArrayRef);
			outWritable = false;
			return noErr;
		}
		if (inScope == kAudioUnitScope_Global && inID == kAudioUnitProperty_MIDIOutputCallback) {
			outDataSize = sizeof(AUMIDIOutputCallbackStruct);
			outWritable = true;
			return noErr;
		}
#endif
		return Base::GetPropertyInfo(inID, inScope, inElement, outDataSize, outWritable);
	}

	OSStatus GetProperty(AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement,
		void* outData) override
	{
		if (inScope == kAudioUnitScope_Global && inID == kAudioUnitProperty_CocoaUI) {
			CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR(BEATKEY_AU_BUNDLE_ID));
			if (!bundle) {
				bkp_log(mInst, "AU CocoaUI: bundle %s is not loaded; no face", BEATKEY_AU_BUNDLE_ID);
				return kAudioUnitErr_InvalidProperty;
			}
			CFURLRef url = CFBundleCopyBundleURL(bundle); // ownership passes to the host with the struct
			if (!url) {
				bkp_log(mInst, "AU CocoaUI: bundle has no URL; no face");
				return kAudioUnitErr_InvalidProperty;
			}
			auto* info = static_cast<AudioUnitCocoaViewInfo*>(outData);
			info->mCocoaAUViewBundleLocation = url;
			info->mCocoaAUViewClass[0] = CFSTR(BEATKEY_AU_VIEW_FACTORY);
			return noErr;
		}
		if (inScope == kAudioUnitScope_Global && inID == kBeatKeyPropViewToken) {
			*static_cast<std::uint64_t*>(outData) = mViewToken;
			return noErr;
		}
#if BKP_MIDI
		if (inScope == kAudioUnitScope_Global && inID == kAudioUnitProperty_MIDIOutputCallbackInfo) {
			// one MIDI output; the host owns (releases) the array
			CFStringRef name = CFSTR("Beat Key notes");
			*static_cast<CFArrayRef*>(outData) = CFArrayCreate(nullptr, reinterpret_cast<const void**>(&name), 1, &kCFTypeArrayCallBacks);
			return noErr;
		}
#endif
		return Base::GetProperty(inID, inScope, inElement, outData);
	}

#if BKP_MIDI
	// The host hands over its MIDI output callback (or a NULL one to stop).  Host thread; the audio
	// thread reads the pair through the atomics (user data first, callback last).
	OSStatus SetProperty(AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement,
		const void* inData, UInt32 inDataSize) override
	{
		if (inScope == kAudioUnitScope_Global && inID == kAudioUnitProperty_MIDIOutputCallback) {
			if (!inData || inDataSize < sizeof(AUMIDIOutputCallbackStruct)) {
				bkp_log(mInst, "REFUSED: AU MIDI output callback: %u bytes, want %zu", static_cast<unsigned>(inDataSize),
					sizeof(AUMIDIOutputCallbackStruct));
				return kAudioUnitErr_InvalidPropertyValue;
			}
			const auto* cb = static_cast<const AUMIDIOutputCallbackStruct*>(inData);
			mMidiCallback.store(nullptr, std::memory_order_release);
			mMidiUserData.store(cb->userData, std::memory_order_release);
			mMidiCallback.store(cb->midiOutputCallback, std::memory_order_release);
			bkp_log(mInst, "AU MIDI output: the host %s", cb->midiOutputCallback ? "set its callback (it takes MIDI)" : "cleared its callback");
			return noErr;
		}
		return Base::SetProperty(inID, inScope, inElement, inData, inDataSize);
	}

	// Audio thread: the block as usual, then the notes that changed to the host's callback.
	OSStatus Render(AudioUnitRenderActionFlags& ioActionFlags, const AudioTimeStamp& inTimeStamp, UInt32 nFrames) noexcept
		AUSDK_RTSAFE override
	{
		const OSStatus st = Base::Render(ioActionFlags, inTimeStamp, nFrames);
		const AUMIDIOutputCallback cb = mMidiCallback.load(std::memory_order_acquire);
		void* const user = mMidiUserData.load(std::memory_order_acquire);
		bkp_midi_event ev[BKP_MIDI_EVENTS];
		const int n = bkp_midi_process(mInst, cb != nullptr, ev);
		if (n > 0 && cb) {
			alignas(8) Byte buf[sizeof(MIDIPacketList) + BKP_MIDI_EVENTS * (sizeof(MIDIPacket) + 4)];
			auto* list = reinterpret_cast<MIDIPacketList*>(buf);
			MIDIPacket* pkt = MIDIPacketListInit(list);
			for (int i = 0; i < n && pkt; i++) {
				const Byte msg[3] = { ev[i].status, ev[i].note, ev[i].velocity };
				pkt = MIDIPacketListAdd(list, sizeof buf, pkt, ev[i].offset, 3, msg);
			}
			cb(user, &inTimeStamp, 0, list);
		}
		return st;
	}
#endif

	// ---- any N in, the same N out ----
	UInt32 SupportedNumChannels(const AUChannelInfo** outInfo) override
	{
		static const AUChannelInfo kInfo[] = { { -1, -1 } };
		if (outInfo) {
			*outInfo = kInfo;
		}
		return 1;
	}

	// ---- audio thread: bypass flag, host tempo, then the one audio function ----
	OSStatus ProcessBufferLists(AudioUnitRenderActionFlags& /*ioActionFlags*/, const AudioBufferList& inBuffer,
		AudioBufferList& outBuffer, UInt32 inFramesToProcess) noexcept AUSDK_RTSAFE override
	{
		bkp_set_bypass(mInst, IsBypassEffect());
		Float64 beat = 0, tempo = 0;
		if (CallHostBeatAndTempo(&beat, &tempo) == noErr) {
			bkp_set_host_tempo(mInst, tempo);
		}
		const void* in[kMaxChannels];
		void* out[kMaxChannels];
		UInt32 nIn = inBuffer.mNumberBuffers < kMaxChannels ? inBuffer.mNumberBuffers : kMaxChannels;
		UInt32 nOut = outBuffer.mNumberBuffers < kMaxChannels ? outBuffer.mNumberBuffers : kMaxChannels;
		bool deinterleaved = true;
		for (UInt32 c = 0; c < nIn; c++) {
			in[c] = inBuffer.mBuffers[c].mData;
			deinterleaved = deinterleaved && inBuffer.mBuffers[c].mNumberChannels == 1;
		}
		for (UInt32 c = 0; c < nOut; c++) {
			out[c] = outBuffer.mBuffers[c].mData;
			deinterleaved = deinterleaved && outBuffer.mBuffers[c].mNumberChannels == 1;
		}
		if (!deinterleaved) {
			// not the SDK's canonical format: copy what is there, and the analyzer hears nothing
			for (UInt32 c = 0; c < nOut; c++) {
				const AudioBuffer& o = outBuffer.mBuffers[c];
				if (c < nIn && inBuffer.mBuffers[c].mData && o.mData && inBuffer.mBuffers[c].mData != o.mData) {
					const UInt32 n = inBuffer.mBuffers[c].mDataByteSize < o.mDataByteSize ? inBuffer.mBuffers[c].mDataByteSize : o.mDataByteSize;
					__builtin_memmove(o.mData, inBuffer.mBuffers[c].mData, n);
				}
			}
			return noErr;
		}
		bkp_process(mInst, in, static_cast<int>(nIn), out, static_cast<int>(nOut), inFramesToProcess, 0);
		return noErr;
	}

	// Bypass and processing are the same identity copy (the analyzer hears nothing while bypassed).
	// The SDK's own bypass path copies nothing when "processes in place" is on but the host supplied its
	// own output buffers; routing bypass through ProcessBufferLists makes the output right in every case.
	bool ShouldBypassEffect() noexcept AUSDK_RTSAFE override { return false; }
	bool CanScheduleParameters() const noexcept AUSDK_RTSAFE override { return false; }
	// No tail and no latency: a pass-through.  Saying so (tail 0) answers auval's recommended property.
	bool SupportsTail() noexcept AUSDK_RTSAFE override { return true; }

private:
	bkp_instance* mInst = nullptr;
	std::uint64_t mViewToken = 0;
#if BKP_MIDI
	std::atomic<AUMIDIOutputCallback> mMidiCallback{ nullptr };
	std::atomic<void*> mMidiUserData{ nullptr };
#endif
};

// Defines and exports BeatKeyAUFactory (BeatKeyMIDIAUFactory for the MIDI variant), the factoryFunction
// the Info.plist names (the only export).  The extra macro level expands BEATKEY_AU_CLASS before ## pastes it.
#define BEATKEY_AU_ENTRY(F, C) AUSDK_COMPONENT_ENTRY(F, C)
BEATKEY_AU_ENTRY(BEATKEY_AU_FACTORY, BEATKEY_AU_CLASS)
