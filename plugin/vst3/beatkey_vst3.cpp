/*
 * beatkey_vst3.cpp: Beat Key, VST3 shim (plan step 8).  Host glue only
 * (plan §Q1 default: the generic glue only).
 *
 * Single component: one object is the IComponent + IAudioProcessor, and queryInterface(IEditController)
 * hands out a controller facet that shares the object's reference count.  One parameter, Bypass
 * (kIsBypass).  Audio passes through untouched; analysis is the instance layer's (plugin/shared/bkp.h).
 * The shim knows host types and nothing of the core: it calls bkp_* and nothing else of Beat Key.
 *
 * Component state = "BKV3" | u8 layout (1) | u8 bypass | the instance layer's blob.  The controller's own
 * state is empty.  setState before initialize is fine: the instance exists from the constructor.
 *
 * Threads: process() is the audio thread and calls bkp_process / bkp_set_host_tempo / bkp_set_bypass
 * (and bkp_midi_process) only (no lock, no allocation, no log).  Everything else is the host's main /
 * setup thread.
 *
 * BKP_MIDI=1 builds the MIDI variant (plan step 15) from this same file: Beat Key MIDI, its own class id,
 * plus one event output bus.  After each block the instance layer says which notes changed
 * (bkp_midi_process) and they go into the block's output event list; a host that leaves the bus
 * inactive or gives no list is told so on the face.
 */
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/ivstunits.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include "pluginterfaces/vst/vsttypes.h"
#include "pluginterfaces/gui/iplugview.h"
#include <CoreFoundation/CoreFoundation.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <new>

#include "../shared/bkp.h"
#include "../shared/bkp_view.h"
#include "beatkey_vst3.h"

#ifndef BKP_VERSION
#error "BKP_VERSION is not defined: build with plugin/build.sh"
#endif
#ifndef BKP_MIDI
#define BKP_MIDI 0
#endif

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace Steinberg {
namespace Vst {
DEF_CLASS_IID(IComponent)
DEF_CLASS_IID(IAudioProcessor)
DEF_CLASS_IID(IProcessContextRequirements)
DEF_CLASS_IID(IEditController)
DEF_CLASS_IID(IComponentHandler)
} // namespace Vst
DEF_CLASS_IID(IPlugView)
} // namespace Steinberg

namespace {

#if BKP_MIDI
// Class ID of Beat Key MIDI (fixed forever): "BtKy" "MIDI" "VST3" "FLRc".
const TUID kBeatKeyCid = INLINE_UID(0x42744B79, 0x4D494449, 0x56535433, 0x464C5263);
constexpr const char* kClassName = "Beat Key MIDI";
constexpr const char* kBundleId = "com.jshriver.orion.plugin.midi.vst3";
constexpr const char* kFormat = "VST3-MIDI";
#else
// Class ID of Beat Key (fixed forever): "BtKy" "Anlz" "VST3" "FLRc".
const TUID kBeatKeyCid = INLINE_UID(0x42744B79, 0x416E6C7A, 0x56535433, 0x464C5263);
constexpr const char* kClassName = "Beat Key";
constexpr const char* kBundleId = "com.jshriver.orion.plugin.vst3";
constexpr const char* kFormat = "VST3";
#endif
constexpr const char* kVendor = "Four Letter Records";
constexpr const char* kUrl = "https://fourletterrecords.com";
constexpr const char* kEmail = "contact@fourletterrecords.com";
constexpr const char* kSubCategories = "Fx|Analyzer";
constexpr ParamID kBypassId = 0;
constexpr std::uint8_t kStateTag[4] = { 'B', 'K', 'V', '3' };
constexpr std::size_t kStateHead = 6;
constexpr std::size_t kStateCap = kStateHead + BKP_STATE_CAP;

template <class I>
bool offer(const TUID iid, void** obj, I* self)
{
	if (FUnknownPrivate::iidEqual(iid, I::iid)) {
		self->addRef();
		*obj = self;
		return true;
	}
	return false;
}

void Widen(char16* dst, int cap, const char* src)
{
	int i = 0;
	for (; src[i] && i < cap - 1; i++) {
		dst[i] = static_cast<char16>(static_cast<unsigned char>(src[i]));
	}
	dst[i] = 0;
}

class BeatKeyVst3;

// The controller facet: the Bypass parameter, no state of its own.  Reference counting is the component's.
class Controller final : public IEditController {
public:
	explicit Controller(BeatKeyVst3* owner) : mOwner(owner) {}
	tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override;
	uint32 PLUGIN_API addRef() override;
	uint32 PLUGIN_API release() override;

