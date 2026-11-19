/*
 * log.h: the core's one log writer (plan A7, house kit "logging").
 * File: <dir>/plugin.log, rolled at 1 MB, the current file plus one old one (plugin.log.1).
 * dir = bk_log_set_dir, else $BEATKEY_LOG_DIR, else ~/Library/Logs/Beat Key (the app's log folder),
 * found from the password database, never $HOME: a sandboxed host's HOME is its container.
 * Every line: "<local time> <utc offset> pid <p> <area> <message>", mirrored to os_log
 * (subsystem com.jshriver.orion, category core).  A log folder that cannot be written is reported
 * once, to os_log; nothing is swallowed.  NEVER call from the audio thread (it locks and writes).
 */
#ifndef BK_LOG_H
#define BK_LOG_H

#include <cstdarg>
#include <cstddef>
#include <string>

#include "beatkey.h"

namespace bk {

void log_set_dir(const char *dir);            // NULL / "" = the env / default rule
void log_set_sink(bk_log_sink sink, void *ctx);   // NULL = the file again
void log_set_roll_bytes(size_t bytes);        // tests lower it; 0 = the 1 MB default
std::string log_path();                       // "" when no folder can be found
void logv(const char *area, const char *fmt, va_list ap);
void logf(const char *area, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

// Fills a caller's error buffer (may be NULL) and logs the same sentence under `area`.
void fail(const char *area, char *err, size_t err_cap, const char *fmt, ...) __attribute__((format(printf, 4, 5)));

}  // namespace bk

#endif
