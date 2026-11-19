/*
 * bkp_test.cpp: the instance layer's tests (plan step 7), run by plugin/test.sh on both slices.
 *   passthru   bkp_process copies N in to N out (float and double, in place, extra outputs silent),
 *              with and without weights, bypassed or not
 *   tripwire   the real audio path (float, double, bypass, host tempo) under the core's tripwire:
 *              0 allocations and 0 locks on the thread that plays the audio thread
 *   live       real analysis through the layer: a reading, key / BPM in use, pin, x2 / /2,
 *              the rate swapped while an audio thread keeps calling bkp_process
 *   state      the blob round-trips byte for byte; every refusal (garbage, cut short, trailing bytes,
 *              over the cap, newer version, damaged, out-of-range values) is refused, logged, and
 *              leaves the instance as it was
 *   marker     the "host died with Beat Key in it" marker: a dead process's marker is reported once
 *              and removed; ours exists while an instance is open and is gone after the last
 *   clip       a whole clip (AudioSuite Analyze, step 14): fed in odd windows it reads exactly as the core's
 *              file path reads the same mono; the reading becomes the instance's (buttons, state); every
 *              refusal is logged, keeps the old reading and tells the face
 * Usage: bkp_test <weights.bkw> <scratch folder> [passthru|tripwire|live|state|marker|clip ...]
 * BEATKEY_LOG_DIR must point inside the scratch folder (plugin/test.sh sets it).
 */
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

#include "../shared/bkp.h"

extern "C" {
void tw_arm(void);
void tw_disarm(void);
long tw_mallocs(void);
long tw_locks(void);
}