	tresult PLUGIN_API initialize(FUnknown*) override { return kResultOk; } // the component's initialize did the work
	tresult PLUGIN_API terminate() override { return kResultOk; }
	tresult PLUGIN_API setComponentState(IBStream*) override { return kResultOk; } // same object: already applied
	tresult PLUGIN_API setState(IBStream*) override { return kResultOk; }          // controller state: none
	tresult PLUGIN_API getState(IBStream*) override { return kResultOk; }
	int32 PLUGIN_API getParameterCount() override { return 1; }
	tresult PLUGIN_API getParameterInfo(int32 index, ParameterInfo& info) override
	{
		if (index != 0) {
			return kInvalidArgument;
		}
		std::memset(&info, 0, sizeof info);
		info.id = kBypassId;
		Widen(info.title, 128, "Bypass");
		Widen(info.shortTitle, 128, "Bypass");
		info.stepCount = 1;
		info.defaultNormalizedValue = 0.0;
		info.unitId = kRootUnitId;
		info.flags = ParameterInfo::kCanAutomate | ParameterInfo::kIsBypass;
		return kResultOk;
	}
	tresult PLUGIN_API getParamStringByValue(ParamID id, ParamValue v, String128 out) override
	{
		if (id != kBypassId || !out) {
			return kInvalidArgument;
		}
		Widen(out, 128, v >= 0.5 ? "On" : "Off");
		return kResultOk;
	}
	tresult PLUGIN_API getParamValueByString(ParamID id, TChar* s, ParamValue& v) override
	{
		if (id != kBypassId || !s) {
			return kInvalidArgument;
		}
		v = (s[0] == 'O' && s[1] == 'n' && s[2] == 0) || (s[0] == '1' && s[1] == 0) ? 1.0 : 0.0;
		return kResultOk;
	}
	ParamValue PLUGIN_API normalizedParamToPlain(ParamID, ParamValue v) override { return v; }
	ParamValue PLUGIN_API plainParamToNormalized(ParamID, ParamValue v) override { return v; }
	ParamValue PLUGIN_API getParamNormalized(ParamID id) override;
	tresult PLUGIN_API setParamNormalized(ParamID id, ParamValue v) override;
	tresult PLUGIN_API setComponentHandler(IComponentHandler* handler) override;
	IPlugView* PLUGIN_API createView(FIDString name) override;

private:
	BeatKeyVst3* mOwner;
};

class BeatKeyVst3 final : public IComponent, public IAudioProcessor, public IProcessContextRequirements {
public:
	BeatKeyVst3() : mController(this)
	{
		bkp_config cfg = { kFormat, kBundleId, nullptr, nullptr };
		mInst = bkp_create(&cfg);
		mViewToken = bkp_view_register(mInst);
#if BKP_MIDI
		bkp_view_midi_enable(mInst); // the face's chords; a refusal is logged and the face says no MIDI
#endif
	}
	~BeatKeyVst3()
	{
		if (mHandler) {
			mHandler->release();
		}
		bkp_view_unregister(mViewToken); // before the instance goes: an open view stops reading it
		bkp_destroy(mInst);
	}
	bool Ok() const { return mInst != nullptr; }

	// ---- FUnknown ----
	tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override
	{
		if (FUnknownPrivate::iidEqual(iid, FUnknown::iid)) {
			addRef();
			*obj = static_cast<IComponent*>(this);
			return kResultOk;
		}
		if (offer<IComponent>(iid, obj, this) || offer<IPluginBase>(iid, obj, static_cast<IComponent*>(this)) ||
			offer<IAudioProcessor>(iid, obj, this) || offer<IProcessContextRequirements>(iid, obj, this) ||
			offer<IEditController>(iid, obj, &mController)) {
			return kResultOk;
		}
		*obj = nullptr;
		return kNoInterface;
	}
	uint32 PLUGIN_API addRef() override { return ++mRefs; }
	uint32 PLUGIN_API release() override
	{
		const uint32 n = --mRefs;
		if (n == 0) {
			delete this;
		}
		return n;
	}

