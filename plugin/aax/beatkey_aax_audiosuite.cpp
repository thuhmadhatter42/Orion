/*
 * beatkey_aax_audiosuite.cpp: Pro Tools AudioSuite Analyze (plan step 14).  A second effect in the same AAX bundle,
 * modelled on the SDK's ExamplePlugIns/DemoDelay_HostProcessor: no real-time process proc, an AAX_CHostProcessor,
 * AAX_eProperty_OptionalAnalysis (the AudioSuite window's Analyze button is on, and Pro Tools also analyzes before a
 * Render or Preview).
 *
 * One owner per behaviour: this file is host glue only.  The whole clip goes to the instance layer (bkp_clip_*),
 * which downmixes it the core's way and reads it with the core's file path (bk_analyze_buffer = bpm.py's
 * analyze_full), then keeps the reading as the instance's reading.  The face (same GUI as the insert), SEND
 * AUTO-TUNE, SEND BPM and the session state then work on it unchanged.
 *
 * Render: Beat Key changes no audio.  The SDK has no property that refuses Render for an analysis-only effect
 * (AAX_Properties.h: RequiresAnalysis greys the Analyze button, OptionalAnalysis keeps it, DisablePreview turns
 * Preview off; nothing turns Render off), and an error from RenderAudio is a Pro Tools error dialog.  So Render
 * copies the selection through unchanged, bit for bit, and logs that it did.
 *
 * Threads: PreAnalyze / AnalyzeAudio / RenderAudio run on Pro Tools' offline (AudioSuite) thread, not the real-time
 * one, so they may lock, allocate and log.  The analysis runs inside the last AnalyzeAudio window (Pro Tools'
 * progress bar is up); PostAnalyze only finishes a clip whose length the host never said, because PostAnalyze runs
 * on the main thread (AAX_CHostProcessor.h: a long PostAnalyze is a visible hang).
 */
#include "AAX.h"
#include "AAX_CHostProcessor.h"
#include "AAX_Errors.h"
#include "AAX_ICollection.h"
#include "AAX_IController.h"
#include "AAX_IEffectDescriptor.h"
#include "AAX_IEffectParameters.h"
#include "AAX_IPropertyMap.h"
#include "beatkey_aax.h"
#include <cmath>
#include <cstring>
#include <new>

namespace {

constexpr const char* kRun = "AudioSuite Analyze";

class BeatKeyAaxHostProcessor final : public AAX_CHostProcessor {
public:
	static AAX_CHostProcessor* AAX_CALLBACK Create()
	{
		AAX_CHostProcessor* h = new (std::nothrow) BeatKeyAaxHostProcessor();
		if (!h) {
			bk_log("plugin", "AAX AudioSuite: out of memory for the host processor; Analyze will not run");
		}
		return h;
	}

	AAX_Result PreAnalyze(int32_t inAudioInCount, int32_t iWindowSize) override
	{
		mOpen = false;
		mInst = instance();
		if (!mInst) {
			return AAX_SUCCESS; // logged in instance(); Pro Tools' pass runs, nothing is read
		}
		double rate = 0;
		AAX_CSampleRate sr = 0;
		const AAX_Result r = Controller() ? Controller()->GetSampleRate(&sr) : AAX_ERROR_NULL_OBJECT;
		if (r == AAX_SUCCESS) {
			rate = static_cast<double>(sr);
		}
		const int64_t range = GetInputRange();
		char err[256] = {0};
		if (bkp_clip_begin(mInst, rate, range > 0 ? static_cast<uint64_t>(range) : 0, err, sizeof err) != 0) {
			bkp_log(mInst, "%s REFUSED before it began: %s (AAX rate error %d, %d ch, window %d)", kRun, err, static_cast<int>(r),
				static_cast<int>(inAudioInCount), static_cast<int>(iWindowSize));
			return AAX_SUCCESS;
		}
		mOpen = true;
		return AAX_SUCCESS;
	}

