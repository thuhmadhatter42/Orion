/*
 * beatkey_aax.h: the AAX Native shim (plan step 13).  Host glue only.
 * The shim knows host types and nothing of the core: it calls bkp_* (plugin/shared/bkp.h) and nothing else of
 * Beat Key.  Declared here so a harness can build the real data-model object and call the real process entry.
 *
 * Threads: construct / destruct, EffectInit, chunk calls (AAX_eProperty_RequiresChunkCallsOnMainThread),
 * TimerWakeup, GetCustomData and notifications run on the host's main thread; the process proc runs on the
 * audio thread and calls bkp_process only (no lock, no allocation, no log).
 */
#ifndef BEATKEY_AAX_H
#define BEATKEY_AAX_H

#include "AAX.h"
#include "AAX_CEffectParameters.h"
#include "../shared/bkp.h"

/* BKP_MIDI=1 builds Beat Key MIDI (plan step 15) from the same sources: its own IDs, a local MIDI output node
 * in the context, and the notes from bkp_midi_process posted to it after each block. */
#ifndef BKP_MIDI
#define BKP_MIDI 0
#endif
#if BKP_MIDI
#include "AAX_IMIDINode.h"
#endif

/* IDs (permanent once shipped: Pro Tools sessions name the plug-in by them). */
constexpr AAX_CTypeID kBeatKeyAaxManufacturerID = 'FLRc'; // the AU's manufacturer code
#if BKP_MIDI
constexpr AAX_CTypeID kBeatKeyAaxProductID = 'BtKM';      // the MIDI AU's subtype
#else
constexpr AAX_CTypeID kBeatKeyAaxProductID = 'BtKy';      // the AU's subtype
#endif
constexpr AAX_CTypeID kBeatKeyAaxChunkID = 'BKst';        // the one chunk: the layer's state blob
constexpr int32_t kBeatKeyAaxChunkVersion = 1;            // the blob carries its own version inside
constexpr AAX_CTypeID kBeatKeyAaxViewTokenBlock = 'BKtk'; // GetCustomData: the face's token (uint64_t)
#if BKP_MIDI
#define BEATKEY_AAX_EFFECT_ID "com.jshriver.orion.plugin.midi"
#define BEATKEY_AAX_BUNDLE_ID "com.jshriver.orion.plugin.midi.aax"
#define BEATKEY_AAX_FORMAT "AAX-MIDI"
#define BEATKEY_AAX_NAME "Beat Key MIDI"
#else
#define BEATKEY_AAX_EFFECT_ID "com.jshriver.orion.plugin"
#define BEATKEY_AAX_BUNDLE_ID "com.jshriver.orion.plugin.aax"
#define BEATKEY_AAX_FORMAT "AAX"
#define BEATKEY_AAX_NAME "Beat Key"
#endif

/* The AudioSuite effect (plan step 14), a second effect in the same bundle: whole-clip Analyze through
 * AAX_CHostProcessor.  Its own product and AudioSuite IDs (permanent too), as the SDK's DemoDelay_HostProcessor does. */
constexpr AAX_CTypeID kBeatKeyAaxASProductID = 'BtKA';
constexpr AAX_CTypeID kBeatKeyAaxASPlugInID = 'BKas';
constexpr AAX_CTypeID kBeatKeyAaxInstanceBlock = 'BKin'; // GetCustomData: the instance (bkp_instance *), same process
#define BEATKEY_AAX_AS_EFFECT_ID "com.jshriver.orion.plugin.audiosuite"

/* The algorithm context: audio in, audio out, buffer length, and the instance (private data the data model
 * fills in ResetFieldData).  Bypass and the host tempo reach the instance from the data model, not here. */
struct BeatKeyAaxContext {
	float** mInputPP;
	float** mOutputPP;
	int32_t* mBufferSize;
	bkp_instance** mInstance;
#if BKP_MIDI
	AAX_IMIDINode* mMIDIOut; // the local MIDI output node ("Beat Key notes")
#endif
};
enum {
	eBeatKeyAaxField_AudioIn = AAX_FIELD_INDEX(BeatKeyAaxContext, mInputPP),
	eBeatKeyAaxField_AudioOut = AAX_FIELD_INDEX(BeatKeyAaxContext, mOutputPP),
	eBeatKeyAaxField_BufferSize = AAX_FIELD_INDEX(BeatKeyAaxContext, mBufferSize),
	eBeatKeyAaxField_Instance = AAX_FIELD_INDEX(BeatKeyAaxContext, mInstance),
#if BKP_MIDI
	eBeatKeyAaxField_MIDIOut = AAX_FIELD_INDEX(BeatKeyAaxContext, mMIDIOut),
#endif
};

