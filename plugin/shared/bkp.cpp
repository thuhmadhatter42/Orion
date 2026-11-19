/*
 * bkp.cpp: see bkp.h.  This file is the plug-in's instance layer; the shims call it and nothing
 * else of Beat Key, and it calls the core (beatkey.h) and nothing of the core's insides.
 *
 * The audio path (bkp_process) touches: two atomics (bypass, the analyzer pointer), a per-instance
 * counter that says "the audio thread is inside", memmove / memset on the host's buffers, and the
 * core's bk_analyzer_push_channels (ring only).  For double buffers it converts into scratch that
 * was allocated at bkp_create.  Nothing else: no lock, no allocation, no log, no system call.
 */
#include "bkp.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <new>
#include <string>

#ifndef BKP_VERSION
#error "BKP_VERSION is not defined: build the plug-in with plugin/build.sh (it reads the repo's VERSION)"
#endif

namespace {

constexpr int kMaxCh = 64;            // what bk_analyzer_push_channels takes; channels past it are not heard
constexpr uint32_t kScratch = 1024;   // frames per double -> float conversion pass
constexpr size_t kHeader = 16;        // magic, version, reserved, payload length, checksum
constexpr size_t kPayloadV1 = 173;    // see put_payload

static_assert(std::atomic<double>::is_always_lock_free, "the host-tempo slot must be lock-free");
static_assert(std::atomic<bk_analyzer *>::is_always_lock_free, "the analyzer hand-over must be lock-free");

std::atomic<unsigned> g_serial{0};    // instance numbers for the log ("VST3#3")
std::mutex g_marker_mu;               // this format's copy of the layer: open instances + its marker
int g_open = 0;

std::string host_name() {
    CFBundleRef main = CFBundleGetMainBundle();
    CFStringRef id = main ? CFBundleGetIdentifier(main) : nullptr;
    char buf[256];
    if (id && CFStringGetCString(id, buf, sizeof buf, kCFStringEncodingUTF8) && buf[0]) return buf;
    const char *p = getprogname();
    return p && *p ? p : "unknown host";
}

std::string log_dir() {
    char buf[1024];
    std::string p = bk_log_path(buf, sizeof buf);
    const size_t slash = p.rfind('/');
    return slash == std::string::npos ? std::string() : p.substr(0, slash);
}

std::string now_text() {
    char buf[64];
    time_t t = time(nullptr);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(buf, sizeof buf, "%Y-%m-%d %H:%M:%S %z", &tm);
    return buf;
}

// ---- the crash marker (house kit, A7): <log dir>/running/<pid>-<format> while instances are open ----

std::string marker_dir() {
    const std::string d = log_dir();
    return d.empty() ? d : d + "/running";
}

// First instance of this format in this process: report markers whose process is gone, then set ours.
void marker_open(const char *format, const std::string &host) {
    const std::string dir = marker_dir();
    if (dir.empty()) {
        bk_log("plugin", "crash marker not set: no log folder (the host died check is off for this %s)", format);
        return;
    }
    if (mkdir(dir.c_str(), 0755) != 0 && errno != EEXIST) {
        bk_log("plugin", "crash marker not set: cannot make %s (errno %d)", dir.c_str(), errno);
        return;
    }
    if (DIR *d = opendir(dir.c_str())) {
        while (struct dirent *e = readdir(d)) {
            long pid = 0;
            char fmt[16] = {0};
            if (sscanf(e->d_name, "%ld-%15s", &pid, fmt) != 2 || pid <= 0) continue;
            if (pid == (long)getpid()) continue;
            if (kill((pid_t)pid, 0) == 0 || errno != ESRCH) continue;   // alive (or not ours to judge)
            const std::string path = dir + "/" + e->d_name;
            char what[512] = {0};
            if (FILE *f = fopen(path.c_str(), "r")) {
                size_t n = fread(what, 1, sizeof what - 1, f);
                what[n] = 0;
                fclose(f);
                if (char *nl = strchr(what, '\n')) *nl = 0;
            }
            if (unlink(path.c_str()) == 0)   // whoever removes it reports it: once, even with two formats loaded
                bk_log("plugin", "HOST DIED with Beat Key %s loaded: pid %ld, %s (Report attaches the host's newest crash report)",
                       fmt, pid, what[0] ? what : "no details in the marker");
        }
        closedir(d);
    } else {
        bk_log("plugin", "crash marker: cannot read %s (errno %d)", dir.c_str(), errno);
    }
    char name[64];
    snprintf(name, sizeof name, "%ld-%s", (long)getpid(), format);
    const std::string path = dir + "/" + name;
    FILE *f = fopen(path.c_str(), "w");
    if (!f) {
        bk_log("plugin", "crash marker not set: cannot write %s (errno %d)", path.c_str(), errno);
        return;
    }
    fprintf(f, "host %s, Beat Key %s %s, loaded %s\n", host.c_str(), format, BKP_VERSION, now_text().c_str());
    fclose(f);
}

void marker_close(const char *format) {
    const std::string dir = marker_dir();
    if (dir.empty()) return;
    char name[64];
    snprintf(name, sizeof name, "%ld-%s", (long)getpid(), format);
    const std::string path = dir + "/" + name;
    if (unlink(path.c_str()) != 0 && errno != ENOENT)
        bk_log("plugin", "crash marker: cannot remove %s (errno %d); the next load may report a crash that did not happen",
               path.c_str(), errno);
}

// ---- little-endian byte writer / reader for the state blob ----

struct Put {
    uint8_t *p;
    size_t n = 0;
    void u8(unsigned v) { p[n++] = (uint8_t)v; }
    void u16(unsigned v) { u8(v & 0xff); u8((v >> 8) & 0xff); }
    void u32(uint32_t v) { for (int i = 0; i < 4; i++) u8((v >> (8 * i)) & 0xff); }
    void f64(double v) {
        uint64_t b;
        memcpy(&b, &v, 8);
        for (int i = 0; i < 8; i++) u8((unsigned)((b >> (8 * i)) & 0xff));
    }
    void name(const char *s) { for (int i = 0; i < 4; i++) u8(i < (int)strnlen(s, 4) ? (uint8_t)s[i] : 0); }
};

struct Get {
    const uint8_t *p;
    size_t n = 0;
    unsigned u8() { return p[n++]; }
    unsigned u16() { unsigned v = u8(); return v | (u8() << 8); }
    uint32_t u32() { uint32_t v = 0; for (int i = 0; i < 4; i++) v |= (uint32_t)u8() << (8 * i); return v; }
    double f64() {
        uint64_t b = 0;
        for (int i = 0; i < 8; i++) b |= (uint64_t)u8() << (8 * i);
        double v;
        memcpy(&v, &b, 8);
        return v;
    }
    void name(char out[4]) {
        for (int i = 0; i < 4; i++) out[i] = (char)u8();
    }
};

uint32_t fnv1a(const uint8_t *p, size_t n) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 16777619u; }
    return h;
}

