/*
 * beatkey_aax_describe.cpp: GetEffectDescriptions, the entry AAXLibrary's ACFRegisterPlugin calls when Pro Tools
 * scans the bundle (plan step 13).    One effect, "Beat Key", one Native process
 * proc per stem format, mono to 7.1.2 (N in = N out), the data model, the GUI.  No DSP (TI); AudioSuite is
 * step 14.  Every failed descriptor call is logged with its AAX error and the first error is returned.
 *
 * Category: AAX_Enums.h has no analyzer category (EQ, Dynamics, PitchShift, Reverb, Delay, Modulation, Harmonic,
 * NoiseReduction, Dither, SoundField, generators, WrappedPlugin, Effect, Example, MIDIEffect).  Beat Key changes
 * no audio, so none of the processing ones fit; AAX_ePlugInCategory_Effect ("special effects") is the one left.
 */
#include "AAX.h"
#include "AAX_Errors.h"
#include "AAX_ICollection.h"
#include "AAX_IComponentDescriptor.h"
#include "AAX_IEffectDescriptor.h"
#include "AAX_IPropertyMap.h"
#include "beatkey_aax.h"

#ifndef BKP_AAX_VERSION_INT
#error "BKP_AAX_VERSION_INT is not defined: build with plugin/build.sh"
#endif

namespace {

struct Steps {
	AAX_Result first = AAX_SUCCESS;
	void check(AAX_Result r, const char* what)
	{
		if (r != AAX_SUCCESS) {
			bk_log("plugin", "AAX describe: %s failed (AAX error %d)", what, static_cast<int>(r));
			if (first == AAX_SUCCESS) {
				first = r;
			}
		}
	}
};

struct Stem {
	uint32_t format;
	AAX_CTypeID nativeID; // permanent: Pro Tools sessions store it
	AAX_CProcessProc proc;
	const char* name;
};

template <int N>
AAX_CProcessProc proc_for()
{
	return reinterpret_cast<AAX_CProcessProc>(&BeatKeyAax_Process<N>);
}

const Stem kStems[] = {
	{ AAX_eStemFormat_Mono, 'BKmo', proc_for<1>(), "mono" },
	{ AAX_eStemFormat_Stereo, 'BKs2', proc_for<2>(), "stereo" },
	{ AAX_eStemFormat_LCR, 'BKlc', proc_for<3>(), "LCR" },
	{ AAX_eStemFormat_LCRS, 'BKls', proc_for<4>(), "LCRS" },
	{ AAX_eStemFormat_Quad, 'BKqd', proc_for<4>(), "quad" },
	{ AAX_eStemFormat_5_0, 'BK50', proc_for<5>(), "5.0" },
	{ AAX_eStemFormat_5_1, 'BK51', proc_for<6>(), "5.1" },
	{ AAX_eStemFormat_6_0, 'BK60', proc_for<6>(), "6.0" },
	{ AAX_eStemFormat_6_1, 'BK61', proc_for<7>(), "6.1" },
	{ AAX_eStemFormat_7_0_SDDS, 'BK7S', proc_for<7>(), "7.0 SDDS" },
	{ AAX_eStemFormat_7_1_SDDS, 'BK8S', proc_for<8>(), "7.1 SDDS" },
	{ AAX_eStemFormat_7_0_DTS, 'BK70', proc_for<7>(), "7.0" },
	{ AAX_eStemFormat_7_1_DTS, 'BK71', proc_for<8>(), "7.1" },
	{ AAX_eStemFormat_7_0_2, 'BK72', proc_for<9>(), "7.0.2" },
	{ AAX_eStemFormat_7_1_2, 'BK82', proc_for<10>(), "7.1.2" },
};

void describe_stem(AAX_IComponentDescriptor* comp, const Stem& s, Steps& st)
{
	st.check(comp->AddAudioIn(eBeatKeyAaxField_AudioIn), "AddAudioIn");
	st.check(comp->AddAudioOut(eBeatKeyAaxField_AudioOut), "AddAudioOut");
	st.check(comp->AddAudioBufferLength(eBeatKeyAaxField_BufferSize), "AddAudioBufferLength");
	st.check(comp->AddPrivateData(eBeatKeyAaxField_Instance, sizeof(bkp_instance*), AAX_ePrivateDataOptions_DefaultOptions), "AddPrivateData");
#if BKP_MIDI
	st.check(comp->AddMIDINode(eBeatKeyAaxField_MIDIOut, AAX_eMIDINodeType_LocalOutput, "Beat Key notes", 0x0001), "AddMIDINode (output)");
#endif
	AAX_IPropertyMap* const pm = comp->NewPropertyMap();
	if (!pm) {
		st.check(AAX_ERROR_NULL_OBJECT, s.name);
		return;
	}
	st.check(pm->AddProperty(AAX_eProperty_ManufacturerID, kBeatKeyAaxManufacturerID), "ManufacturerID");
	st.check(pm->AddProperty(AAX_eProperty_ProductID, kBeatKeyAaxProductID), "ProductID");
#if BKP_MIDI
	// Beat Key MIDI's own native IDs: the same table with 'BK' turned into 'BM' ('BKs2' -> 'BMs2'), permanent too
	const AAX_CTypeID nativeID = (s.nativeID & 0x0000FFFFu) | (static_cast<AAX_CTypeID>('B') << 24) | (static_cast<AAX_CTypeID>('M') << 16);
#else
	const AAX_CTypeID nativeID = s.nativeID;
#endif
	st.check(pm->AddProperty(AAX_eProperty_PlugInID_Native, nativeID), "PlugInID_Native");
	st.check(pm->AddProperty(AAX_eProperty_InputStemFormat, static_cast<AAX_CPropertyValue>(s.format)), "InputStemFormat");
	st.check(pm->AddProperty(AAX_eProperty_OutputStemFormat, static_cast<AAX_CPropertyValue>(s.format)), "OutputStemFormat");
	st.check(pm->AddProperty(AAX_eProperty_CanBypass, 1), "CanBypass");
	// one reading per track: a multi-mono split would give N instances each hearing one channel
	st.check(pm->AddProperty(AAX_eProperty_Constraint_MultiMonoSupport, 0), "MultiMonoSupport");
	st.check(comp->AddProcessProc_Native(s.proc, pm), s.name);
}

AAX_Result describe_effect(AAX_IEffectDescriptor* d)
{
	Steps st;
#if BKP_MIDI
	st.check(d->AddName("Beat Key MIDI"), "AddName");
	st.check(d->AddName("BeatKeyMIDI"), "AddName");
	st.check(d->AddName("BtKM"), "AddName");
#else
	st.check(d->AddName("Beat Key"), "AddName");
	st.check(d->AddName("BeatKey"), "AddName");
	st.check(d->AddName("BtKy"), "AddName");
#endif
	st.check(d->AddCategory(AAX_ePlugInCategory_Effect), "AddCategory");
	for (const Stem& s : kStems) {
		AAX_IComponentDescriptor* const comp = d->NewComponentDescriptor();
		if (!comp) {
			st.check(AAX_ERROR_NULL_OBJECT, "NewComponentDescriptor");
			continue;
		}
		describe_stem(comp, s, st);
		st.check(d->AddComponent(comp), s.name);
	}
	st.check(d->AddProcPtr(reinterpret_cast<void*>(&BeatKeyAaxParameters::Create), kAAX_ProcPtrID_Create_EffectParameters), "Create_EffectParameters");
	st.check(d->AddProcPtr(reinterpret_cast<void*>(&BeatKeyAaxGUI_Create), kAAX_ProcPtrID_Create_EffectGUI), "Create_EffectGUI");
	AAX_IPropertyMap* const ep = d->NewPropertyMap();
	if (!ep) {
		st.check(AAX_ERROR_NULL_OBJECT, "effect property map");
	} else {
		// the layer's state calls take its lock; keep them on the host's main thread with the rest
		st.check(ep->AddProperty(AAX_eProperty_RequiresChunkCallsOnMainThread, 1), "RequiresChunkCallsOnMainThread");
		st.check(d->SetProperties(ep), "SetProperties");
	}
	return st.first;
}

} // namespace