	// ---- IPluginBase ----
	// The instance exists from the constructor to the destructor, so state set before initialize or
	// read after terminate is the instance's own; these two have nothing left to do.
	tresult PLUGIN_API initialize(FUnknown*) override { return kResultOk; }
	tresult PLUGIN_API terminate() override { return kResultOk; }

	// ---- IComponent ----
	tresult PLUGIN_API getControllerClassId(TUID) override { return kNotImplemented; } // single component
	tresult PLUGIN_API setIoMode(IoMode) override { return kResultOk; }
	int32 PLUGIN_API getBusCount(MediaType type, BusDirection dir) override
	{
		return type == kAudio ? 1 : (BKP_MIDI && type == kEvent && dir == kOutput) ? 1 : 0;
	}
	tresult PLUGIN_API getBusInfo(MediaType type, BusDirection dir, int32 index, BusInfo& bus) override
	{
#if BKP_MIDI
		if (type == kEvent && dir == kOutput && index == 0) { // the MIDI variant's notes, channel 1
			bus.mediaType = kEvent;
			bus.direction = kOutput;
			bus.channelCount = 1;
			Widen(bus.name, 128, "Beat Key notes");
			bus.busType = kMain;
			bus.flags = BusInfo::kDefaultActive;
			return kResultOk;
		}
#endif
		if (type != kAudio || index != 0) {
			return kInvalidArgument;
		}
		bus.mediaType = kAudio;
		bus.direction = dir;
		bus.channelCount = SpeakerArr::getChannelCount(mArrangement);
		Widen(bus.name, 128, dir == kInput ? "Input" : "Output");
		bus.busType = kMain;
		bus.flags = BusInfo::kDefaultActive;
		return kResultOk;
	}
	tresult PLUGIN_API getRoutingInfo(RoutingInfo&, RoutingInfo&) override { return kNotImplemented; }
	tresult PLUGIN_API activateBus(MediaType type, BusDirection dir, int32 index, TBool state) override
	{
#if BKP_MIDI
		if (type == kEvent && dir == kOutput && index == 0) {
			if (mEventOut.exchange(state ? 1 : 0) != (state ? 1 : 0)) {
				bkp_log(mInst, "VST3 MIDI output bus %s by the host", state ? "activated" : "deactivated");
			}
			return kResultOk;
		}
#else
		(void)dir;
		(void)state;
#endif
		return (type == kAudio && index == 0) ? kResultOk : kInvalidArgument;
	}
	tresult PLUGIN_API setActive(TBool state) override
	{
		if (state && mRate > 0) {
			bkp_prepare(mInst, mRate); // logged inside on any refusal; audio still passes through
		}
		return kResultOk;
	}

	tresult PLUGIN_API setState(IBStream* state) override;
	tresult PLUGIN_API getState(IBStream* state) override;

	// ---- IAudioProcessor: any N in, the same N out ----
	tresult PLUGIN_API setBusArrangements(SpeakerArrangement* inputs, int32 numIns, SpeakerArrangement* outputs, int32 numOuts) override
	{
		if (numIns != 1 || numOuts != 1 || !inputs || !outputs || inputs[0] != outputs[0] ||
			SpeakerArr::getChannelCount(inputs[0]) < 1) {
			return kResultFalse; // the host then asks getBusArrangement and keeps ours
		}
		mArrangement = inputs[0];
		return kResultTrue;
	}
	tresult PLUGIN_API getBusArrangement(BusDirection, int32 index, SpeakerArrangement& arr) override
	{
		if (index != 0) {
			return kInvalidArgument;
		}
		arr = mArrangement;
		return kResultOk;
	}
	tresult PLUGIN_API canProcessSampleSize(int32 size) override { return (size == kSample32 || size == kSample64) ? kResultTrue : kResultFalse; }
	uint32 PLUGIN_API getLatencySamples() override { return 0; }
	tresult PLUGIN_API setupProcessing(ProcessSetup& setup) override
	{
		if (!std::isfinite(setup.sampleRate) || setup.sampleRate <= 0) {
			bkp_log(mInst, "REFUSED: VST3 setupProcessing with sample rate %f", setup.sampleRate);
			return kResultFalse;
		}
		mRate = setup.sampleRate;
		return kResultOk;
	}
	tresult PLUGIN_API setProcessing(TBool) override { return kResultOk; }
	uint32 PLUGIN_API getTailSamples() override { return 0; }
	uint32 PLUGIN_API getProcessContextRequirements() override { return kNeedTempo; }

