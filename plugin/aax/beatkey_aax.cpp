/*
 * beatkey_aax.cpp: the AAX Native shim's data model and audio entry (plan step 13).  See beatkey_aax.h.
 * Host glue only.
 *
 * What lives where (one owner each):
 *   audio          bkp_process, THE audio function of every format (the context hands it the instance)
 *   sample rate    Controller()->GetSampleRate at EffectInit, re-checked in TimerWakeup -> bkp_prepare
 *   bypass         Pro Tools' Master Bypass control -> bkp_set_bypass (UpdateParameterNormalizedValue)
 *   host tempo     Transport()->GetCurrentTempo in TimerWakeup -> bkp_set_host_tempo
 *   session state  one chunk 'BKst' = the layer's blob (bkp_state_save / bkp_state_load)
 *   face           GetCustomData('BKtk') hands the GUI the instance's view token (bkp_view.h)
 *   AudioSuite     the same object, made by CreateAudioSuite: its instance reads whole clips (bkp_use_clips), never
 *                  prepares a live analyzer; GetCustomData('BKin') hands the host processor the instance
 *                  (beatkey_aax_audiosuite.cpp)
 */
#include "beatkey_aax.h"
#include "AAX_CBinaryDisplayDelegate.h"
#include "AAX_CBinaryTaperDelegate.h"
#include "AAX_CParameter.h"
#include "AAX_CString.h"
#include "AAX_Errors.h"
#include "AAX_ITransport.h"
#include "../shared/bkp_view.h"
#include <cmath>
#include <cstring>
#include <memory>
#include <new>

#ifndef BKP_VERSION
#error "BKP_VERSION is not defined: build with plugin/build.sh"
#endif

// ---------------------------------------------------------------------------------------------------------------
// audio

void beatkey_aax_process_instances(BeatKeyAaxContext* const begin[], const void* end, int nch)
{
	if (!begin) {
		return;
	}
	for (BeatKeyAaxContext* const* walk = begin; walk < end; ++walk) {
		BeatKeyAaxContext* const c = *walk;
		if (!c || !c->mBufferSize || *c->mBufferSize <= 0 || !c->mOutputPP) {
			continue;
		}
		const uint32_t frames = static_cast<uint32_t>(*c->mBufferSize);
		bkp_instance* const inst = c->mInstance ? *c->mInstance : nullptr;
		if (!inst) {
			// Create refuses without an instance, so this is a context the data model never filled:
			// pass the audio through as every other path does, nothing else
			for (int ch = 0; ch < nch; ch++) {
				if (c->mOutputPP[ch] && c->mInputPP && c->mInputPP[ch] && c->mOutputPP[ch] != c->mInputPP[ch]) {
					std::memcpy(c->mOutputPP[ch], c->mInputPP[ch], frames * sizeof(float));
				}
			}
			continue;
		}
		bkp_process(inst, reinterpret_cast<const void* const*>(c->mInputPP), c->mInputPP ? nch : 0,
			reinterpret_cast<void* const*>(c->mOutputPP), nch, frames, 0);
#if BKP_MIDI
		// the notes that changed, to the MIDI output node (the DemoMIDI_NoteOn pattern)
		bkp_midi_event ev[BKP_MIDI_EVENTS];
		AAX_IMIDINode* const node = c->mMIDIOut;
		const int n = bkp_midi_process(inst, node != nullptr, ev);
		for (int k = 0; k < n; k++) {
			AAX_CMidiPacket pkt;
			pkt.mTimestamp = ev[k].offset;
			pkt.mLength = 3;
			pkt.mData[0] = ev[k].status;
			pkt.mData[1] = ev[k].note;
			pkt.mData[2] = ev[k].velocity;
			pkt.mData[3] = 0;
			pkt.mIsImmediate = false;
			node->PostMIDIPacket(&pkt);
		}
#endif
	}
}

// ---------------------------------------------------------------------------------------------------------------
// data model

AAX_CEffectParameters* AAX_CALLBACK BeatKeyAaxParameters::Create()
{
	BeatKeyAaxParameters* p = new (std::nothrow) BeatKeyAaxParameters();
	if (!p) {
		bk_log("plugin", "AAX instance not created: out of memory for the effect object");
		return nullptr;
	}
	if (!p->mInst) {
		bk_log("plugin", "AAX instance not created: the instance layer could not be made (out of memory)");
		delete p;
		return nullptr;
	}
	return p;
}

