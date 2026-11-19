/*
 * bkp_view.h: the placeholder face (plan step 8) every format hosts until the SwiftUI face (step 9)
 * replaces it.  One NSView: key in use, BPM in use, and the status sentence, refreshed 4 times a
 * second from the instance.  Fixed BKP_VIEW_W x BKP_VIEW_H.
 * Each format compiles bkp_view.m under its own Objective-C class name (-DBKP_VIEW_CLASS=...), so the
 * AU and the VST3 loaded in one host never share a class (plan A6).
 *
 * Lifetime: a view never holds the instance, only a token.  bkp_view_register(p) when the instance is
 * made, bkp_view_unregister(token) BEFORE bkp_destroy(p): from then on every view of that token shows
 * "closed" and never touches p, even when the host keeps the view alive after the instance (it
 * waits out a refresh that is reading p).  Register / unregister: any non-audio thread.
 * bkp_view_create: main thread.
 */
#ifndef BKP_VIEW_H_INCLUDED
#define BKP_VIEW_H_INCLUDED

#include <stdint.h>

#include "bkp.h"

#define BKP_VIEW_W 360
#define BKP_VIEW_H 120

#ifdef __cplusplus
extern "C" {
#endif

uint64_t bkp_view_register(bkp_instance *p);      /* 0 = could not (logged); the face then never opens */
void bkp_view_unregister(uint64_t token);
/* An autoreleased NSView * (void * so C++ shims need no Objective-C), or NULL (logged). */
void *bkp_view_create(uint64_t token);

#ifdef __cplusplus
}
#endif

#endif
