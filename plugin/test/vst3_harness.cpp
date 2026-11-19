/*
 * vst3_harness.cpp: the VST3 shim driven directly, no host, no bundle (plan step 8).  Run by plugin/test.sh
 * on both slices.
 *   - the factory: one class, our class id, createInstance gives IComponent / IAudioProcessor / IEditController
 *   - the real process() (float and double, bypass parameter change, process context tempo) under the
 *     core's tripwire: 0 allocations, 0 locks
 *   - the Bypass parameter (kIsBypass, one step) and its normalized value
 *   - component state round-trips byte for byte, carries bypass; garbage / a wrong tag / over the cap are
 *     refused and leave the instance as it was
 *   - built with BKP_MIDI=1 (plan step 15, Beat Key MIDI): its own class, the event output bus, and the
 *     notes in process(): a pinned key's chord (the face's table) as note-ons, note-offs on bypass, the
 *     chord again after it, nothing into an inactive bus or a missing list; all under the tripwire
 * Usage: BEATKEY_LOG_DIR=<scratch> vst3_harness <weights.bkw>
 * No bundle is loaded, so the harness loads the weights itself first (as the shim's bundle lookup would).
 */
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "../shared/bkp.h"
#include "../shared/bkp_view.h"
#include "../vst3/beatkey_vst3.h"

#ifndef BKP_MIDI
#define BKP_MIDI 0
#endif

using namespace Steinberg;
using namespace Steinberg::Vst;

extern "C" {
void tw_arm(void);
void tw_disarm(void);
long tw_mallocs(void);
long tw_locks(void);
IPluginFactory* PLUGIN_API GetPluginFactory();
}