	// Audio thread: bypass changes, host tempo, then the one audio function.  No lock, no allocation, no log.
	tresult PLUGIN_API process(ProcessData& data) override
	{
		if (IParameterChanges* changes = data.inputParameterChanges) {
			const int32 n = changes->getParameterCount();
			for (int32 i = 0; i < n; i++) {
				IParamValueQueue* q = changes->getParameterData(i);
				if (!q || q->getParameterId() != kBypassId) {
					continue;
				}
				int32 offset = 0;
				ParamValue v = 0;
				const int32 points = q->getPointCount();
				if (points > 0 && q->getPoint(points - 1, offset, v) == kResultOk) {
					mBypass.store(v, std::memory_order_relaxed);
					bkp_set_bypass(mInst, v >= 0.5);
				}
			}
		}
		if (data.processContext && (data.processContext->state & ProcessContext::kTempoValid)) {
			bkp_set_host_tempo(mInst, data.processContext->tempo);
		}
		if (data.numSamples <= 0 || data.numOutputs < 1 || !data.outputs) {
			return kResultOk; // parameter flush or nothing to render
		}
		AudioBusBuffers& o = data.outputs[0];
		const AudioBusBuffers* i = (data.numInputs >= 1 && data.inputs) ? &data.inputs[0] : nullptr;
		const bool f64 = data.symbolicSampleSize == kSample64;
		const void* const* in = i ? (f64 ? reinterpret_cast<const void* const*>(i->channelBuffers64) : reinterpret_cast<const void* const*>(i->channelBuffers32)) : nullptr;
		void* const* out = f64 ? reinterpret_cast<void* const*>(o.channelBuffers64) : reinterpret_cast<void* const*>(o.channelBuffers32);
		bkp_process(mInst, in, i ? i->numChannels : 0, out, o.numChannels, static_cast<uint32_t>(data.numSamples), f64);
		o.silenceFlags = i ? i->silenceFlags : ~static_cast<std::uint64_t>(0);
#if BKP_MIDI
		bkp_midi_event ev[BKP_MIDI_EVENTS];
		const int n = bkp_midi_process(mInst, mEventOut.load(std::memory_order_relaxed) && data.outputEvents, ev);
		for (int k = 0; k < n; k++) {
			Event e{};
			e.busIndex = 0;
			e.sampleOffset = static_cast<int32>(ev[k].offset);
			e.flags = Event::kIsLive;
			if (ev[k].status == 0x90) {
				e.type = Event::kNoteOnEvent;
				e.noteOn = NoteOnEvent{ 0, ev[k].note, 0.f, ev[k].velocity / 127.f, 0, -1 };
			} else {
				e.type = Event::kNoteOffEvent;
				e.noteOff = NoteOffEvent{ 0, ev[k].note, 0.f, -1, 0.f };
			}
			data.outputEvents->addEvent(e);
		}
#endif
		return kResultOk;
	}