/* AUDIO THREAD.  For every context in [begin, end): bkp_process with nch in = nch out.  A null context, a null
 * instance or a non-positive length never crashes (skipped; with no instance the audio is copied through). */
void beatkey_aax_process_instances(BeatKeyAaxContext* const begin[], const void* end, int nch);

template <int kChannels>
void AAX_CALLBACK BeatKeyAax_Process(BeatKeyAaxContext* const begin[], const void* end)
{
	beatkey_aax_process_instances(begin, end, kChannels);
}

class BeatKeyAaxParameters : public AAX_CEffectParameters {
public:
	static AAX_CEffectParameters* AAX_CALLBACK Create();
	/* The AudioSuite effect's data model: the same object, its instance reads whole clips (bkp_use_clips), no
	 * live analyzer is ever prepared. */
	static AAX_CEffectParameters* AAX_CALLBACK CreateAudioSuite();
	explicit BeatKeyAaxParameters(bool audioSuite = false);
	~BeatKeyAaxParameters() AAX_OVERRIDE;

	AAX_Result EffectInit() AAX_OVERRIDE;
	AAX_Result ResetFieldData(AAX_CFieldIndex inFieldIndex, void* oData, uint32_t inDataSize) const AAX_OVERRIDE;
	AAX_Result UpdateParameterNormalizedValue(AAX_CParamID iParameterID, double iValue, AAX_EUpdateSource iSource) AAX_OVERRIDE;
	AAX_Result TimerWakeup() AAX_OVERRIDE;

	AAX_Result GetNumberOfChunks(int32_t* oNumChunks) const AAX_OVERRIDE;
	AAX_Result GetChunkIDFromIndex(int32_t iIndex, AAX_CTypeID* oChunkID) const AAX_OVERRIDE;
	AAX_Result GetChunkSize(AAX_CTypeID iChunkID, uint32_t* oSize) const AAX_OVERRIDE;
	AAX_Result GetChunk(AAX_CTypeID iChunkID, AAX_SPlugInChunk* oChunk) const AAX_OVERRIDE;
	AAX_Result SetChunk(AAX_CTypeID iChunkID, const AAX_SPlugInChunk* iChunk) AAX_OVERRIDE;
	AAX_Result CompareActiveChunk(const AAX_SPlugInChunk* iChunkP, AAX_CBoolean* oIsEqual) const AAX_OVERRIDE;
	AAX_Result GetCustomData(AAX_CTypeID iDataBlockID, uint32_t inDataSize, void* oData, uint32_t* oDataWritten) const AAX_OVERRIDE;
	AAX_Result NotificationReceived(AAX_CTypeID inNotificationType, const void* inNotificationData, uint32_t inNotificationDataSize) AAX_OVERRIDE;

	bkp_instance* instance() const { return mInst; }
	uint64_t viewToken() const { return mViewToken; }

private:
	void prepareForHostRate();

	bkp_instance* mInst = nullptr;
	bool mAudioSuite = false;
	uint64_t mViewToken = 0;
	double mRate = 0;
	// GetChunkSize stages the bytes GetChunk then writes (the AAX interface makes both const)
	mutable uint8_t mStaged[BKP_STATE_CAP];
	mutable size_t mStagedLen = 0;
	mutable bool mSized = false;
};

/* The GUI (beatkey_aax_view.mm): an AAX_CEffectGUI hosting the face (bkp_view_create). */
class AAX_IEffectGUI;
AAX_IEffectGUI* AAX_CALLBACK BeatKeyAaxGUI_Create();

/* The AudioSuite effect (beatkey_aax_audiosuite.cpp): its description, added to the collection by
 * GetEffectDescriptions.  Failed descriptor calls are logged; the first error is returned. */
class AAX_ICollection;
AAX_Result BeatKeyAax_DescribeAudioSuite(AAX_ICollection* collection);

#endif
