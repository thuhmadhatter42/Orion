/*
 * beatkey_vst3.h: what beatkey_vst3.cpp shares with its view (beatkey_vst3_view.mm) and the shim harness.
 */
#ifndef BEATKEY_VST3_H
#define BEATKEY_VST3_H

#include <cstdint>
#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/gui/iplugview.h"
#include "../shared/bkp.h"

/* The plug-in's one IPlugView around the face (plugin/shared/bkp_view.h), bound to the instance's view
 * token.  `inst` is only for log lines. */
Steinberg::IPlugView* beatkey_vst3_create_view(std::uint64_t token, bkp_instance* inst);

/* One plug-in instance (IComponent + IAudioProcessor + the controller facet).  Refcount 1, or NULL
 * (logged).  The factory calls it; the shim harness calls it directly. */
Steinberg::FUnknown* beatkey_vst3_create_instance();

#endif