	// ---- called by the controller facet ----
	ParamValue Bypass() const { return mBypass.load(std::memory_order_relaxed); }
	void SetBypass(ParamValue v)
	{
		mBypass.store(v, std::memory_order_relaxed);
		bkp_set_bypass(mInst, v >= 0.5);
	}
	void SetHandler(IComponentHandler* h)
	{
		if (h) {
			h->addRef();
		}
		if (mHandler) {
			mHandler->release();
		}
		mHandler = h;
	}
	IPlugView* CreateView(FIDString name)
	{
		if (!name || std::strcmp(name, ViewType::kEditor) != 0) {
			bkp_log(mInst, "VST3 createView: asked for '%s', only 'editor' exists", name ? name : "(null)");
			return nullptr;
		}
		return beatkey_vst3_create_view(mViewToken, mInst);
	}

private:
	Controller mController;
	std::atomic<uint32> mRefs{ 1 };
	bkp_instance* mInst = nullptr;
	std::uint64_t mViewToken = 0;
	double mRate = 0;
	std::atomic<ParamValue> mBypass{ 0.0 };
	IComponentHandler* mHandler = nullptr;
	SpeakerArrangement mArrangement = SpeakerArr::kStereo;
#if BKP_MIDI
	std::atomic<int> mEventOut{ 1 }; // the event output bus (kDefaultActive until the host says otherwise)
#endif
};

tresult PLUGIN_API BeatKeyVst3::getState(IBStream* stream)
{
	if (!stream) {
		bkp_log(mInst, "VST3 getState: the host gave no stream; state not saved");
		return kInvalidArgument;
	}
	std::uint8_t buf[kStateCap];
	std::memcpy(buf, kStateTag, 4);
	buf[4] = 1;
	buf[5] = Bypass() >= 0.5 ? 1 : 0;
	const std::size_t n = bkp_state_save(mInst, buf + kStateHead, BKP_STATE_CAP);
	if (n == 0) {
		return kResultFalse; // logged by the layer
	}
	int32 wrote = 0;
	const int32 len = static_cast<int32>(kStateHead + n);
	if (stream->write(buf, len, &wrote) != kResultOk || wrote != len) {
		bkp_log(mInst, "VST3 getState: the host's stream took %d of %d bytes; state not saved", static_cast<int>(wrote), static_cast<int>(len));
		return kResultFalse;
	}
	return kResultOk;
}

tresult PLUGIN_API BeatKeyVst3::setState(IBStream* stream)
{
	if (!stream) {
		bkp_log(mInst, "VST3 setState: the host gave no stream; saved state ignored");
		return kInvalidArgument;
	}
	std::uint8_t buf[kStateCap + 1];
	std::size_t got = 0;
	while (got < sizeof buf) {
		int32 n = 0;
		if (stream->read(buf + got, static_cast<int32>(sizeof buf - got), &n) != kResultOk || n <= 0) {
			break;
		}
		got += static_cast<std::size_t>(n);
	}
	if (got == 0) {
		return kResultOk; // nothing saved: a fresh instance
	}
	if (got > kStateCap) {
		bkp_log(mInst, "REFUSED: VST3 setState: over %zu bytes; kept what the instance had", kStateCap);
		return kResultFalse;
	}
	if (got < kStateHead || std::memcmp(buf, kStateTag, 4) != 0 || buf[4] != 1 || buf[5] > 1) {
		bkp_log(mInst, "REFUSED: VST3 setState: %zu bytes that are not a Beat Key VST3 state (layout %u); kept what the instance had",
			got, got > 4 ? static_cast<unsigned>(buf[4]) : 0u);
		return kResultFalse;
	}
	char err[256];
	if (bkp_state_load(mInst, buf + kStateHead, got - kStateHead, err, sizeof err) != 0) {
		return kResultFalse; // logged by the layer
	}
	SetBypass(buf[5] ? 1.0 : 0.0);
	return kResultOk;
}

tresult PLUGIN_API Controller::queryInterface(const TUID iid, void** obj) { return mOwner->queryInterface(iid, obj); }
uint32 PLUGIN_API Controller::addRef() { return mOwner->addRef(); }
uint32 PLUGIN_API Controller::release() { return mOwner->release(); }
ParamValue PLUGIN_API Controller::getParamNormalized(ParamID id) { return id == kBypassId ? mOwner->Bypass() : 0.0; }
tresult PLUGIN_API Controller::setParamNormalized(ParamID id, ParamValue v)
{
	if (id != kBypassId || !(v >= 0.0 && v <= 1.0)) {
		return kInvalidArgument;
	}
	mOwner->SetBypass(v);
	return kResultOk;
}
tresult PLUGIN_API Controller::setComponentHandler(IComponentHandler* handler)
{
	mOwner->SetHandler(handler);
	return kResultOk;
}
IPlugView* PLUGIN_API Controller::createView(FIDString name) { return mOwner->CreateView(name); }

// ---- the factory ----
class Factory final : public IPluginFactory3 {
public:
	tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override
	{
		if (FUnknownPrivate::iidEqual(iid, FUnknown::iid)) {
			addRef();
			*obj = static_cast<IPluginFactory*>(this);
			return kResultOk;
		}
		if (offer<IPluginFactory3>(iid, obj, this) || offer<IPluginFactory2>(iid, obj, this) || offer<IPluginFactory>(iid, obj, this)) {
			return kResultOk;
		}
		*obj = nullptr;
		return kNoInterface;
	}
	uint32 PLUGIN_API addRef() override { return ++mRefs; }
	uint32 PLUGIN_API release() override { return --mRefs; } // a process-lifetime singleton: never deleted