bool name_ok(const char raw[4], char out[4]) {
    if (raw[3] != 0) return false;                 // always NUL-terminated inside the 4 bytes
    memcpy(out, raw, 4);
    return bk_key_index(out) >= 0;
}

}  // namespace

struct bkp_instance {
    std::string format, host, area, weights_path;

    // audio thread <-> the rest
    std::atomic<bk_analyzer *> live{nullptr};
    std::atomic<int> inside{0};                 // the audio thread is in bkp_process
    std::atomic<int> bypass{0};
    std::atomic<double> host_tempo{0.0};
    float *scratch = nullptr;                   // kMaxCh x kScratch floats (double buffers only)
    float *scratch_ch[kMaxCh] = {};

    // non-audio threads, under mu
    std::mutex mu;
    double rate = 0.0;
    std::string why_not;                        // "" = analyzing
    bool has_held = false;
    bk_reading held{};                          // the last reading seen or restored
    char pin[4] = {0};
    int mult = 0;
};

namespace {

// Takes the analyzer out of the audio path and waits until the audio thread is not inside
// bkp_process (it never waits on us; we wait on it, a few microseconds).  Caller holds mu.
bk_analyzer *take_live(bkp_instance *p, bk_analyzer *replacement) {
    bk_analyzer *old = p->live.exchange(replacement, std::memory_order_seq_cst);
    for (int i = 0; p->inside.load(std::memory_order_seq_cst) != 0; i++) {
        if (i == 200000) {   // ~20 s: the audio thread is stuck inside the core; leaking beats freeing under it
            bkp_log(p, "REFUSED: the audio thread did not leave the analyzer for 20 s; the old analyzer is left alive");
            return nullptr;
        }
        usleep(100);
    }
    return old;
}

// Keep the newest reading the analyzer has (caller holds mu).
void hold_from(bkp_instance *p, const bk_analyzer *a) {
    if (!a) return;
    bk_snapshot s;
    bk_analyzer_snapshot(a, &s);
    if (s.has_reading) {
        p->held = s.reading;
        p->has_held = true;
    }
}

void put_payload(Put &w, const bkp_instance *p, bool has, const bk_reading &r) {
    w.u8((p->pin[0] ? 1u : 0u) | (has ? 2u : 0u));
    w.u8((uint8_t)(int8_t)p->mult);
    w.name(p->pin);
    const bk_reading z{};
    const bk_reading &x = has ? r : z;
    for (int i = 0; i < 3; i++) { w.name(x.keys[i].name); w.f64(x.keys[i].percent); }
    w.u8(x.has_tuning ? 1 : 0); w.f64(x.tuning_cents);
    for (int i = 0; i < 12; i++) w.f64(x.chroma[i]);
    w.u8(x.has_bpm ? 1 : 0); w.f64(x.bpm);
    w.u8(x.has_bpm_exact ? 1 : 0); w.f64(x.bpm_exact);
    w.f64(x.secs);
}

bool in(double v, double lo, double hi) { return std::isfinite(v) && v >= lo && v <= hi; }

}  // namespace

