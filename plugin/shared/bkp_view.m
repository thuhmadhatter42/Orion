/*
 * bkp_view.m: see bkp_view.h.  The placeholder face; step 9 replaces it with the SwiftUI face.
 */
#import <AppKit/AppKit.h>
#include <pthread.h>
#include "bkp_view.h"

#ifndef BKP_VIEW_CLASS
#error "BKP_VIEW_CLASS is not defined: each format names its own view class (plan A6)"
#endif

/* token -> instance, for this format's copy.  Held while a view reads the instance. */
#define BKP_VIEW_SLOTS 256
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static struct { uint64_t token; bkp_instance *p; } g_slots[BKP_VIEW_SLOTS];
static uint64_t g_next = 1;

uint64_t bkp_view_register(bkp_instance *p) {
    if (!p) return 0;
    pthread_mutex_lock(&g_mu);
    uint64_t t = 0;
    for (int i = 0; i < BKP_VIEW_SLOTS; i++)
        if (g_slots[i].token == 0) {
            t = g_next++;
            g_slots[i].token = t;
            g_slots[i].p = p;
            break;
        }
    pthread_mutex_unlock(&g_mu);
    if (!t) bkp_log(p, "REFUSED: %d instances already have a face in this host; this one will not open its face", BKP_VIEW_SLOTS);
    return t;
}

void bkp_view_unregister(uint64_t token) {
    if (!token) return;
    pthread_mutex_lock(&g_mu);   /* waits out a refresh reading the instance */
    for (int i = 0; i < BKP_VIEW_SLOTS; i++)
        if (g_slots[i].token == token) g_slots[i].token = 0, g_slots[i].p = NULL;
    pthread_mutex_unlock(&g_mu);
}

typedef struct {
    int alive, has_key, has_bpm;
    char key[8], status[256];
    double bpm;
} bkp_view_read;

static bkp_view_read read_token(uint64_t token) {
    bkp_view_read r = {0};
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < BKP_VIEW_SLOTS; i++)
        if (token && g_slots[i].token == token) {
            bkp_instance *p = g_slots[i].p;
            r.alive = 1;
            r.has_key = bkp_key_in_use(p, r.key, sizeof r.key) == 0;
            r.has_bpm = bkp_bpm_in_use(p, &r.bpm) == 0;
            bkp_status(p, r.status, sizeof r.status);
            break;
        }
    pthread_mutex_unlock(&g_mu);
    return r;
}

@interface BKP_VIEW_CLASS : NSView
@end

@implementation BKP_VIEW_CLASS {
    uint64_t _token;
    NSTextField *_key, *_bpm, *_status;
    NSTimer *_timer;
}

- (NSTextField *)label:(CGFloat)size weight:(NSFontWeight)w frame:(NSRect)f {
    NSTextField *t = [NSTextField labelWithString:@""];
    t.frame = f;
    t.font = [NSFont systemFontOfSize:size weight:w];
    t.textColor = [NSColor colorWithSRGBRed:1.0 green:0.69 blue:0.125 alpha:1.0];   /* house amber #ffb020 */
    t.alignment = NSTextAlignmentCenter;
    [self addSubview:t];
    return t;
}

- (instancetype)initWithToken:(uint64_t)token {
    self = [super initWithFrame:NSMakeRect(0, 0, BKP_VIEW_W, BKP_VIEW_H)];
    if (!self) return nil;
    _token = token;
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor colorWithWhite:0.08 alpha:1.0].CGColor;
    _key = [self label:30 weight:NSFontWeightSemibold frame:NSMakeRect(10, 58, 160, 44)];
    _bpm = [self label:30 weight:NSFontWeightSemibold frame:NSMakeRect(190, 58, 160, 44)];
    _status = [self label:11 weight:NSFontWeightRegular frame:NSMakeRect(10, 14, 340, 32)];
    _status.textColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    _status.maximumNumberOfLines = 2;
    [self refresh];
    return self;
}

- (void)refresh {
    const bkp_view_read r = read_token(_token);
    _key.stringValue = r.has_key ? [NSString stringWithUTF8String:r.key] : @"—";
    _bpm.stringValue = r.has_bpm ? [NSString stringWithFormat:@"%.2f", r.bpm] : @"—";
    if (!r.alive) _status.stringValue = @"This instance is closed.";
    else if (r.status[0]) _status.stringValue = [NSString stringWithUTF8String:r.status];
    else _status.stringValue = r.has_key ? @"Beat Key" : @"Listening…";
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [_timer invalidate];
    _timer = nil;
    if (self.window) {
        __weak BKP_VIEW_CLASS *weakSelf = self;
        _timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
            (void)t;
            [weakSelf refresh];
        }];
        [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    }
}

- (void)dealloc {
    [_timer invalidate];
}
@end

void *bkp_view_create(uint64_t token) {
    if (!token) {
        bk_log("plugin", "view: no token (the instance never registered a face); no face");
        return NULL;
    }
    if (![NSThread isMainThread]) {
        bk_log("plugin", "REFUSED: the host asked for the face off the main thread; no face");
        return NULL;
    }
    BKP_VIEW_CLASS *v = [[BKP_VIEW_CLASS alloc] initWithToken:token];
    if (!v) {
        bk_log("plugin", "view: could not make the face");
        return NULL;
    }
    return (void *)CFAutorelease((__bridge_retained CFTypeRef)v);   /* the parent view retains it when added */
}