AAX_CEffectParameters* AAX_CALLBACK BeatKeyAaxParameters::CreateAudioSuite()
{
	BeatKeyAaxParameters* p = new (std::nothrow) BeatKeyAaxParameters(true);
	if (!p) {
		bk_log("plugin", "AAX AudioSuite instance not created: out of memory for the effect object");
		return nullptr;
	}
	if (!p->mInst) {
		bk_log("plugin", "AAX AudioSuite instance not created: the instance layer could not be made (out of memory)");
		delete p;
		return nullptr;
	}
	return p;
}

BeatKeyAaxParameters::BeatKeyAaxParameters(bool audioSuite)
	: mAudioSuite(audioSuite)
{
	// one format for both effects of a bundle ("AAX", or "AAX-MIDI" in Beat Key MIDI): one crash marker per bundle
	bkp_config cfg = { BEATKEY_AAX_FORMAT, BEATKEY_AAX_BUNDLE_ID, nullptr, nullptr };
	mInst = bkp_create(&cfg);
	if (mInst && mAudioSuite) {
		bkp_use_clips(mInst);
	}
	mViewToken = bkp_view_register(mInst);
#if BKP_MIDI
	if (!mAudioSuite) {
		bkp_view_midi_enable(mInst); // the face's chords; a refusal is logged and the face says no MIDI
	}
#endif
}

BeatKeyAaxParameters::~BeatKeyAaxParameters()
{
	bkp_view_unregister(mViewToken); // before the instance goes: an open face stops reading it
	mViewToken = 0;
	bkp_destroy(mInst);
	mInst = nullptr;
}

void BeatKeyAaxParameters::prepareForHostRate()
{
	if (mAudioSuite) {
		return; // whole clips only: the host processor reads the rate at each Analyze, no live analyzer
	}
	AAX_IController* const ctl = Controller();
	if (!ctl) {
		return;
	}
	AAX_CSampleRate rate = 0;
	const AAX_Result r = ctl->GetSampleRate(&rate);
	if (r != AAX_SUCCESS || !(rate > 0) || !std::isfinite(rate)) {
		if (mRate == 0) {
			bkp_log(mInst, "AAX: the host did not give a sample rate (AAX error %d, rate %f); no analysis until it does",
				static_cast<int>(r), static_cast<double>(rate));
			mRate = -1; // logged once
		}
		return;
	}
	if (static_cast<double>(rate) != mRate) {
		mRate = rate;
		bkp_prepare(mInst, mRate); // a refusal is logged inside; audio still passes through
	}
}

AAX_Result BeatKeyAaxParameters::EffectInit()
{
	// Pro Tools' Master Bypass control: audio still passes through, the analyzer hears nothing (bkp_set_bypass).
	// The base class keeps it out of every chunk (FilterParameterIDOnSave in Initialize).
	AAX_CString id(cDefaultMasterBypassID);
	std::unique_ptr<AAX_IParameter> param(new (std::nothrow) AAX_CParameter<bool>(id, AAX_CString("Master Bypass"), false,
		AAX_CBinaryTaperDelegate<bool>(), AAX_CBinaryDisplayDelegate<bool>("bypass", "on"), true));
	if (!param) {
		bkp_log(mInst, "AAX EffectInit: out of memory for the Master Bypass control");
		return AAX_ERROR_NULL_OBJECT;
	}
	param->SetNumberOfSteps(2);
	param->SetType(AAX_eParameterType_Discrete);
	mParameterManager.AddParameter(param.release());
	if (!mParameterManager.GetParameterByID(cDefaultMasterBypassID)) {
		bkp_log(mInst, "AAX EffectInit: the Master Bypass control was not kept by the parameter manager");
		return AAX_ERROR_NULL_OBJECT;
	}
	prepareForHostRate();
	return AAX_SUCCESS;
}

AAX_Result BeatKeyAaxParameters::ResetFieldData(AAX_CFieldIndex inFieldIndex, void* oData, uint32_t inDataSize) const
{
	if (inFieldIndex != eBeatKeyAaxField_Instance) {
		return AAX_CEffectParameters::ResetFieldData(inFieldIndex, oData, inDataSize);
	}
	if (!oData || inDataSize < sizeof(bkp_instance*)) {
		bkp_log(mInst, "AAX: the host gave %u bytes for the instance field (need %zu); this instance will not analyze",
			static_cast<unsigned>(inDataSize), sizeof(bkp_instance*));
		return AAX_ERROR_INVALID_ARGUMENT;
	}
	std::memset(oData, 0, inDataSize);
	bkp_instance* const inst = mInst;
	std::memcpy(oData, &inst, sizeof inst);
	return AAX_SUCCESS;
}