namespace {

int g_failed = 0, g_checks = 0;
#define CHECK(cond, ...)                                             \
	do {                                                             \
		g_checks++;                                                  \
		if (!(cond)) {                                               \
			g_failed++;                                              \
			printf("  FAIL %s:%d: %s: ", __FILE__, __LINE__, #cond); \
			printf(__VA_ARGS__);                                     \
			printf("\n");                                            \
		}                                                            \
	} while (0)

// A plain memory IBStream.
class Mem final : public IBStream {
public:
	std::vector<uint8_t> b;
	size_t at = 0;
	tresult PLUGIN_API queryInterface(const TUID, void** obj) override { *obj = nullptr; return kNoInterface; }
	uint32 PLUGIN_API addRef() override { return 1; }
	uint32 PLUGIN_API release() override { return 1; }
	tresult PLUGIN_API read(void* buf, int32 n, int32* got) override
	{
		const size_t k = std::min(static_cast<size_t>(n), b.size() - at);
		std::memcpy(buf, b.data() + at, k);
		at += k;
		if (got) *got = static_cast<int32>(k);
		return kResultOk;
	}
	tresult PLUGIN_API write(void* buf, int32 n, int32* wrote) override
	{
		b.insert(b.end(), static_cast<uint8_t*>(buf), static_cast<uint8_t*>(buf) + n);
		if (wrote) *wrote = n;
		return kResultOk;
	}
	tresult PLUGIN_API seek(int64 pos, int32 mode, int64* result) override
	{
		at = mode == kIBSeekSet ? static_cast<size_t>(pos) : mode == kIBSeekEnd ? b.size() + static_cast<size_t>(pos) : at + static_cast<size_t>(pos);
		if (result) *result = static_cast<int64>(at);
		return kResultOk;
	}
	tresult PLUGIN_API tell(int64* pos) override { if (pos) *pos = static_cast<int64>(at); return kResultOk; }
};

// One parameter queue holding one point: the bypass change a host sends inside process().
class OneQueue final : public IParamValueQueue {
public:
	ParamValue v = 0;
	tresult PLUGIN_API queryInterface(const TUID, void** obj) override { *obj = nullptr; return kNoInterface; }
	uint32 PLUGIN_API addRef() override { return 1; }
	uint32 PLUGIN_API release() override { return 1; }
	ParamID PLUGIN_API getParameterId() override { return 0; }
	int32 PLUGIN_API getPointCount() override { return 1; }
	tresult PLUGIN_API getPoint(int32 i, int32& off, ParamValue& val) override { if (i != 0) return kInvalidArgument; off = 0; val = v; return kResultOk; }
	tresult PLUGIN_API addPoint(int32, ParamValue, int32&) override { return kResultFalse; }
};
class Changes final : public IParameterChanges {
public:
	OneQueue q;
	bool on = false;
	tresult PLUGIN_API queryInterface(const TUID, void** obj) override { *obj = nullptr; return kNoInterface; }
	uint32 PLUGIN_API addRef() override { return 1; }
	uint32 PLUGIN_API release() override { return 1; }
	int32 PLUGIN_API getParameterCount() override { return on ? 1 : 0; }
	IParamValueQueue* PLUGIN_API getParameterData(int32 i) override { return on && i == 0 ? &q : nullptr; }
	IParamValueQueue* PLUGIN_API addParameterData(const ParamID&, int32&) override { return nullptr; }
};

// The block's output event list: a fixed array, so adding never allocates (the tripwire watches it).
class Events final : public IEventList {
public:
	Event e[64];
	int n = 0;
	tresult PLUGIN_API queryInterface(const TUID, void** obj) override { *obj = nullptr; return kNoInterface; }
	uint32 PLUGIN_API addRef() override { return 1; }
	uint32 PLUGIN_API release() override { return 1; }
	int32 PLUGIN_API getEventCount() override { return n; }
	tresult PLUGIN_API getEvent(int32 i, Event& out) override { if (i < 0 || i >= n) return kInvalidArgument; out = e[i]; return kResultOk; }
	tresult PLUGIN_API addEvent(Event& in) override { if (n >= 64) return kResultFalse; e[n++] = in; return kResultOk; }
};

template <class I>
I* ask(FUnknown* u, const TUID iid)
{
	void* p = nullptr;
	return u->queryInterface(iid, &p) == kResultOk ? static_cast<I*>(p) : nullptr;
}

} // namespace

int main(int argc, char** argv)
{
	if (argc < 2 || !getenv("BEATKEY_LOG_DIR")) {
		fprintf(stderr, "usage: BEATKEY_LOG_DIR=<scratch> vst3_harness <weights.bkw>\n");
		return 2;
	}
	char err[256];
	// the shim asks for its bundle's weights; no bundle is loaded here, so load them the way the bundle would
	if (bk_load_weights(argv[1], err, sizeof err) != BK_OK) {
		fprintf(stderr, "weights: %s\n", err);
		return 2;
	}

	printf("== factory\n");
	IPluginFactory* f = GetPluginFactory();
	CHECK(f && f->countClasses() == 1, "class count");
	PClassInfo ci;
	CHECK(f->getClassInfo(0, &ci) == kResultOk && std::strcmp(ci.name, BKP_MIDI ? "Beat Key MIDI" : "Beat Key") == 0 &&
			std::strcmp(ci.category, kVstAudioEffectClass) == 0, "class info");
	static const uint8_t kMidiCid[16] = { 0x42, 0x74, 0x4B, 0x79, 0x4D, 0x49, 0x44, 0x49, 0x56, 0x53, 0x54, 0x33, 0x46, 0x4C, 0x52, 0x63 };
	CHECK((std::memcmp(ci.cid, kMidiCid, 16) == 0) == (BKP_MIDI != 0), "the class id is not this variant's");
	CHECK(f->getClassInfo(1, &ci) == kInvalidArgument, "index 1 accepted");
	void* obj = nullptr;
	CHECK(f->createInstance(ci.cid, IComponent::iid, &obj) == kResultOk && obj, "createInstance");
	auto* comp = static_cast<IComponent*>(obj);
	auto* proc = ask<IAudioProcessor>(comp, IAudioProcessor::iid);
	auto* ctl = ask<IEditController>(comp, IEditController::iid);
	CHECK(proc && ctl, "interfaces");
	TUID junk = {};
	CHECK(f->createInstance(junk, IComponent::iid, &obj) == kInvalidArgument && !obj, "unknown class created");

	printf("== parameter\n");
	ParameterInfo pi;
	CHECK(ctl->getParameterCount() == 1 && ctl->getParameterInfo(0, pi) == kResultOk, "one parameter");
	CHECK((pi.flags & ParameterInfo::kIsBypass) && pi.stepCount == 1 && pi.id == 0, "bypass flags %d steps %d", pi.flags, pi.stepCount);
	CHECK(ctl->getParamNormalized(0) == 0.0, "bypass starts off");

#if BKP_MIDI
	printf("== the MIDI variant: buses, and a pinned key through state\n");
	CHECK(comp->getBusCount(kEvent, kOutput) == 1 && comp->getBusCount(kEvent, kInput) == 0, "event buses");
	BusInfo eb = {};
	CHECK(comp->getBusInfo(kEvent, kOutput, 0, eb) == kResultOk && eb.mediaType == kEvent && eb.channelCount == 1 &&
			(eb.flags & BusInfo::kDefaultActive), "event output bus info");
	CHECK(comp->getBusInfo(kEvent, kOutput, 1, eb) == kInvalidArgument, "a second event bus");
	CHECK(comp->activateBus(kEvent, kOutput, 0, true) == kResultOk, "activate the event bus");
	// the face's table: what the notes must be (the app's Harmony, through bkp_face_midi_chords)
	uint8_t table[BKP_MIDI_KEYS][BKP_MIDI_NOTES] = {};
	int vel = 0;
	const int per = bkp_face_midi_chords(table, &vel);
	const int am = bk_key_index("Am");
	CHECK(per == 3 && vel == 96 && table[am][0] == 57 && table[am][1] == 60 && table[am][2] == 64, "Am chord %d %d %d (%d a chord, velocity %d)",
		table[am][0], table[am][1], table[am][2], per, vel);
	{
		// a session that pinned Am: a layer blob with the pin, in the shim's state wrapper
		bkp_config bc = { "TEST", nullptr, argv[1], "harness" };
		bkp_instance* donor = bkp_create(&bc);
		bkp_set_pin(donor, "Am");
		Mem pinned;
		uint8_t head[6] = { 'B', 'K', 'V', '3', 1, 0 };
		uint8_t blob[BKP_STATE_CAP];
		const size_t bn = bkp_state_save(donor, blob, sizeof blob);
		bkp_destroy(donor);
		pinned.b.assign(head, head + 6);
		pinned.b.insert(pinned.b.end(), blob, blob + bn);
		CHECK(bn > 0 && comp->setState(&pinned) == kResultOk, "pinned state refused");
	}
	Events events;
	int ons = 0, offs = 0, onsAfter = 0, during = 0, inactive = 0;
	bool pitchesOk = true;
#endif
	printf("== process under the tripwire\n");
	CHECK(comp->initialize(nullptr) == kResultOk, "initialize");
	ProcessSetup setup = { kRealtime, kSample32, 1024, 48000.0 };
	CHECK(proc->setupProcessing(setup) == kResultOk, "setupProcessing");
	CHECK(comp->setActive(true) == kResultOk && proc->setProcessing(true) == kResultOk, "activate");
	std::vector<float> l(1024), r(1024), ol(1024), or_(1024);
	std::vector<double> dl(1024), dr(1024), odl(1024), odr(1024);
	for (int i = 0; i < 1024; i++) {
		l[static_cast<size_t>(i)] = r[static_cast<size_t>(i)] = static_cast<float>(0.3 * std::sin(i * 0.05));
		dl[static_cast<size_t>(i)] = dr[static_cast<size_t>(i)] = 0.3 * std::sin(i * 0.05);
	}
	Changes changes;
	ProcessContext ctx = {};
	ctx.state = ProcessContext::kTempoValid;
	ctx.tempo = 141.98;
	long mallocs = 0, locks = 0;
	bool same = true;
	for (int block = 0; block < 400; block++) {
		const bool f64 = block >= 200;
		float* in32[2] = { l.data(), r.data() };
		float* out32[2] = { ol.data(), or_.data() };
		double* in64[2] = { dl.data(), dr.data() };
		double* out64[2] = { odl.data(), odr.data() };
		AudioBusBuffers in = {}, out = {};
		in.numChannels = out.numChannels = 2;
		if (f64) { in.channelBuffers64 = in64; out.channelBuffers64 = out64; }
		else { in.channelBuffers32 = in32; out.channelBuffers32 = out32; }
		ProcessData d = {};
		d.processMode = kRealtime;
		d.symbolicSampleSize = f64 ? kSample64 : kSample32;
		d.numSamples = 1024;
		d.numInputs = d.numOutputs = 1;
		d.inputs = &in;
		d.outputs = &out;
		changes.on = block == 100 || block == 150;
		changes.q.v = block == 100 ? 1.0 : 0.0;
		d.inputParameterChanges = &changes;
		d.processContext = &ctx;
#if BKP_MIDI
		events.n = 0;
		d.outputEvents = (block >= 300 && block < 320) ? nullptr : &events;   // a host with no list for a while
		if (block == 340) comp->activateBus(kEvent, kOutput, 0, false);        // then one that turns the bus off
		if (block == 360) comp->activateBus(kEvent, kOutput, 0, true);
#endif
		tw_arm();
		const tresult pr = proc->process(d);
		tw_disarm();
		mallocs += tw_mallocs();
		locks += tw_locks();
#if BKP_MIDI
		for (int k = 0; k < events.n; k++) {
			const Event& e = events.e[k];
			if (e.type == Event::kNoteOnEvent) {
				pitchesOk = pitchesOk && e.noteOn.channel == 0 && std::fabs(e.noteOn.velocity - 96 / 127.f) < 1e-6f &&
					(e.noteOn.pitch == table[am][0] || e.noteOn.pitch == table[am][1] || e.noteOn.pitch == table[am][2]);
				(block < 100 ? ons : onsAfter)++;
			} else if (e.type == Event::kNoteOffEvent) {
				offs++;
			}
			if (block > 100 && block < 150) during++;
			if (block > 340 && block < 360) inactive++;
		}
#endif
		CHECK(pr == kResultOk, "process block %d", block);
		same = same && (f64 ? std::memcmp(odl.data(), dl.data(), 8192) == 0 : std::memcmp(ol.data(), l.data(), 4096) == 0);
		if (block == 120) CHECK(ctl->getParamNormalized(0) == 1.0, "bypass change in process not seen by the controller");
	}
#if BKP_MIDI
	// the chord at the start, off on bypass (block 100), on again after (150), again after the missing list
	// (300-319: nothing held, so it starts at 320) and after the bus came back (360)
	CHECK(ons == 3, "%d note-ons before bypass, want the 3 of Am", ons);
	CHECK(pitchesOk, "a note that is not Am's chord, or not channel 1 at velocity 96");
	CHECK(during == 0, "%d events while bypassed after the note-offs", during);
	CHECK(offs >= 3, "%d note-offs (bypass must end the chord)", offs);
	CHECK(onsAfter == 9, "%d note-ons after bypass, want 3 + 3 (list back) + 3 (bus back)", onsAfter);
	CHECK(inactive == 0, "%d events written while the event bus was off", inactive);
#endif
	CHECK(mallocs == 0, "process allocated %ld times", mallocs);
	CHECK(locks == 0, "process locked %ld times", locks);
	CHECK(same, "output is not the input");
	CHECK(ctl->getParamNormalized(0) == 0.0, "bypass did not turn off again");

	printf("== state\n");
	ctl->setParamNormalized(0, 1.0);
	Mem a;
	CHECK(comp->getState(&a) == kResultOk && a.b.size() == 6 + 189, "getState wrote %zu bytes", a.b.size());
	CHECK(a.b.size() > 6 && std::memcmp(a.b.data(), "BKV3", 4) == 0 && a.b[5] == 1, "tag / bypass byte");
	FUnknown* u2 = nullptr;
	f->createInstance(ci.cid, IComponent::iid, reinterpret_cast<void**>(&u2));
	auto* comp2 = static_cast<IComponent*>(static_cast<void*>(u2));
	auto* ctl2 = ask<IEditController>(comp2, IEditController::iid);
	a.at = 0;
	CHECK(comp2->setState(&a) == kResultOk, "setState before initialize");
	CHECK(ctl2->getParamNormalized(0) == 1.0, "bypass not restored");
	Mem b;
	comp2->getState(&b);
	CHECK(b.b == a.b, "re-saved state differs");
	struct Bad { const char* name; std::vector<uint8_t> bytes; };
	std::vector<Bad> bad = { { "garbage", std::vector<uint8_t>(100, 'x') }, { "over-cap", std::vector<uint8_t>(6 + BKP_STATE_CAP + 1, 0) } };
	{ std::vector<uint8_t> t = a.b; t[4] = 2; bad.push_back({ "layout-2", t }); }
	{ std::vector<uint8_t> t = a.b; t[5] = 7; bad.push_back({ "bypass-7", t }); }
	{ std::vector<uint8_t> t = a.b; t[30] ^= 1; bad.push_back({ "damaged-blob", t }); }
	for (auto& x : bad) {
		Mem m;
		m.b = x.bytes;
		CHECK(comp2->setState(&m) == kResultFalse, "%s accepted", x.name);
		Mem after;
		comp2->getState(&after);
		CHECK(after.b == a.b, "%s changed the instance", x.name);
	}
	Mem empty;
	CHECK(comp2->setState(&empty) == kResultOk, "an empty stream refused");
	CHECK(comp2->setState(nullptr) == kInvalidArgument, "a NULL stream accepted");

	proc->setProcessing(false);
	comp->setActive(false);
	comp->terminate();
	ctl2->release();
	comp2->release();
	ctl->release();
	proc->release();
	comp->release();
	f->release();
	printf("vst3_harness: %d checks, %d failed\n", g_checks, g_failed);
	return g_failed ? 1 : 0;
}