	AAX_Result AnalyzeAudio(const float* const inAudioIns[], int32_t inAudioInCount, int32_t* ioWindowSize) override
	{
		if (!mOpen || !mInst || !ioWindowSize || *ioWindowSize <= 0) {
			return AAX_SUCCESS;
		}
		bkp_clip_add(mInst, inAudioIns, static_cast<int>(inAudioInCount), static_cast<uint32_t>(*ioWindowSize)); // refusals logged inside
		uint64_t have = 0, want = 0;
		bkp_clip_progress(mInst, &have, &want);
		if (want > 0 && have >= want) {
			finish(); // the whole selection is in: read it here, on the offline thread, under Pro Tools' progress bar
		}
		return AAX_SUCCESS;
	}

	AAX_Result PostAnalyze() override
	{
		if (mOpen) {
			// still open: either the host never said the length (read what came) or it stopped short (drop it)
			uint64_t have = 0, want = 0;
			bkp_clip_progress(mInst, &have, &want);
			if (want > 0 && have < want) {
				bkp_clip_cancel(mInst, "Pro Tools ended the Analyze pass before the selection was in (cancelled?)");
				mOpen = false;
				return AAX_SUCCESS;
			}
			finish();
		}
		return AAX_SUCCESS;
	}

	AAX_Result PreRender(int32_t inAudioInCount, int32_t iAudioOutCount, int32_t iWindowSize) override
	{
		(void)iWindowSize;
		mRenderFrames = 0;
		mRenderIn = inAudioInCount;
		mRenderOut = iAudioOutCount;
		return AAX_SUCCESS;
	}

	AAX_Result RenderAudio(const float* const inAudioIns[], int32_t inAudioInCount, float* const inAudioOuts[], int32_t inAudioOutCount,
		int32_t* ioWindowSize) override
	{
		if (!ioWindowSize || *ioWindowSize <= 0 || !inAudioOuts) {
			return AAX_SUCCESS;
		}
		const size_t bytes = static_cast<size_t>(*ioWindowSize) * sizeof(float);
		for (int32_t c = 0; c < inAudioOutCount; c++) {
			if (!inAudioOuts[c]) {
				continue;
			}
			if (inAudioIns && c < inAudioInCount && inAudioIns[c]) {
				if (inAudioOuts[c] != inAudioIns[c]) {
					std::memmove(inAudioOuts[c], inAudioIns[c], bytes);
				}
			} else {
				std::memset(inAudioOuts[c], 0, bytes);
			}
		}
		mRenderFrames += *ioWindowSize;
		return AAX_SUCCESS;
	}

	AAX_Result PostRender() override
	{
		bkp_instance* const inst = mInst ? mInst : instance();
		bkp_log(inst, "AudioSuite Render: %d in / %d out, %lld frames passed through unchanged (Beat Key changes no audio)",
			static_cast<int>(mRenderIn), static_cast<int>(mRenderOut), static_cast<long long>(mRenderFrames));
		return AAX_SUCCESS;
	}

private:
	void finish()
	{
		mOpen = false;
		bk_reading r;
		char err[256] = {0};
		bkp_clip_end(mInst, kRun, &r, err, sizeof err); // the run's one log line (reading or refusal) is written inside
	}

	// The instance of this effect's data model (GetCustomData 'BKin'), or null (logged).
	bkp_instance* instance()
	{
		bkp_instance* inst = nullptr;
		uint32_t wrote = 0;
		AAX_IEffectParameters* const params = GetEffectParameters();
		const AAX_Result r = params ? params->GetCustomData(kBeatKeyAaxInstanceBlock, sizeof inst, &inst, &wrote) : AAX_ERROR_NULL_OBJECT;
		if (r != AAX_SUCCESS || wrote != sizeof inst || !inst) {
			bk_log("plugin", "%s: no instance from the data model (AAX error %d, %u bytes); nothing is read", kRun, static_cast<int>(r),
				static_cast<unsigned>(wrote));
			return nullptr;
		}
		return inst;
	}

