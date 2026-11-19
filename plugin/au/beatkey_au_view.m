/*
 * beatkey_au_view.m: the AU Cocoa view factory (AUCocoaUIBase).  The AU names this class in its
 * kAudioUnitProperty_CocoaUI answer; the host loads the bundle and calls uiViewForAudioUnit:.
 * The face itself is plugin/shared/bkp_view.m.  
 */
#import <AppKit/AppKit.h>
#import <AudioUnit/AUCocoaUIView.h>
#include <AudioToolbox/AudioToolbox.h>
#include "../shared/bkp_view.h"
#ifndef BKP_MIDI
#define BKP_MIDI 0
#endif

/* Same private ID as beatkey_au.cpp. */
#define kBeatKeyPropViewToken 64001

/* One class name per bundle (Objective-C classes share one namespace in the host): the MIDI variant
 * (BKP_MIDI=1, plan step 15) names its own, as beatkey_au.cpp's CocoaUI answer does. */
#if BKP_MIDI
#define BEATKEY_AU_VIEW_FACTORY BeatKeyMIDIAUViewFactory
#else
#define BEATKEY_AU_VIEW_FACTORY BeatKeyAUViewFactory
#endif

@interface BEATKEY_AU_VIEW_FACTORY : NSObject <AUCocoaUIBase>
@end

@implementation BEATKEY_AU_VIEW_FACTORY
- (unsigned)interfaceVersion { return 0; }
- (NSString *)description { return @"Beat Key"; }
- (NSView *)uiViewForAudioUnit:(AudioUnit)au withSize:(NSSize)inPreferredSize {
    (void)inPreferredSize;
    uint64_t token = 0;
    UInt32 size = sizeof token;
    OSStatus st = AudioUnitGetProperty(au, kBeatKeyPropViewToken, kAudioUnitScope_Global, 0, &token, &size);
    if (st != noErr || token == 0) {
        bk_log(BKP_MIDI ? "AU-MIDI" : "AU", "view: could not read the face's token (OSStatus %d, token %llu); no face", (int)st, (unsigned long long)token);
        return nil;
    }
    return (__bridge NSView *)bkp_view_create(token);
}
@end