extern "C" {

void bkp_log(bkp_instance *p, const char *fmt, ...) {
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    bk_log(p ? p->area.c_str() : "plugin", "%s", line);
}

bkp_instance *bkp_create(const bkp_config *cfg) {
    bkp_instance *p = new (std::nothrow) bkp_instance;
    if (!p) {
        bk_log("plugin", "REFUSED: out of memory creating a plug-in instance");
        return nullptr;
    }
    p->scratch = new (std::nothrow) float[(size_t)kMaxCh * kScratch];
    if (!p->scratch) {
        bk_log("plugin", "REFUSED: out of memory for the instance's scratch");
        delete p;
        return nullptr;
    }
    for (int c = 0; c < kMaxCh; c++) p->scratch_ch[c] = p->scratch + (size_t)c * kScratch;
    p->format = cfg && cfg->format && *cfg->format ? cfg->format : "?";
    p->host = cfg && cfg->host && *cfg->host ? cfg->host : host_name();
    p->weights_path = cfg && cfg->weights_path ? cfg->weights_path : "";
    p->area = p->format + "#" + std::to_string(g_serial.fetch_add(1) + 1);

    {
        std::lock_guard<std::mutex> g(g_marker_mu);
        if (g_open++ == 0) marker_open(p->format.c_str(), p->host);
    }
    bkp_log(p, "plug-in opened: host %s, Beat Key %s %s, core %s", p->host.c_str(), p->format.c_str(), BKP_VERSION,
            bk_version());

    char err[256] = {0};
    if (!bk_ready()) {
        if (p->weights_path.empty()) {
            snprintf(err, sizeof err, "no weights path was given");
            bkp_log(p, "REFUSED: no weights path was given; the plug-in passes audio through and does not analyze");
        } else if (bk_load_weights(p->weights_path.c_str(), err, sizeof err) != BK_OK) {
            bkp_log(p, "REFUSED: weights not loaded from %s; the plug-in passes audio through and does not analyze",
                    p->weights_path.c_str());
        }
    }
    p->why_not = bk_ready() ? "Waiting for the host to start audio."
                            : std::string("The analyzer is incomplete: ") + err + ". Reinstall Beat Key.";
    return p;
}

void bkp_destroy(bkp_instance *p) {
    if (!p) return;
    {
        std::lock_guard<std::mutex> g(p->mu);
        bk_analyzer *a = take_live(p, nullptr);
        if (a) bk_analyzer_destroy(a);   // the last one joins the core's worker
    }
    bkp_log(p, "plug-in closed");
    {
        std::lock_guard<std::mutex> g(g_marker_mu);
        if (--g_open == 0) marker_close(p->format.c_str());
    }
    delete[] p->scratch;
    delete p;
}

int bkp_prepare(bkp_instance *p, double sample_rate) {
    if (!p) return -1;
    std::lock_guard<std::mutex> g(p->mu);
    bk_analyzer *cur = p->live.load();
    if (cur && sample_rate == p->rate) return 0;
    if (!bk_ready()) return -1;   // why_not already says so (create)
    if (cur) {
        hold_from(p, cur);
        bkp_log(p, "sample rate %.0f -> %.0f Hz: a new analyzer starts; the reading so far is kept", p->rate, sample_rate);
    }
    char err[256] = {0};
    bk_analyzer_config c = {sample_rate, p->host.c_str(), p->format.c_str()};
    bk_analyzer *a = bk_analyzer_create(&c, err, sizeof err);   // logs its own refusal
    bk_analyzer *old = take_live(p, a);
    if (old) bk_analyzer_destroy(old);
    if (!a) {
        p->rate = 0.0;
        p->why_not = std::string("Not analyzing: ") + err;
        return -1;
    }
    p->rate = sample_rate;
    p->why_not.clear();
    return 0;
}

void bkp_process(bkp_instance *p, const void *const *in, int n_in, void *const *out, int n_out, uint32_t frames, int f64) {
    if (!p || frames == 0) return;
    const size_t bytes = (size_t)frames * (f64 ? sizeof(double) : sizeof(float));
    const bool have_in = in != nullptr && n_in > 0;

    // the tap first (in place, out[c] may be in[c]; the copy below leaves those samples as they are)
    p->inside.fetch_add(1, std::memory_order_seq_cst);
    bk_analyzer *a = p->live.load(std::memory_order_seq_cst);
    if (a && have_in && !p->bypass.load(std::memory_order_relaxed)) {
        const int n = n_in < kMaxCh ? n_in : kMaxCh;
        bool all = true;
        for (int c = 0; c < n; c++) all = all && in[c] != nullptr;
        if (all && !f64) {
            bk_analyzer_push_channels(a, reinterpret_cast<const float *const *>(in), n, frames);
        } else if (all) {
            for (uint32_t done = 0; done < frames;) {
                const uint32_t k = frames - done < kScratch ? frames - done : kScratch;
                for (int c = 0; c < n; c++) {
                    const double *src = static_cast<const double *>(in[c]) + done;
                    float *dst = p->scratch_ch[c];
                    for (uint32_t i = 0; i < k; i++) dst[i] = (float)src[i];
                }
                bk_analyzer_push_channels(a, p->scratch_ch, n, k);
                done += k;
            }
        }
    }
    p->inside.fetch_sub(1, std::memory_order_seq_cst);

    // pass-through: N in, N out; outputs without an input are silence
    if (!out) return;
    for (int c = 0; c < n_out; c++) {
        if (!out[c]) continue;
        if (have_in && c < n_in && in[c]) {
            if (in[c] != out[c]) memmove(out[c], in[c], bytes);
        } else {
            memset(out[c], 0, bytes);
        }
    }
}

void bkp_set_bypass(bkp_instance *p, int on) {
    if (p) p->bypass.store(on ? 1 : 0, std::memory_order_relaxed);
}
int bkp_bypass(const bkp_instance *p) { return p ? p->bypass.load(std::memory_order_relaxed) : 0; }

void bkp_set_host_tempo(bkp_instance *p, double bpm) {
    if (p) p->host_tempo.store(std::isfinite(bpm) && bpm > 0.0 ? bpm : 0.0, std::memory_order_relaxed);
}
double bkp_host_tempo(const bkp_instance *p) { return p ? p->host_tempo.load(std::memory_order_relaxed) : 0.0; }

void bkp_snapshot(bkp_instance *p, bk_snapshot *out) {
    if (!out) return;
    *out = bk_snapshot{};
    if (!p) return;
    std::lock_guard<std::mutex> g(p->mu);
    if (bk_analyzer *a = p->live.load()) {
        bk_analyzer_snapshot(a, out);
        if (out->has_reading) {
            p->held = out->reading;
            p->has_held = true;
            return;
        }
    }
    if (p->has_held) {
        out->has_reading = 1;
        out->reading = p->held;
    }
}

void bkp_new_song(bkp_instance *p) {
    if (!p) return;
    std::lock_guard<std::mutex> g(p->mu);
    p->has_held = false;
    if (bk_analyzer *a = p->live.load()) bk_analyzer_new_song(a);
}

const char *bkp_status(bkp_instance *p, char *buf, size_t cap) {
    if (!buf || !cap) return "";
    buf[0] = 0;
    if (!p) return buf;
    std::lock_guard<std::mutex> g(p->mu);
    std::string s = p->why_not;
    if (s.empty()) {
        if (bk_analyzer *a = p->live.load()) {
            bk_snapshot snap;
            bk_analyzer_snapshot(a, &snap);
            if (snap.error) s = "Analysis stopped after an error. Report sends the log.";
        }
    }
    snprintf(buf, cap, "%s", s.c_str());
    return buf;
}

int bkp_set_pin(bkp_instance *p, const char *key) {
    if (!p) return -1;
    std::lock_guard<std::mutex> g(p->mu);
    if (!key || !*key) {
        p->pin[0] = 0;
        return 0;
    }
    if (bk_key_index(key) < 0) {
        bkp_log(p, "REFUSED: pin '%.16s' is not a key name", key);
        return -1;
    }
    snprintf(p->pin, sizeof p->pin, "%s", key);
    return 0;
}

const char *bkp_pin(bkp_instance *p, char *buf, size_t cap) {
    if (!buf || !cap) return "";
    buf[0] = 0;
    if (!p) return buf;
    std::lock_guard<std::mutex> g(p->mu);
    snprintf(buf, cap, "%s", p->pin);
    return buf;
}

int bkp_set_tempo_mult(bkp_instance *p, int mult) {
    if (!p) return -1;
    if (mult < -1 || mult > 1) {
        bkp_log(p, "REFUSED: tempo multiplier %d (only -1 halve, 0, +1 double)", mult);
        return -1;
    }
    std::lock_guard<std::mutex> g(p->mu);
    p->mult = mult;
    return 0;
}

int bkp_tempo_mult(bkp_instance *p) {
    if (!p) return 0;
    std::lock_guard<std::mutex> g(p->mu);
    return p->mult;
}

int bkp_key_in_use(bkp_instance *p, char *buf, size_t cap) {
    if (!p || !buf || !cap) return -1;
    buf[0] = 0;
    char pin[4];
    {
        std::lock_guard<std::mutex> g(p->mu);
        memcpy(pin, p->pin, sizeof pin);
    }
    if (pin[0]) {
        snprintf(buf, cap, "%s", pin);
        return 0;
    }
    bk_snapshot s;
    bkp_snapshot(p, &s);
    if (!s.has_reading || s.reading.keys[0].percent <= 0.0) return -1;   // nothing tonal heard yet
    snprintf(buf, cap, "%s", s.reading.keys[0].name);
    return 0;
}

int bkp_bpm_in_use(bkp_instance *p, double *bpm) {
    if (!p || !bpm) return -1;
    *bpm = 0.0;
    bk_snapshot s;
    bkp_snapshot(p, &s);
    double v = 0.0;
    if (s.has_reading && s.reading.has_bpm_exact && s.reading.bpm_exact > 0.0) v = s.reading.bpm_exact;
    else if (s.has_reading && s.reading.has_bpm && s.reading.bpm > 0.0) v = s.reading.bpm;
    if (v <= 0.0) return -1;
    const int m = bkp_tempo_mult(p);
    *bpm = m > 0 ? v * 2.0 : m < 0 ? v / 2.0 : v;
    return 0;
}

void bkp_log_send(bkp_instance *p, const char *what, const char *value, int ok, const char *outcome) {
    bkp_log(p, "SEND %s %s: %s%s", what ? what : "?", value ? value : "", ok ? "" : "FAILED: ",
            outcome && *outcome ? outcome : (ok ? "sent" : "no reason given"));
}

size_t bkp_state_save(bkp_instance *p, uint8_t *buf, size_t cap) {
    if (!p) return 0;
    if (!buf || cap < kHeader + kPayloadV1) {
        bkp_log(p, "REFUSED: state save given %zu bytes of room, it needs %zu", buf ? cap : 0, kHeader + kPayloadV1);
        return 0;
    }
    bk_snapshot s;
    bkp_snapshot(p, &s);   // refreshes the held reading
    std::lock_guard<std::mutex> g(p->mu);
    Put w{buf + kHeader};
    put_payload(w, p, p->has_held, p->held);
    if (w.n != kPayloadV1) {   // a layout change without a new version would corrupt every session
        bkp_log(p, "REFUSED: state payload is %zu bytes, the layout says %zu", w.n, kPayloadV1);
        return 0;
    }
    Put h{buf};
    h.u32(BKP_STATE_MAGIC);
    h.u16(BKP_STATE_VERSION);
    h.u16(0);
    h.u32((uint32_t)kPayloadV1);
    h.u32(fnv1a(buf + kHeader, kPayloadV1));
    return kHeader + kPayloadV1;
}

int bkp_state_load(bkp_instance *p, const uint8_t *buf, size_t len, char *err, size_t err_cap) {
    if (err && err_cap) err[0] = 0;
    if (!p) return -1;
    char why[200] = {0};
    auto refuse = [&](void) {
        if (err && err_cap) snprintf(err, err_cap, "%s", why);
        bkp_log(p, "REFUSED: the session's saved state (%zu bytes): %s; kept what the instance had", len, why);
        return -1;
    };
    if (len == 0) return 0;   // nothing saved: a fresh instance
    if (!buf) { snprintf(why, sizeof why, "the host gave a length but no bytes"); return refuse(); }
    if (len > BKP_STATE_CAP) { snprintf(why, sizeof why, "over the %d byte cap", BKP_STATE_CAP); return refuse(); }
    if (len < kHeader) { snprintf(why, sizeof why, "cut short (no header)"); return refuse(); }
    Get h{buf};
    const uint32_t magic = h.u32();
    const unsigned version = h.u16(), reserved = h.u16();
    const uint32_t plen = h.u32(), sum = h.u32();
    if (magic != BKP_STATE_MAGIC) { snprintf(why, sizeof why, "not a Beat Key state"); return refuse(); }
    if (version > BKP_STATE_VERSION) {
        snprintf(why, sizeof why, "saved by a newer Beat Key (state version %u; this one reads %d)", version, BKP_STATE_VERSION);
        return refuse();
    }
    if (version == 0 || reserved != 0) { snprintf(why, sizeof why, "damaged header"); return refuse(); }
    if (plen != len - kHeader) {
        snprintf(why, sizeof why, "%s (header says %u payload bytes, %zu present)", plen > len - kHeader ? "cut short" : "trailing bytes",
                 plen, len - kHeader);
        return refuse();
    }
    if (plen != kPayloadV1) { snprintf(why, sizeof why, "payload is %u bytes, version 1 has %zu", plen, kPayloadV1); return refuse(); }
    if (fnv1a(buf + kHeader, plen) != sum) { snprintf(why, sizeof why, "damaged (checksum)"); return refuse(); }

    Get r{buf + kHeader};
    const unsigned flags = r.u8();
    const int mult = (int8_t)r.u8();
    char raw[4], pin[4] = {0};
    r.name(raw);
    bk_reading x{};
    for (int i = 0; i < 3; i++) {
        char n[4];
        r.name(n);
        memcpy(x.keys[i].name, n, 4);
        x.keys[i].percent = r.f64();
    }
    x.has_tuning = r.u8();
    x.tuning_cents = r.f64();
    for (int i = 0; i < 12; i++) x.chroma[i] = r.f64();
    x.has_bpm = r.u8();
    x.bpm = r.f64();
    x.has_bpm_exact = r.u8();
    x.bpm_exact = r.f64();
    x.secs = r.f64();

    if (flags & ~3u) { snprintf(why, sizeof why, "unknown flags 0x%x", flags); return refuse(); }
    if (mult < -1 || mult > 1) { snprintf(why, sizeof why, "tempo multiplier %d", mult); return refuse(); }
    if ((flags & 1) && !name_ok(raw, pin)) { snprintf(why, sizeof why, "the pinned key is not a key name"); return refuse(); }
    if (!(flags & 1) && (raw[0] || raw[1] || raw[2] || raw[3])) { snprintf(why, sizeof why, "a pin without its flag"); return refuse(); }
    const bool has = flags & 2;
    if (has) {
        for (int i = 0; i < 3; i++) {
            char n[4];
            if (!name_ok(x.keys[i].name, n)) { snprintf(why, sizeof why, "reading key %d is not a key name", i + 1); return refuse(); }
            if (!in(x.keys[i].percent, 0.0, 100.0)) { snprintf(why, sizeof why, "reading key %d percent out of range", i + 1); return refuse(); }
        }
        for (int i = 0; i < 12; i++)
            if (!in(x.chroma[i], 0.0, 1.0)) { snprintf(why, sizeof why, "chroma out of range"); return refuse(); }
        if (x.has_tuning > 1 || x.has_bpm > 1 || x.has_bpm_exact > 1) { snprintf(why, sizeof why, "damaged flags in the reading"); return refuse(); }
        if (!in(x.tuning_cents, -50.0, 50.0) || !in(x.bpm, 0.0, 1000.0) || !in(x.bpm_exact, 0.0, 1000.0) ||
            !in(x.secs, 0.0, 1e9)) {
            snprintf(why, sizeof why, "a value in the reading is out of range");
            return refuse();
        }
    }

    std::lock_guard<std::mutex> g(p->mu);
    memcpy(p->pin, (flags & 1) ? pin : "\0\0\0", 4);
    p->mult = mult;
    p->has_held = has;
    p->held = has ? x : bk_reading{};
    bkp_log(p, "session state restored: pin %s, tempo x%s, %s", p->pin[0] ? p->pin : "none",
            mult > 0 ? "2" : mult < 0 ? "1/2" : "1", has ? "last reading kept" : "no reading");
    return 0;
}

const char *bkp_format(const bkp_instance *p) { return p ? p->format.c_str() : ""; }

}  // extern "C"