	bkp_instance* mInst = nullptr;
	bool mOpen = false;
	int64_t mRenderFrames = 0;
	int32_t mRenderIn = 0, mRenderOut = 0;
};

struct Steps {
	AAX_Result first = AAX_SUCCESS;
	void check(AAX_Result r, const char* what)
	{
		if (r != AAX_SUCCESS) {
			bk_log("plugin", "AAX describe (AudioSuite): %s failed (AAX error %d)", what, static_cast<int>(r));
			if (first == AAX_SUCCESS) {
				first = r;
			}
		}
	}
};

} // namespace

AAX_Result BeatKeyAax_DescribeAudioSuite(AAX_ICollection* collection)
{
	Steps st;
	if (!collection) {
		st.check(AAX_ERROR_NULL_ARGUMENT, "no collection");
		return st.first;
	}
	AAX_IEffectDescriptor* const d = collection->NewDescriptor();
	if (!d) {
		st.check(AAX_ERROR_NULL_OBJECT, "NewDescriptor");
		return st.first;
	}
	AAX_IPropertyMap* const pm = d->NewPropertyMap();
	if (!pm) {
		st.check(AAX_ERROR_NULL_OBJECT, "NewPropertyMap");
		return st.first;
	}
	st.check(pm->AddProperty(AAX_eProperty_ManufacturerID, kBeatKeyAaxManufacturerID), "ManufacturerID");
	st.check(pm->AddProperty(AAX_eProperty_ProductID, kBeatKeyAaxASProductID), "ProductID");
	st.check(pm->AddProperty(AAX_eProperty_PlugInID_AudioSuite, kBeatKeyAaxASPlugInID), "PlugInID_AudioSuite");
	st.check(pm->AddProperty(AAX_eProperty_NumberOfInputs, AAX_eMaxAudioSuiteTracks), "NumberOfInputs");
	st.check(pm->AddProperty(AAX_eProperty_NumberOfOutputs, AAX_eMaxAudioSuiteTracks), "NumberOfOutputs");
	// Analyze button on; Pro Tools also analyzes before Render / Preview.  Not MultiInputModeOnly: the SDK's known
	// issue PT-258560 says Pro Tools then gives mono mode only (will not be fixed).
	st.check(pm->AddProperty(AAX_eProperty_OptionalAnalysis, 1), "OptionalAnalysis");
	// the layer's state calls take its lock; keep them on the host's main thread with the rest (as the insert does)
	st.check(pm->AddProperty(AAX_eProperty_RequiresChunkCallsOnMainThread, 1), "RequiresChunkCallsOnMainThread");
	st.check(d->AddName("Beat Key"), "AddName");
	st.check(d->AddName("BeatKey"), "AddName");
	st.check(d->AddName("BtKy"), "AddName");
	st.check(d->AddCategory(AAX_ePlugInCategory_Effect), "AddCategory"); // no analyzer category (beatkey_aax_describe.cpp)
	st.check(d->AddProcPtr(reinterpret_cast<void*>(&BeatKeyAaxParameters::CreateAudioSuite), kAAX_ProcPtrID_Create_EffectParameters),
		"Create_EffectParameters");
	st.check(d->AddProcPtr(reinterpret_cast<void*>(&BeatKeyAaxHostProcessor::Create), kAAX_ProcPtrID_Create_HostProcessor),
		"Create_HostProcessor");
	st.check(d->AddProcPtr(reinterpret_cast<void*>(&BeatKeyAaxGUI_Create), kAAX_ProcPtrID_Create_EffectGUI), "Create_EffectGUI");
	st.check(d->SetProperties(pm), "SetProperties");
	st.check(collection->AddEffect(BEATKEY_AAX_AS_EFFECT_ID, d), "AddEffect");
	return st.first;
}
