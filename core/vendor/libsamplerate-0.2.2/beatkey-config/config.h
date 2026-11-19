/*
 * config.h for the vendored libsamplerate 0.2.2 subset, written for Beat Key's core (not upstream's).
 * Only the medium sinc converter is built: essentia's Resample runs libsamplerate at its default
 * quality 1 = SRC_SINC_MEDIUM_QUALITY (essentia src/algorithms/standard/resample.h, commit 77a6a954),
 * and the core must give the same samples.  src_new() with any other sinc converter fails loudly
 * (SRC_ERR_BAD_CONVERTER); the best and fast coefficient tables are not vendored.
 */
#ifndef BEATKEY_LIBSAMPLERATE_CONFIG_H
#define BEATKEY_LIBSAMPLERATE_CONFIG_H

#define PACKAGE "libsamplerate"
#define VERSION "0.2.2"

#define ENABLE_SINC_MEDIUM_CONVERTER 1

#define HAVE_STDBOOL_H 1
#define HAVE_STDINT_H 1
#define HAVE_LRINT 1
#define HAVE_LRINTF 1
#define HAVE_VISIBILITY 1

/* lrint() rounds, it does not clip, on both arm64 and x86_64 */
#define CPU_CLIPS_POSITIVE 0
#define CPU_CLIPS_NEGATIVE 0
#define CPU_IS_LITTLE_ENDIAN 1
#define CPU_IS_BIG_ENDIAN 0

#endif