	tresult PLUGIN_API getFactoryInfo(PFactoryInfo* info) override
	{
		if (!info) {
			return kInvalidArgument;
		}
		*info = PFactoryInfo(kVendor, kUrl, kEmail, PFactoryInfo::kUnicode);
		return kResultOk;
	}
	int32 PLUGIN_API countClasses() override { return 1; }
	tresult PLUGIN_API getClassInfo(int32 index, PClassInfo* info) override
	{
		if (index != 0 || !info) {
			bk_log("VST3", "factory getClassInfo: bad request (index %d)", static_cast<int>(index));
			return kInvalidArgument;
		}
		*info = PClassInfo(kBeatKeyCid, PClassInfo::kManyInstances, kVstAudioEffectClass, kClassName);
		return kResultOk;
	}
	tresult PLUGIN_API getClassInfo2(int32 index, PClassInfo2* info) override
	{
		if (index != 0 || !info) {
			bk_log("VST3", "factory getClassInfo2: bad request (index %d)", static_cast<int>(index));
			return kInvalidArgument;
		}
		*info = PClassInfo2(kBeatKeyCid, PClassInfo::kManyInstances, kVstAudioEffectClass, kClassName, 0, kSubCategories, kVendor, BKP_VERSION, kVstVersionString);
		return kResultOk;
	}
	tresult PLUGIN_API getClassInfoUnicode(int32 index, PClassInfoW* info) override
	{
		if (index != 0 || !info) {
			bk_log("VST3", "factory getClassInfoUnicode: bad request (index %d)", static_cast<int>(index));
			return kInvalidArgument;
		}
		*info = PClassInfoW(kBeatKeyCid, PClassInfo::kManyInstances, kVstAudioEffectClass, nullptr, 0, kSubCategories, nullptr, nullptr, nullptr);
		Widen(info->name, 64, kClassName);
		Widen(info->vendor, 64, kVendor);
		Widen(info->version, 64, BKP_VERSION);
		Widen(info->sdkVersion, 64, kVstVersionString);
		return kResultOk;
	}
	tresult PLUGIN_API createInstance(FIDString cid, FIDString iid, void** obj) override
	{
		if (!obj) {
			return kInvalidArgument;
		}
		*obj = nullptr;
		if (!cid || !iid || !FUnknownPrivate::iidEqual(cid, kBeatKeyCid)) {
			bk_log("VST3", "factory createInstance: unknown class id");
			return kInvalidArgument;
		}
		FUnknown* inst = beatkey_vst3_create_instance();
		if (!inst) {
			bk_log("VST3", "REFUSED: factory createInstance: could not allocate an instance");
			return kOutOfMemory;
		}
		const tresult r = inst->queryInterface(iid, obj);
		inst->release(); // the host's reference is the one queryInterface added
		if (r != kResultOk) {
			bk_log("VST3", "factory createInstance: the instance does not offer the requested interface (tresult %d)", static_cast<int>(r));
		}
		return r;
	}
	tresult PLUGIN_API setHostContext(FUnknown*) override { return kResultOk; }

private:
	std::atomic<uint32> mRefs{ 1 };
};

Factory gFactory;

} // namespace

FUnknown* beatkey_vst3_create_instance()
{
	auto* p = new (std::nothrow) BeatKeyVst3();
	if (p && !p->Ok()) {
		delete p;
		return nullptr;
	}
	return p ? static_cast<IComponent*>(p) : nullptr;
}

// ---- the three symbols a macOS VST3 module exports ----
extern "C" {
__attribute__((visibility("default"))) IPluginFactory* PLUGIN_API GetPluginFactory()
{
	gFactory.addRef();
	return &gFactory;
}
__attribute__((visibility("default"))) bool bundleEntry(CFBundleRef) { return true; }
__attribute__((visibility("default"))) bool bundleExit() { return true; }
}
