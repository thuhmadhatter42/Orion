/*
 * beatkey_vst3_view.mm: the VST3 IPlugView around the face (plugin/shared/bkp_view.h).  The size is the face's (bkp_face_size); the user does not drag it, but ADVANCED
 * widens the face and the view asks the host to follow (IPlugFrame::resizeView).  attached() adds the face to the host's parent
 * NSView; removed() takes it off.  The view holds only a token, never the instance.
 */
#import <AppKit/AppKit.h>
#include <atomic>
#include <new>
#include <cstring>

#include "pluginterfaces/gui/iplugview.h"
#include "beatkey_vst3.h"
#include "../shared/bkp_view.h"

using namespace Steinberg;

namespace {

class BeatKeyPlugView final : public IPlugView {
public:
	explicit BeatKeyPlugView(std::uint64_t token) : mToken(token) {}
	~BeatKeyPlugView() { Detach(); }

	tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override
	{
		if (FUnknownPrivate::iidEqual(iid, FUnknown::iid) || FUnknownPrivate::iidEqual(iid, IPlugView::iid)) {
			addRef();
			*obj = static_cast<IPlugView*>(this);
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

	tresult PLUGIN_API isPlatformTypeSupported(FIDString type) override
	{
		return (type && std::strcmp(type, kPlatformTypeNSView) == 0) ? kResultTrue : kResultFalse;
	}
	tresult PLUGIN_API attached(void* parent, FIDString type) override
	{
		if (isPlatformTypeSupported(type) != kResultTrue) {
			bk_log("VST3", "view attached: platform type '%s' is not NSView; no face", type ? type : "(null)");
			return kResultFalse;
		}
		if (!parent) {
			bk_log("VST3", "view attached: the host gave no parent NSView; no face");
			return kInvalidArgument;
		}
		@autoreleasepool {
			Detach();
			NSView* v = (__bridge NSView*)bkp_view_create(mToken);
			if (!v) {
				return kResultFalse; // logged by bkp_view_create
			}
			NSView* host = (__bridge NSView*)parent;
			[v setFrameOrigin:NSZeroPoint];
			[host addSubview:v];
			mView = v;
			// ADVANCED on / off resizes the face: ask the host's window to follow
			mObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSViewFrameDidChangeNotification
			                                                             object:v
			                                                              queue:nil
			                                                         usingBlock:^(NSNotification*) { FollowFace(); }];
		}
		return kResultOk;
	}
	tresult PLUGIN_API removed() override
	{
		Detach();
		return kResultOk;
	}
	tresult PLUGIN_API onWheel(float) override { return kResultFalse; }
	tresult PLUGIN_API onKeyDown(char16, int16, int16) override { return kResultFalse; }
	tresult PLUGIN_API onKeyUp(char16, int16, int16) override { return kResultFalse; }
	tresult PLUGIN_API getSize(ViewRect* size) override
	{
		if (!size) {
			return kInvalidArgument;
		}
		*size = FaceRect();
		return kResultOk;
	}
	tresult PLUGIN_API onSize(ViewRect*) override { return kResultOk; }
	tresult PLUGIN_API onFocus(TBool) override { return kResultOk; }
	tresult PLUGIN_API setFrame(IPlugFrame* frame) override
	{
		mFrame = frame;
		return kResultOk;
	}
	tresult PLUGIN_API canResize() override { return kResultFalse; }
	tresult PLUGIN_API checkSizeConstraint(ViewRect* rect) override
	{
		if (!rect) {
			return kInvalidArgument;
		}
		*rect = FaceRect();
		return kResultOk;
	}

private:
	static ViewRect FaceRect()
	{
		int32_t w = BKP_VIEW_W, h = BKP_VIEW_H;
		bkp_face_size(&w, &h);
		return ViewRect(0, 0, w, h);
	}
	void FollowFace()
	{
		if (!mFrame || mResizing) {
			return;
		}
		ViewRect r = FaceRect();
		mResizing = true;
		const tresult ok = mFrame->resizeView(this, &r);
		mResizing = false;
		if (ok != kResultOk) {
			bk_log("VST3", "face resize to %dx%d: the host refused (%d)", r.getWidth(), r.getHeight(), static_cast<int>(ok));
		}
	}
	void Detach()
	{
		if (mObserver) {
			[[NSNotificationCenter defaultCenter] removeObserver:mObserver];
			mObserver = nil;
		}
		if (mView) {
			[mView removeFromSuperview];
			mView = nil;
		}
	}
	std::uint64_t mToken;
	std::atomic<uint32> mRefs{ 1 };
	NSView* mView = nil;
	id mObserver = nil;
	IPlugFrame* mFrame = nullptr;
	bool mResizing = false;
};

} // namespace

IPlugView* beatkey_vst3_create_view(std::uint64_t token, bkp_instance* inst)
{
	if (!token) {
		bkp_log(inst, "VST3 createView: the face never registered; no editor");
		return nullptr;
	}
	return new (std::nothrow) BeatKeyPlugView(token);
}