namespace {

int g_failed = 0, g_checks = 0;

#define CHECK(cond, ...)                                             \
    do {                                                             \
        g_checks++;                                                  \
        if (!(cond)) {                                               \
            g_failed++;                                              \
            printf("  FAIL %s:%d: %s: ", __FILE__, __LINE__, #cond); \
            printf(__VA_ARGS__);                                     \
            printf("\n");                                            \
        }                                                            \
    } while (0)

std::string g_scratch, g_weights;

std::string read_all(const std::string &path) {
    std::ifstream f(path, std::ios::binary);
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}
std::string log_text() {
    char buf[1024];
    return read_all(bk_log_path(buf, sizeof buf));
}
size_t log_mark() { return log_text().size(); }
bool log_has_since(size_t mark, const char *needle) {
    const std::string t = log_text();
    return t.size() >= mark && t.find(needle, mark) != std::string::npos;
}
bool exists(const std::string &p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0;
}
void sleep_ms(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

// An A-minor chord with a click every beat at `bpm` (the core test's clip).
std::vector<float> clip(double rate, double secs, double bpm) {
    const size_t n = (size_t)(rate * secs);
    std::vector<float> x(n);
    const double notes[3] = {220.0, 261.6256, 329.6276};
    const double beat = 60.0 / bpm;
    for (size_t i = 0; i < n; i++) {
        const double t = (double)i / rate;
        double v = 0;
        for (double f : notes) v += 0.12 * std::sin(2 * M_PI * f * t) + 0.04 * std::sin(2 * M_PI * 2 * f * t);
        const double since = std::fmod(t, beat);
        v += 0.5 * std::exp(-since * 60.0) * std::sin(2 * M_PI * 1800.0 * since);
        x[i] = (float)v;
    }
    return x;
}

bkp_instance *make(const char *format, bool weights = true) {
    bkp_config c = {format, weights ? nullptr : "com.example.not-loaded", weights ? g_weights.c_str() : nullptr, "test.host"};
    return bkp_create(&c);
}

// Feeds `x` (mono, duplicated to stereo) in blocks of 512 at about 20x real time, so the worker keeps up.
void feed(bkp_instance *p, const std::vector<float> &x, double rate) {
    std::vector<float> l(512), r(512);
    const size_t half = (size_t)(rate / 2);
    for (size_t at = 0; at < x.size();) {
        const size_t n = std::min<size_t>(512, x.size() - at);
        std::copy(x.begin() + (long)at, x.begin() + (long)(at + n), l.begin());
        std::copy(x.begin() + (long)at, x.begin() + (long)(at + n), r.begin());
        const void *in[2] = {l.data(), r.data()};
        void *out[2] = {l.data(), r.data()};
        bkp_process(p, in, 2, out, 2, (uint32_t)n, 0);
        at += n;
        if (at % half < 512) sleep_ms(25);
    }
}

// Waits until the instance's analyzer has made `want` readings (or 20 s).
bool wait_readings(bkp_instance *p, uint64_t want) {
    for (int i = 0; i < 2000; i++) {
        bk_snapshot s;
        bkp_snapshot(p, &s);
        if (s.readings >= want) return true;
        sleep_ms(10);
    }
    return false;
}

// Waits until the reading carries a BPM (12 s heard; the worker may lag the feed under Rosetta).
bool wait_bpm(bkp_instance *p) {
    for (int i = 0; i < 3000; i++) {
        bk_snapshot s;
        bkp_snapshot(p, &s);
        if (s.has_reading && s.reading.has_bpm) return true;
        sleep_ms(10);
    }
    return false;
}

// ------------------------------------------------------------------ passthru
void test_passthru() {
    printf("== pass-through (no weights path: still a clean pass-through)\n");
    size_t mark = log_mark();
    bkp_instance *p = make("TEST", false);
    CHECK(p != nullptr, "create returned NULL");
    CHECK(log_has_since(mark, "plug-in opened: host test.host"), "no open line");
    char st[256];
    // weights may already be loaded by an earlier test in this process; only then is status empty
    if (!bk_ready()) {
        CHECK(strstr(bkp_status(p, st, sizeof st), "incomplete") != nullptr, "status '%s'", st);
        CHECK(log_has_since(mark, "REFUSED: no weights file (bundle com.example.not-loaded is not loaded)"), "no refusal line");
        CHECK(bkp_prepare(p, 48000) != 0, "prepare analyzed without weights");
    }
    for (int f64 = 0; f64 < 2; f64++) {
        const size_t sz = f64 ? sizeof(double) : sizeof(float);
        std::vector<uint8_t> a(256 * sz), b(256 * sz), o0(256 * sz, 0xAA), o1(256 * sz, 0xAA), o2(256 * sz, 0xAA);
        for (size_t i = 0; i < a.size(); i++) { a[i] = (uint8_t)(i * 7 + 1); b[i] = (uint8_t)(i * 13 + 5); }
        const void *in[2] = {a.data(), b.data()};
        void *out[3] = {o0.data(), o1.data(), o2.data()};
        for (int byp = 0; byp < 2; byp++) {
            bkp_set_bypass(p, byp);
            bkp_process(p, in, 2, out, 3, 256, f64);
            CHECK(o0 == a && o1 == b, "f64 %d bypass %d: outputs differ from inputs", f64, byp);
            CHECK(std::all_of(o2.begin(), o2.end(), [](uint8_t v) { return v == 0; }), "f64 %d: extra output not silent", f64);
        }
        // in place
        std::vector<uint8_t> keep = a;
        const void *in2[1] = {a.data()};
        void *out2[1] = {a.data()};
        bkp_process(p, in2, 1, out2, 1, 256, f64);
        CHECK(a == keep, "f64 %d: in place changed the samples", f64);
        // no input at all = silence out
        std::fill(o0.begin(), o0.end(), 0x55);
        void *out3[1] = {o0.data()};
        bkp_process(p, nullptr, 0, out3, 1, 256, f64);
        CHECK(std::all_of(o0.begin(), o0.end(), [](uint8_t v) { return v == 0; }), "f64 %d: no input, output not silent", f64);
    }
    bkp_set_bypass(p, 1);
    CHECK(bkp_bypass(p) == 1, "bypass did not read back");
    bkp_set_host_tempo(p, 141.98);
    CHECK(bkp_host_tempo(p) == 141.98, "host tempo %.3f", bkp_host_tempo(p));
    bkp_set_host_tempo(p, NAN);
    CHECK(bkp_host_tempo(p) == 0.0, "NaN host tempo kept: %.3f", bkp_host_tempo(p));
    bkp_process(nullptr, nullptr, 0, nullptr, 0, 64, 0);   // NULL instance: nothing, no crash
    mark = log_mark();
    bkp_destroy(p);
    CHECK(log_has_since(mark, "plug-in closed"), "no close line");
}

// ------------------------------------------------------------------ tripwire
void test_tripwire() {
    printf("== the audio path under the tripwire\n");
    bkp_instance *p = make("TEST");
    CHECK(bkp_prepare(p, 44100) == 0, "prepare failed");
    std::vector<float> x = clip(44100, 3.0, 120);
    std::vector<double> xd(x.begin(), x.end());
    std::vector<float> o0(1024), o1(1024);
    std::vector<double> d0(1024), d1(1024);
    long mallocs = 0, locks = 0;
    for (int pass = 0; pass < 4; pass++) {   // float, double, bypassed float, more than 64 channels' worth of pointers
        const bool f64 = pass == 1;
        bkp_set_bypass(p, pass == 2);
        for (size_t at = 0; at + 1024 <= x.size(); at += 1024) {
            const void *in[2] = {f64 ? (const void *)&xd[at] : (const void *)&x[at], f64 ? (const void *)&xd[at] : (const void *)&x[at]};
            void *out[2] = {f64 ? (void *)d0.data() : (void *)o0.data(), f64 ? (void *)d1.data() : (void *)o1.data()};
            const void *wide[80];
            for (auto &w : wide) w = &x[at];
            std::vector<float> wo(1024);
            void *wout[1] = {wo.data()};
            tw_arm();
            if (pass == 3) bkp_process(p, wide, 80, wout, 1, 1024, 0);
            else bkp_process(p, in, 2, out, 2, 1024, f64);
            bkp_set_host_tempo(p, 120.0 + (double)at);
            (void)bkp_host_tempo(p);
            (void)bkp_bypass(p);
            tw_disarm();
            mallocs += tw_mallocs();
            locks += tw_locks();
        }
        sleep_ms(50);
    }
    CHECK(mallocs == 0, "the audio path allocated %ld times", mallocs);
    CHECK(locks == 0, "the audio path locked %ld times", locks);
    // the tripwire is armed for real: a lock on the armed thread is seen
    tw_arm();
    bk_snapshot s;
    bkp_snapshot(p, &s);
    tw_disarm();
    CHECK(tw_locks() >= 1, "tripwire saw no lock in bkp_snapshot (it takes the instance lock): is it counting?");
    bkp_destroy(p);
}

// ------------------------------------------------------------------ live
void test_live() {
    printf("== real analysis through the layer\n");
    bkp_instance *p = make("TEST");
    CHECK(bkp_prepare(p, 44100) == 0, "prepare failed");
    char st[256];
    CHECK(bkp_status(p, st, sizeof st)[0] == 0, "status while analyzing: '%s'", st);
    char key[8];
    double bpm = 0;
    CHECK(bkp_key_in_use(p, key, sizeof key) == -1, "a key before any audio: %s", key);
    CHECK(bkp_bpm_in_use(p, &bpm) == -1, "a BPM before any audio: %.2f", bpm);
    feed(p, clip(44100, 16.0, 120), 44100);
    CHECK(wait_readings(p, 5) && wait_bpm(p), "no BPM reading after 16 s of audio");
    bk_snapshot s;
    bkp_snapshot(p, &s);
    CHECK(s.has_reading && s.reading.has_bpm, "no BPM in the reading");
    CHECK(bkp_key_in_use(p, key, sizeof key) == 0 && strcmp(key, s.reading.keys[0].name) == 0, "key in use '%s' vs '%s'", key,
          s.reading.keys[0].name);
    CHECK(bkp_bpm_in_use(p, &bpm) == 0 && bpm > 0, "no BPM in use");
    const double base = bpm;
    CHECK(std::fabs(base - 120.0) < 1.0, "BPM %.2f for a 120 BPM click", base);
    bkp_set_tempo_mult(p, 1);
    bkp_bpm_in_use(p, &bpm);
    CHECK(bpm == base * 2, "x2 gives %.2f", bpm);
    bkp_set_tempo_mult(p, -1);
    bkp_bpm_in_use(p, &bpm);
    CHECK(bpm == base / 2, "/2 gives %.2f", bpm);
    size_t mark = log_mark();
    CHECK(bkp_set_tempo_mult(p, 3) == -1 && bkp_tempo_mult(p) == -1, "multiplier 3 accepted");
    CHECK(log_has_since(mark, "REFUSED: tempo multiplier 3"), "no log line for the refused multiplier");
    CHECK(bkp_set_pin(p, "F#m") == 0, "pin F#m refused");
    CHECK(bkp_key_in_use(p, key, sizeof key) == 0 && strcmp(key, "F#m") == 0, "pinned key in use '%s'", key);
    mark = log_mark();
    CHECK(bkp_set_pin(p, "Gbm") == -1, "pin Gbm accepted (not the core's spelling)");
    CHECK(log_has_since(mark, "REFUSED: pin 'Gbm'"), "no log line for the refused pin");
    char pin[8];
    CHECK(strcmp(bkp_pin(p, pin, sizeof pin), "F#m") == 0, "pin changed by a refusal: %s", pin);
    bkp_set_pin(p, nullptr);
    CHECK(bkp_pin(p, pin, sizeof pin)[0] == 0, "unpin left '%s'", pin);
    mark = log_mark();
    bkp_log_send(p, "AUTO-TUNE", "Am", 1, "wrote Auto-Key.handoff");
    bkp_log_send(p, "BPM", "120.00", 0, "");
    CHECK(log_has_since(mark, "SEND AUTO-TUNE Am: wrote Auto-Key.handoff"), "no send line");
    CHECK(log_has_since(mark, "SEND BPM 120.00: FAILED: no reason given"), "no failed send line");

    printf("== the rate swapped while the audio thread runs\n");
    std::atomic<bool> stop{false};
    std::atomic<long> blocks{0};
    std::thread audio([&] {
        std::vector<float> x = clip(48000, 1.0, 100);
        std::vector<float> o(480);
        for (size_t at = 0; !stop.load(); at = (at + 480) % (x.size() - 480)) {
            const void *in[1] = {&x[at]};
            void *out[1] = {o.data()};
            bkp_process(p, in, 1, out, 1, 480, 0);
            blocks++;
            if (memcmp(o.data(), &x[at], 480 * sizeof(float)) != 0) { stop = true; break; }
            std::this_thread::sleep_for(std::chrono::microseconds(200));
        }
    });
    mark = log_mark();
    const double rates[] = {48000, 96000, 44100, 48000, 88200, 48000};
    int ok = 0;
    for (double r : rates) {
        ok += bkp_prepare(p, r) == 0;
        sleep_ms(30);
    }
    stop = true;
    audio.join();
    CHECK(ok == 6, "%d of 6 prepares succeeded", ok);
    CHECK(blocks > 50, "the audio thread ran only %ld blocks", blocks.load());
    CHECK(log_has_since(mark, "sample rate 44100 -> 48000 Hz"), "no log line for the rate change");
    bkp_snapshot(p, &s);
    CHECK(s.has_reading && s.reading.has_bpm, "the reading was lost across rate changes");
    CHECK(bkp_prepare(p, 48000) == 0, "same rate again");
    mark = log_mark();
    CHECK(bkp_prepare(p, 1000) != 0, "1000 Hz accepted");
    CHECK(bkp_status(p, st, sizeof st)[0] != 0 && strstr(st, "1000") != nullptr, "status after a refused rate: '%s'", st);
    CHECK(log_has_since(mark, "REFUSED"), "no log line for the refused rate");
    CHECK(bkp_prepare(p, 48000) == 0 && bkp_status(p, st, sizeof st)[0] == 0, "did not recover: '%s'", st);
    bkp_new_song(p);
    bkp_destroy(p);
}

// ------------------------------------------------------------------ state
std::vector<uint8_t> save(bkp_instance *p) {
    std::vector<uint8_t> b(BKP_STATE_CAP);
    b.resize(bkp_state_save(p, b.data(), b.size()));
    return b;
}

void put_u32(std::vector<uint8_t> &b, size_t at, uint32_t v) {
    for (int i = 0; i < 4; i++) b[at + (size_t)i] = (uint8_t)(v >> (8 * i));
}
uint32_t fnv(const uint8_t *p, size_t n) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 16777619u; }
    return h;
}
void reseal(std::vector<uint8_t> &b) { put_u32(b, 12, fnv(b.data() + 16, b.size() - 16)); }

void test_state() {
    printf("== state blob\n");
    bkp_instance *a = make("TEST");
    CHECK(bkp_prepare(a, 44100) == 0, "prepare failed");
    feed(a, clip(44100, 14.0, 128), 44100);
    CHECK(wait_bpm(a), "no BPM reading to save");
    bkp_set_pin(a, "Ebm");
    bkp_set_tempo_mult(a, 1);
    const std::vector<uint8_t> blob = save(a);
    CHECK(blob.size() == 189, "blob is %zu bytes", blob.size());
    CHECK(blob.size() > 4 && memcmp(blob.data(), "BKPS", 4) == 0, "magic");
    uint8_t tiny[8];
    size_t mark = log_mark();
    CHECK(bkp_state_save(a, tiny, sizeof tiny) == 0, "saved into 8 bytes");
    CHECK(log_has_since(mark, "REFUSED: state save given 8 bytes"), "no log line for a short buffer");

    // round trip into a fresh instance that never heard audio
    bkp_instance *b = make("TEST");
    char err[256];
    mark = log_mark();
    CHECK(bkp_state_load(b, blob.data(), blob.size(), err, sizeof err) == 0, "refused its own blob: %s", err);
    CHECK(log_has_since(mark, "session state restored: pin Ebm, tempo x2, last reading kept"), "no restore line");
    CHECK(save(b) == blob, "re-saved blob differs");
    bk_snapshot sa, sb;
    bkp_snapshot(a, &sa);
    bkp_snapshot(b, &sb);
    CHECK(sb.has_reading && sb.readings == 0, "restored reading not shown (has %d, readings %llu)", sb.has_reading,
          (unsigned long long)sb.readings);
    CHECK(memcmp(&sa.reading, &sb.reading, sizeof sa.reading) == 0, "restored reading differs from the saved one");
    double ba = 0, bb = 0;
    bkp_bpm_in_use(a, &ba);
    bkp_bpm_in_use(b, &bb);
    CHECK(ba == bb && bb > 0, "BPM in use after restore %.2f vs %.2f", bb, ba);
    char key[8];
    CHECK(bkp_key_in_use(b, key, sizeof key) == 0 && strcmp(key, "Ebm") == 0, "key in use after restore: %s", key);
    CHECK(bkp_state_load(b, nullptr, 0, err, sizeof err) == 0 && save(b) == blob, "an empty state changed the instance");

    // a fresh instance's blob (no pin, no reading) round-trips too
    bkp_instance *c = make("TEST");
    const std::vector<uint8_t> fresh = save(c);
    CHECK(bkp_state_load(b, fresh.data(), fresh.size(), err, sizeof err) == 0 && save(b) == fresh, "fresh blob round trip");
    CHECK(bkp_state_load(b, blob.data(), blob.size(), err, sizeof err) == 0, "reload");

    struct Bad {
        const char *name, *want;
        std::vector<uint8_t> bytes;
    };
    std::vector<Bad> bad;
    bad.push_back({"garbage", "not a Beat Key state", std::vector<uint8_t>(189, 'x')});
    bad.push_back({"cut-short-header", "cut short (no header)", std::vector<uint8_t>(blob.begin(), blob.begin() + 10)});
    bad.push_back({"cut-short", "cut short", std::vector<uint8_t>(blob.begin(), blob.end() - 1)});
    {
        std::vector<uint8_t> t = blob;
        t.push_back(0);
        bad.push_back({"trailing", "trailing bytes", t});
    }
    bad.push_back({"oversize", "over the 4096 byte cap", std::vector<uint8_t>(BKP_STATE_CAP + 1, 0)});
    {
        std::vector<uint8_t> t = blob;
        t[4] = 2;   // version 2
        bad.push_back({"newer", "saved by a newer Beat Key (state version 2", t});
    }
    {
        std::vector<uint8_t> t = blob;
        t[4] = 0;
        bad.push_back({"version-0", "damaged header", t});
    }
    {
        std::vector<uint8_t> t = blob;
        t[40] ^= 0x01;
        bad.push_back({"checksum", "damaged (checksum)", t});
    }
    {
        std::vector<uint8_t> t = blob;
        t[16 + 2] = 'H';   // pin "Hbm"
        reseal(t);
        bad.push_back({"pin", "pinned key is not a key name", t});
    }
    {
        std::vector<uint8_t> t = blob;
        t[16 + 1] = 2;     // tempo x4
        reseal(t);
        bad.push_back({"mult", "tempo multiplier 2", t});
    }
    {
        std::vector<uint8_t> t = blob;
        const double nan = NAN;
        memcpy(&t[16 + 6 + 4], &nan, 8);   // key 1 percent
        reseal(t);
        bad.push_back({"nan", "percent out of range", t});
    }
    {
        std::vector<uint8_t> t = blob;
        t[16] = 0x80;      // unknown flag
        reseal(t);
        bad.push_back({"flags", "unknown flags", t});
    }
    {
        std::vector<uint8_t> t = blob;
        const double big = 5000.0;
        memcpy(&t[16 + 6 + 36 + 9 + 96 + 1], &big, 8);   // bpm
        reseal(t);
        bad.push_back({"bpm", "out of range", t});
    }
    for (const Bad &x : bad) {
        mark = log_mark();
        CHECK(bkp_state_load(b, x.bytes.data(), x.bytes.size(), err, sizeof err) == -1, "%s accepted", x.name);
        CHECK(strstr(err, x.want) != nullptr, "%s: sentence '%s' lacks '%s'", x.name, err, x.want);
        CHECK(log_has_since(mark, "REFUSED: the session's saved state"), "%s: no log line", x.name);
        CHECK(save(b) == blob, "%s: the refusal changed the instance", x.name);
    }
    CHECK(bkp_state_load(b, nullptr, 5, err, sizeof err) == -1, "NULL bytes with a length accepted");
    bkp_destroy(c);
    bkp_destroy(b);
    bkp_destroy(a);
}

// ------------------------------------------------------------------ clip
// Feeds n channels in host-sized windows (sizes cycle, the way an AudioSuite pass may hand them).
long feed_clip(bkp_instance *p, const std::vector<std::vector<float>> &ch, size_t frames) {
    static const uint32_t sizes[] = {1024, 4096, 333, 8192, 1};
    std::vector<const float *> ptr(ch.size());
    long kept = 0;
    for (size_t at = 0, i = 0; at < frames; i++) {
        const uint32_t n = (uint32_t)std::min<size_t>(sizes[i % 5], frames - at);
        for (size_t c = 0; c < ch.size(); c++) ptr[c] = ch[c].data() + at;
        const long k = bkp_clip_add(p, ptr.data(), (int)ch.size(), n);
        if (k < 0) return -1;
        kept += k;
        at += n;
    }
    return kept;
}

bool same_reading(const bk_reading &a, const bk_reading &b) { return memcmp(&a, &b, sizeof a) == 0; }

void test_clip() {
    printf("== whole clip (AudioSuite Analyze): the core's file path, the instance's reading, every refusal\n");
    const double rate = 48000.0;
    const size_t n = (size_t)(rate * 20);
    std::vector<float> l = clip(rate, 20, 120.0), r = clip(rate, 20, 120.0);
    for (size_t i = 0; i < n; i++) r[i] = 0.6f * r[i] + 0.05f * (float)std::sin(2 * M_PI * 98.0 * (double)i / rate);
    std::vector<float> mono(n);
    for (size_t i = 0; i < n; i++) mono[i] = (l[i] + r[i]) / 2.0f;   // the core's downmix, stereo = 0.5 * (L + R)
    bkp_instance *p = make("AAX");   // loads the weights (once per process)
    bk_reading ref{};
    char err[256] = {0};
    CHECK(bk_analyze_buffer(mono.data(), n, rate, &ref, err, sizeof err) == BK_OK, "the core refused the reference: %s", err);

    CHECK(bkp_clip_state(p) == 0, "a fresh instance claims to read clips");
    bkp_use_clips(p);
    CHECK(bkp_clip_state(p) == 1, "bkp_use_clips did not take");
    char st[256];
    CHECK(bkp_status(p, st, sizeof st)[0] == 0, "a whole-clip instance has a status before any clip: '%s'", st);
    bk_snapshot s;
    bkp_snapshot(p, &s);
    CHECK(!s.has_reading, "a reading before any clip");

    size_t mark = log_mark();
    CHECK(bkp_clip_begin(p, rate, n, err, sizeof err) == 0, "begin refused: %s", err);
    uint64_t have = 1, want = 0;
    bkp_clip_progress(p, &have, &want);
    CHECK(have == 0 && want == n, "progress after begin: %llu / %llu", (unsigned long long)have, (unsigned long long)want);
    // 700 frames past the announced length: not kept
    std::vector<std::vector<float>> st2 = {l, r};
    st2[0].resize(n + 700, 0.9f);
    st2[1].resize(n + 700, 0.9f);
    CHECK(feed_clip(p, st2, n + 700) == (long)n, "frames past the announced length were kept");
    bkp_clip_progress(p, &have, &want);
    CHECK(have == n, "progress at the end: %llu", (unsigned long long)have);
    bk_reading got{};
    CHECK(bkp_clip_end(p, "AudioSuite Analyze", &got, err, sizeof err) == 0, "end refused: %s", err);
    CHECK(same_reading(got, ref), "the clip's reading is not the core's file reading of the same mono (%s %.1f / %.2f vs %s %.1f / %.2f)",
          got.keys[0].name, got.keys[0].percent, got.bpm_exact, ref.keys[0].name, ref.keys[0].percent, ref.bpm_exact);
    CHECK(log_has_since(mark, "AudioSuite Analyze: 2 ch, 20.0 s at 48000 Hz -> "), "no AudioSuite log line for the run");
    CHECK(bkp_clip_state(p) == 1, "still analyzing after the end");
    bkp_snapshot(p, &s);
    CHECK(s.has_reading && same_reading(s.reading, ref), "the instance's reading is not the clip's");
    char key[8];
    CHECK(bkp_key_in_use(p, key, sizeof key) == 0 && strcmp(key, ref.keys[0].name) == 0, "key in use '%s', want '%s'", key, ref.keys[0].name);
    double bpm = 0;
    CHECK(bkp_bpm_in_use(p, &bpm) == 0 && bpm == ref.bpm_exact, "BPM in use %.2f, want %.2f", bpm, ref.bpm_exact);

    // mono, in other windows: the same answer as the core on that channel
    CHECK(bkp_clip_begin(p, rate, n, err, sizeof err) == 0, "second begin refused: %s", err);
    CHECK(feed_clip(p, {l}, n) == (long)n, "mono clip not kept");
    bk_reading monor{}, lref{};
    CHECK(bkp_clip_end(p, "AudioSuite Analyze", &monor, err, sizeof err) == 0, "mono end refused: %s", err);
    CHECK(bk_analyze_buffer(l.data(), n, rate, &lref, err, sizeof err) == BK_OK, "core refused L: %s", err);
    CHECK(same_reading(monor, lref), "a mono clip is not the core's reading of that channel");

    // the length not said: the clip grows as it comes
    CHECK(bkp_clip_begin(p, rate, 0, err, sizeof err) == 0, "begin with no length refused: %s", err);
    CHECK(feed_clip(p, {l, r}, n) == (long)n, "unannounced clip not kept whole");
    CHECK(bkp_clip_end(p, nullptr, &got, err, sizeof err) == 0 && same_reading(got, ref), "an unannounced clip read differently");

    // the session state carries a clip's reading into a live instance (reopened session)
    uint8_t blob[BKP_STATE_CAP];
    const size_t len = bkp_state_save(p, blob, sizeof blob);
    bkp_instance *q = make("AAX");
    CHECK(len > 0 && bkp_state_load(q, blob, len, err, sizeof err) == 0, "the state did not round-trip: %s", err);
    bkp_snapshot(q, &s);
    CHECK(s.has_reading && same_reading(s.reading, ref), "the restored reading is not the clip's");

    // refusals: each logged, the reading the instance had is kept, the face is told why
    mark = log_mark();
    CHECK(bkp_clip_begin(q, rate, n, err, sizeof err) == -1 && strstr(err, "plays live"), "a live instance began a clip: '%s'", err);
    CHECK(bkp_clip_begin(p, 1000.0, n, err, sizeof err) == -1 && strstr(err, "outside 8000..384000"), "rate 1000 accepted: '%s'", err);
    CHECK(bkp_clip_begin(p, rate, (uint64_t)(rate * (BKP_CLIP_MAX_SECS + 1)), err, sizeof err) == -1 && strstr(err, "reads up to"),
          "an over-long selection accepted: '%s'", err);
    const float *one[1] = {l.data()};
    CHECK(bkp_clip_add(p, one, 1, 100) == -1, "audio before a begin was kept");
    CHECK(log_has_since(mark, "audio came before the clip began"), "no log line for audio before a begin");
    CHECK(bkp_clip_end(p, "AudioSuite Analyze", &got, err, sizeof err) == -1 && strstr(err, "no clip was begun"), "end with no clip: '%s'", err);
    CHECK(bkp_clip_begin(p, rate, n, err, sizeof err) == 0, "begin after refusals refused: %s", err);
    CHECK(bkp_status(p, st, sizeof st)[0] == 0, "a new clip did not clear the last refusal: '%s'", st);
    const float *two[2] = {l.data(), r.data()};
    CHECK(bkp_clip_add(p, two, 2, 4096) == 4096, "first stereo window refused");
    CHECK(bkp_clip_add(p, one, 1, 4096) == -1, "a channel-count change mid-clip was accepted");
    CHECK(bkp_clip_add(p, two, 2, 4096) == -1, "a refused clip kept taking audio");
    CHECK(bkp_clip_end(p, "AudioSuite Analyze", &got, err, sizeof err) == -1 && strstr(err, "changed the channel count"),
          "a refused clip was read: '%s'", err);
    CHECK(log_has_since(mark, "AudioSuite Analyze REFUSED: the host changed the channel count"), "no REFUSED run line");
    CHECK(strstr(bkp_status(p, st, sizeof st), "Couldn't read the selection"), "the face is not told: '%s'", st);
    bkp_snapshot(p, &s);
    CHECK(s.has_reading && same_reading(s.reading, ref), "a refused clip changed the reading");
    const float *nul[2] = {l.data(), nullptr};
    CHECK(bkp_clip_begin(p, rate, n, err, sizeof err) == 0 && bkp_clip_add(p, nul, 2, 10) == -1, "a NULL channel was accepted");
    bkp_clip_cancel(p, "test");
    CHECK(log_has_since(mark, "whole clip dropped after 0.0 s: test"), "no log line for a cancel");
    CHECK(bkp_clip_begin(p, rate, n, err, sizeof err) == 0, "begin for the empty clip refused");
    CHECK(bkp_clip_end(p, "AudioSuite Analyze", &got, err, sizeof err) == -1 && strstr(err, "no audio"), "an empty clip was read: '%s'", err);
    std::vector<float> bad(4800, 0.1f);
    bad[100] = NAN;
    const float *b1[1] = {bad.data()};
    CHECK(bkp_clip_begin(p, rate, bad.size(), err, sizeof err) == 0 && bkp_clip_add(p, b1, 1, (uint32_t)bad.size()) == (long)bad.size(),
          "the NaN clip was not taken in");
    CHECK(bkp_clip_end(p, "AudioSuite Analyze", &got, err, sizeof err) == -1 && strstr(err, "not audio"), "a NaN clip was read: '%s'", err);

    // a whole-clip instance never prepares a live analyzer through the clip calls; NEW SONG clears its reading
    bkp_new_song(p);
    bkp_snapshot(p, &s);
    CHECK(!s.has_reading && s.readings == 0, "clear left a reading");
    bkp_destroy(q);
    bkp_destroy(p);
}

// ------------------------------------------------------------------ marker
void test_marker() {
    printf("== crash marker\n");
    char buf[1024];
    std::string dir = bk_log_path(buf, sizeof buf);
    dir = dir.substr(0, dir.rfind('/')) + "/running";
    mkdir(dir.c_str(), 0755);
    // a process that is surely gone: a child that exited and was reaped
    const pid_t kid = fork();
    if (kid == 0) _exit(0);
    int status = 0;
    waitpid(kid, &status, 0);
    const std::string dead = dir + "/" + std::to_string(kid) + "-AU";
    {
        std::ofstream f(dead);
        f << "host com.example.daw, Beat Key AU 0.0.0, loaded yesterday\n";
    }
    // a marker of a live process (our parent) must be left alone
    const std::string alive = dir + "/" + std::to_string(getppid()) + "-VST3";
    { std::ofstream f(alive); f << "host alive\n"; }
    const std::string ours = dir + "/" + std::to_string(getpid()) + "-MARK";

    size_t mark = log_mark();
    bkp_instance *p = make("MARK");
    CHECK(log_has_since(mark, "HOST DIED with Beat Key AU loaded: pid"), "the dead host was not reported");
    CHECK(log_has_since(mark, "host com.example.daw"), "the marker's details were not logged");
    CHECK(!exists(dead), "the dead marker is still there");
    CHECK(exists(alive), "a live process's marker was removed");
    CHECK(exists(ours), "no marker for this process while an instance is open");
    bkp_instance *q = make("MARK");
    bkp_destroy(p);
    CHECK(exists(ours), "the marker went with the first of two instances");
    mark = log_mark();
    bkp_destroy(q);
    CHECK(!exists(ours), "the marker is still there after the last instance closed");
    CHECK(!log_has_since(mark, "HOST DIED"), "a clean close was reported as a death");
    unlink(alive.c_str());
}

}  // namespace

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: bkp_test <weights.bkw> <scratch folder> [passthru|tripwire|live|state|marker|clip ...]\n");
        return 2;
    }
    g_weights = argv[1];
    g_scratch = argv[2];
    const char *ld = getenv("BEATKEY_LOG_DIR");
    if (!ld || std::string(ld).find(g_scratch) != 0) {
        fprintf(stderr, "bkp_test: REFUSED: BEATKEY_LOG_DIR must point inside the scratch folder\n");
        return 2;
    }
    auto want = [&](const char *name) {
        if (argc == 3) return true;
        for (int i = 3; i < argc; i++) if (strcmp(argv[i], name) == 0) return true;
        return false;
    };
    if (want("passthru")) test_passthru();
    if (want("tripwire")) test_tripwire();
    if (want("live")) test_live();
    if (want("state")) test_state();
    if (want("marker")) test_marker();
    if (want("clip")) test_clip();
    printf("bkp_test: %d checks, %d failed\n", g_checks, g_failed);
    return g_failed ? 1 : 0;
}