AAX_Result GetEffectDescriptions(AAX_ICollection* outCollection)
{
	if (!outCollection) {
		bk_log("plugin", "AAX describe: Pro Tools gave no collection");
		return AAX_ERROR_NULL_ARGUMENT;
	}
	Steps st;
	AAX_IEffectDescriptor* const d = outCollection->NewDescriptor();
	if (!d) {
		st.check(AAX_ERROR_NULL_OBJECT, "NewDescriptor");
	} else {
		st.check(describe_effect(d), "describe the effect");
		st.check(outCollection->AddEffect(BEATKEY_AAX_EFFECT_ID, d), "AddEffect");
	}
	st.check(outCollection->SetManufacturerName("Four Letter Records"), "SetManufacturerName");
#if BKP_MIDI
	st.check(outCollection->AddPackageName("Beat Key MIDI"), "AddPackageName");
	st.check(outCollection->AddPackageName("BeatKeyMIDI"), "AddPackageName");
	st.check(outCollection->AddPackageName("BtKM"), "AddPackageName");
#else
	st.check(outCollection->AddPackageName("Beat Key"), "AddPackageName");
	st.check(outCollection->AddPackageName("BeatKey"), "AddPackageName");
	st.check(outCollection->AddPackageName("BtKy"), "AddPackageName");
#endif
	st.check(outCollection->SetPackageVersion(BKP_AAX_VERSION_INT), "SetPackageVersion");
	return st.first;
}
