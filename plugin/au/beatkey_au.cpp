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
 */
#include <AudioUnitSDK/AUBase.h>
#include <AudioUnitSDK/AUEffectBase.h>
#include <AudioToolbox/AudioUnitProperties.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cstdint>

#include "../shared/bkp.h"
#include "../shared/bkp_view.h"

#ifndef BKP_VERSION
#error "BKP_VERSION is not defined: build with plugin/build.sh"
#endif
#define BEATKEY_AU_BUNDLE_ID "com.jshriver.orion.plugin.au"
/* Private property: the face's token, read by the Cocoa view factory (beatkey_au_view.m). */
constexpr AudioUnitPropertyID kBeatKeyPropViewToken = 64001;
#define kStateKey CFSTR("beatKeyState")
constexpr UInt32 kMaxChannels = 256;   // pointer arrays on the audio thread's stack

class BeatKeyAU final : public ausdk::AUEffectBase {
	using Base = ausdk::AUEffectBase;

public:
	explicit BeatKeyAU(AudioComponentInstance ci) : Base{ ci, true }
	{
		CreateElements();
		bkp_config cfg = { "AU", BEATKEY_AU_BUNDLE_ID, nullptr, nullptr };
		mInst = bkp_create(&cfg);
		mViewToken = bkp_view_register(mInst);
	}

	~BeatKeyAU() override
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
			info->mCocoaAUViewClass[0] = CFSTR("BeatKeyAUViewFactory");
			return noErr;
		}
		if (inScope == kAudioUnitScope_Global && inID == kBeatKeyPropViewToken) {
			*static_cast<std::uint64_t*>(outData) = mViewToken;
			return noErr;
		}
		return Base::GetProperty(inID, inScope, inElement, outData);
	}

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
};

// Defines and exports BeatKeyAUFactory, the factoryFunction the Info.plist names (the only export).
AUSDK_COMPONENT_ENTRY(ausdk::AUBaseFactory, BeatKeyAU)