AAX_Result BeatKeyAaxParameters::UpdateParameterNormalizedValue(AAX_CParamID iParameterID, double iValue, AAX_EUpdateSource iSource)
{
	const AAX_Result r = AAX_CEffectParameters::UpdateParameterNormalizedValue(iParameterID, iValue, iSource);
	if (r == AAX_SUCCESS && iParameterID && std::strcmp(iParameterID, cDefaultMasterBypassID) == 0) {
		bkp_set_bypass(mInst, iValue >= 0.5);
	}
	return r;
}

AAX_Result BeatKeyAaxParameters::TimerWakeup()
{
	prepareForHostRate();
	const AAX_ITransport* const t = Transport();
	double bpm = 0;
	if (t && t->GetCurrentTempo(&bpm) == AAX_SUCCESS) {
		bkp_set_host_tempo(mInst, bpm); // <= 0 or not finite = unknown (the layer's rule)
	}
	return AAX_CEffectParameters::TimerWakeup();
}

// ---- the one chunk ----

AAX_Result BeatKeyAaxParameters::GetNumberOfChunks(int32_t* oNumChunks) const
{
	if (!oNumChunks) {
		bkp_log(mInst, "AAX chunks: the host gave no count pointer");
		return AAX_ERROR_NULL_ARGUMENT;
	}
	*oNumChunks = 1;
	return AAX_SUCCESS;
}

AAX_Result BeatKeyAaxParameters::GetChunkIDFromIndex(int32_t iIndex, AAX_CTypeID* oChunkID) const
{
	if (!oChunkID) {
		bkp_log(mInst, "AAX chunks: the host gave no chunk ID pointer");
		return AAX_ERROR_NULL_ARGUMENT;
	}
	if (iIndex != 0) {
		*oChunkID = 0;
		return AAX_ERROR_INVALID_CHUNK_INDEX;
	}
	*oChunkID = kBeatKeyAaxChunkID;
	return AAX_SUCCESS;
}

AAX_Result BeatKeyAaxParameters::GetChunkSize(AAX_CTypeID iChunkID, uint32_t* oSize) const
{
	if (!oSize) {
		bkp_log(mInst, "AAX chunk size: the host gave no size pointer");
		return AAX_ERROR_NULL_ARGUMENT;
	}
	if (iChunkID != kBeatKeyAaxChunkID) {
		*oSize = 0;
		return AAX_ERROR_INVALID_CHUNK_ID;
	}
	mStagedLen = bkp_state_save(mInst, mStaged, sizeof mStaged);
	mSized = mStagedLen > 0;
	if (!mSized) {
		*oSize = 0;
		bkp_log(mInst, "AAX chunk size: the state could not be made (logged above); nothing saved");
		return AAX_ERROR_INCORRECT_CHUNK_SIZE;
	}
	*oSize = static_cast<uint32_t>(mStagedLen);
	return AAX_SUCCESS;
}

AAX_Result BeatKeyAaxParameters::GetChunk(AAX_CTypeID iChunkID, AAX_SPlugInChunk* oChunk) const
{
	if (!oChunk) {
		bkp_log(mInst, "AAX save: the host gave no chunk to fill; state not saved");
		return AAX_ERROR_NULL_ARGUMENT;
	}
	if (iChunkID != kBeatKeyAaxChunkID) {
		return AAX_ERROR_INVALID_CHUNK_ID;
	}
	if (!mSized) {
		// the host's buffer size is only known from a GetChunkSize: without one, nothing is written
		bkp_log(mInst, "AAX save REFUSED: the host asked for the chunk without asking its size first; state not saved");
		return AAX_ERROR_INCORRECT_CHUNK_SIZE;
	}
	oChunk->fVersion = kBeatKeyAaxChunkVersion;
	std::memset(oChunk->fName, 0, sizeof oChunk->fName);
	std::strncpy(reinterpret_cast<char*>(oChunk->fName), "Beat Key state", sizeof oChunk->fName - 1);
	oChunk->fSize = static_cast<int32_t>(mStagedLen);
	std::memcpy(oChunk->fData, mStaged, mStagedLen);
	return AAX_SUCCESS;
}

