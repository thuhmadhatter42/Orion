/*
 * beatkey_aax_view.mm: the AAX plug-in window (plan step 13): an AAX_CEffectGUI that puts the face
 * (bkp_view_create, the SwiftUI face compiled as module BeatKeyAAX) into Pro Tools' NSView container.
 *   The window never holds the instance: it gets the view TOKEN from the data
 * model through GetCustomData('BKtk'), so a window that outlives its instance says "closed".  Main thread.  ARC.
 */
#import <AppKit/AppKit.h>
#include "AAX_CEffectGUI.h"
#include "AAX_Enums.h"
#include "AAX_IEffectParameters.h"
#include "AAX_IViewContainer.h"
#include "beatkey_aax.h"
#include "../shared/bkp_view.h"

namespace {

class BeatKeyAaxGUI final : public AAX_CEffectGUI {
public:
	AAX_Result GetViewSize(AAX_Point* oViewSize) const override
	{
		if (!oViewSize) {
			return AAX_ERROR_NULL_ARGUMENT;
		}
		oViewSize->horz = static_cast<float>(BKP_VIEW_W);
		oViewSize->vert = static_cast<float>(BKP_VIEW_H);
		return AAX_SUCCESS;
	}
	~BeatKeyAaxGUI() override { DeleteViewContainer(); }

protected:
	void CreateViewContents() override {} // the face is made when Pro Tools hands over its container

	void CreateViewContainer() override
	{
		if (GetViewContainerType() != AAX_eViewContainer_Type_NSView) {
			bk_log("plugin", "AAX face: container type %d is not an NSView; no face", static_cast<int>(GetViewContainerType()));
			return;
		}
		NSView* parent = (__bridge NSView*)GetViewContainerPtr();
		if (!parent) {
			bk_log("plugin", "AAX face: Pro Tools gave an empty NSView container; no face");
			return;
		}
		uint64_t token = 0;
		uint32_t wrote = 0;
		AAX_IEffectParameters* params = GetEffectParameters();
		const AAX_Result r = params ? params->GetCustomData(kBeatKeyAaxViewTokenBlock, sizeof token, &token, &wrote) : AAX_ERROR_NULL_OBJECT;
		if (r != AAX_SUCCESS || wrote != sizeof token) {
			bk_log("plugin", "AAX face: no view token from the data model (AAX error %d, %u bytes); no face", static_cast<int>(r),
				static_cast<unsigned>(wrote));
			return;
		}
		mView = (__bridge NSView*)bkp_view_create(token); // logged inside when NULL
		if (!mView) {
			return;
		}
		[mView setFrameOrigin:NSMakePoint(0, 0)];
		[parent addSubview:mView];
	}

	void DeleteViewContainer() override
	{
		if (mView) {
			[mView removeFromSuperview];
			mView = nil;
		}
	}

private:
	NSView* mView = nil;
};

} // namespace

AAX_IEffectGUI* AAX_CALLBACK BeatKeyAaxGUI_Create()
{
	AAX_IEffectGUI* g = new (std::nothrow) BeatKeyAaxGUI();
	if (!g) {
		bk_log("plugin", "AAX face: out of memory for the GUI object");
	}
	return g;
}