AAX_Result BeatKeyAaxParameters::SetChunk(AAX_CTypeID iChunkID, const AAX_SPlugInChunk* iChunk)
{
	if (!iChunk) {
		bkp_log(mInst, "AAX restore: the host gave no chunk; kept what the instance had");
		return AAX_ERROR_NULL_ARGUMENT;
	}
	if (iChunkID != kBeatKeyAaxChunkID) {
		bkp_log(mInst, "AAX restore: chunk 0x%08x is not Beat Key's 'BKst'; ignored", static_cast<unsigned>(iChunkID));
		return AAX_ERROR_INVALID_CHUNK_ID;
	}
	const int32_t sz = iChunk->fSize;
	if (sz < 0 || sz > BKP_STATE_CAP) {
		bkp_log(mInst, "REFUSED: AAX restore: chunk of %d bytes (cap %d); kept what the instance had", static_cast<int>(sz), BKP_STATE_CAP);
		return AAX_ERROR_INCORRECT_CHUNK_SIZE;
	}
	char err[256];
	if (bkp_state_load(mInst, reinterpret_cast<const uint8_t*>(iChunk->fData), static_cast<size_t>(sz), err, sizeof err) != 0) {
		return AAX_ERROR_MALFORMED_CHUNK; // the reason is in the log (bkp_state_load)
	}
	return AAX_SUCCESS;
}

AAX_Result BeatKeyAaxParameters::CompareActiveChunk(const AAX_SPlugInChunk* iChunkP, AAX_CBoolean* oIsEqual) const
{
	if (!oIsEqual) {
		return AAX_ERROR_NULL_ARGUMENT;
	}
	// Beat Key has no settings to A/B: the chunk carries the last reading, which changes every two seconds while
	// audio plays.  Equal always, so Pro Tools' Compare light never lights for it.
	(void)iChunkP;
	*oIsEqual = true;
	return AAX_SUCCESS;
}

AAX_Result BeatKeyAaxParameters::GetCustomData(AAX_CTypeID iDataBlockID, uint32_t inDataSize, void* oData, uint32_t* oDataWritten) const
{
	if (iDataBlockID == kBeatKeyAaxInstanceBlock) {
		// the AudioSuite host processor's way to the instance (it only sees this object through the host's
		// interface); same process, and the host processor never outlives its data model
		if (!oData || inDataSize < sizeof(bkp_instance*)) {
			bkp_log(mInst, "AAX instance block: asked with %u bytes of room (need %zu) or no buffer", static_cast<unsigned>(inDataSize),
				sizeof(bkp_instance*));
			if (oDataWritten) {
				*oDataWritten = 0;
			}
			return AAX_ERROR_INVALID_ARGUMENT;
		}
		bkp_instance* const inst = mInst;
		std::memcpy(oData, &inst, sizeof inst);
		if (oDataWritten) {
			*oDataWritten = sizeof inst;
		}
		return AAX_SUCCESS;
	}
	if (iDataBlockID != kBeatKeyAaxViewTokenBlock) {
		return AAX_CEffectParameters::GetCustomData(iDataBlockID, inDataSize, oData, oDataWritten);
	}
	if (!oData || inDataSize < sizeof(uint64_t)) {
		bkp_log(mInst, "AAX face token: asked with %u bytes of room (need %zu) or no buffer", static_cast<unsigned>(inDataSize), sizeof(uint64_t));
		if (oDataWritten) {
			*oDataWritten = 0;
		}
		return AAX_ERROR_INVALID_ARGUMENT;
	}
	std::memcpy(oData, &mViewToken, sizeof(uint64_t));
	if (oDataWritten) {
		*oDataWritten = sizeof(uint64_t);
	}
	return AAX_SUCCESS;
}

AAX_Result BeatKeyAaxParameters::NotificationReceived(AAX_CTypeID inNotificationType, const void* inNotificationData, uint32_t inNotificationDataSize)
{
	if (inNotificationType == AAX_eNotificationEvent_SessionBeingOpened) {
		bkp_log(mInst, "Pro Tools is opening a session");
	} else if (inNotificationType == AAX_eNotificationEvent_EnteringOfflineMode) {
		bkp_log(mInst, "Pro Tools entered offline mode (bounce): readings may skip, nothing waits");
	}
	return AAX_CEffectParameters::NotificationReceived(inNotificationType, inNotificationData, inNotificationDataSize);
}
