/*
 * core_test.cpp: the core's own tests (plan steps 3 and 6), run by core/test.sh on both slices.
 *   ring       wrap-around, two-thread integrity, overflow counted, push under the tripwire
 *   log        the line format, the roll at the size limit, an unwritable folder
 *   bring-up   every refusal before and around bk_load_weights
 *   file       bk_analyze_buffer on a made-up clip, and its argument refusals
 *   live       the worker: the snapshot equals what LiveAnalyzer says for the same chunks, the
 *              audio-thread path under the tripwire, new song, overflow, garbage samples,
 *              create / destroy in any order
 * Usage: core_test <weights.bkw> <scratch folder> [ring|log|bringup|file|live ...]   (default: all)
 * It writes only inside the scratch folder.  Exit 0 = every check passed.
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
#include <thread>
#include <unistd.h>
#include <vector>

#include "../include/beatkey.h"
#include "../src/live.h"
#include "../src/log.h"
#include "../src/ring.h"
#include "../src/worker.h"

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

std::string log_text() { return read_all(bk::log_path()); }
size_t log_mark() { return log_text().size(); }
bool log_has_since(size_t mark, const char *needle) {
    const std::string t = log_text();
    return t.size() >= mark && t.find(needle, mark) != std::string::npos;
}

void write_bytes(const std::string &path, const std::string &bytes) {
    std::ofstream f(path, std::ios::binary);
    f.write(bytes.data(), (std::streamsize)bytes.size());
}

void sleep_ms(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

// A made-up clip: an A-minor chord with a click every beat at `bpm`.  Deterministic.
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

// ------------------------------------------------------------------ ring
void test_ring() {
    printf("== ring\n");
    {
        bk::Ring r(1000);
        CHECK(r.capacity() == 1024, "capacity %zu", r.capacity());
        std::vector<float> in(700), out(700);
        size_t next = 0, want = 0;
        bool intact = true;
        for (int round = 0; round < 50; round++) {             // wraps the 1024 buffer many times
            for (size_t i = 0; i < in.size(); i++) in[i] = (float)(next++);
            CHECK(r.push(in.data(), in.size()) == in.size(), "round %d", round);
            CHECK(r.pop(out.data(), out.size()) == out.size(), "round %d", round);
            for (float v : out) intact = intact && v == (float)(want++);
        }
        CHECK(intact, "samples came out changed or out of order across the wrap");
        CHECK(r.dropped() == 0, "dropped %llu", (unsigned long long)r.dropped());
    }
    {
        bk::Ring r(1024);
        std::vector<float> in(3000, 1.0f), out(4096);
        CHECK(r.push(in.data(), in.size()) == 1024, "a full ring takes only what fits");
        CHECK(r.dropped() == 3000 - 1024, "dropped %llu", (unsigned long long)r.dropped());
        CHECK(r.push(in.data(), 10) == 0, "a full ring takes nothing more");
        CHECK(r.dropped() == 3000 - 1024 + 10, "dropped %llu", (unsigned long long)r.dropped());
        CHECK(r.pop(out.data(), out.size()) == 1024, "pop returns what is there");
        CHECK(r.pop(out.data(), out.size()) == 0, "an empty ring gives nothing");
    }
    {
        // two threads, one each side: every sample that was taken comes out once, in order
        bk::Ring r(4096);
        const size_t total = 4000000;
        std::atomic<bool> done{false};
        std::atomic<size_t> taken{0};
        std::thread producer([&] {
            float block[257];
            size_t sent = 0;
            while (sent < total) {
                const size_t n = total - sent < 257 ? total - sent : 257;
                for (size_t i = 0; i < n; i++) block[i] = (float)((sent + i) % 1000003);
                size_t off = 0;
                while (off < n) off += r.push(block + off, n - off);     // test only: retry, so nothing is lost
                sent += n;
            }
            taken = sent;
            done = true;
        });
        std::vector<float> out(1024);
        size_t got = 0;
        bool ordered = true;
        for (;;) {
            const size_t n = r.pop(out.data(), out.size());
            for (size_t i = 0; i < n; i++) ordered = ordered && out[i] == (float)((got + i) % 1000003);
            got += n;
            if (!n && done && r.available() == 0) break;
        }
        producer.join();
        CHECK(got == total, "got %zu of %zu", got, total);
        CHECK(ordered, "two-thread transfer changed or reordered samples");
    }
    {
        // the audio thread's call: no allocation, no lock
        bk::Ring r(1 << 16);
        std::vector<float> in(512, 0.25f);
        tw_arm();
        for (int i = 0; i < 400; i++) r.push(in.data(), in.size());      // fills, then overflows
        tw_disarm();
        CHECK(tw_mallocs() == 0, "push allocated %ld times", tw_mallocs());
        CHECK(tw_locks() == 0, "push locked %ld times", tw_locks());
        CHECK(r.dropped() > 0, "the overflow part of the path ran");
        // the tripwire itself works: an allocation on the armed thread is seen
        tw_arm();
        void *volatile p = malloc(64);             // volatile: the compiler may not drop the pair
        tw_disarm();
        free(p);
        CHECK(tw_mallocs() == 1, "tripwire counted %ld mallocs for one malloc", tw_mallocs());
    }
}

// ------------------------------------------------------------------ log
void test_log() {
    printf("== log\n");
    const std::string dir = g_scratch + "/log-test/nested/deeper";
    bk_log_set_dir(dir.c_str());
    char path[1100];
    CHECK(std::string(bk_log_path(path, sizeof path)) == dir + "/plugin.log", "path %s", path);
    bk_log("unit", "hello %d", 42);
    const std::string text = read_all(path);
    CHECK(text.find(" unit hello 42\n") != std::string::npos, "line missing: %s", text.c_str());
    // "<YYYY-MM-DD HH:MM:SS +zzzz> pid <n> <area> <message>"
    int y, mo, d, h, mi, s, off, pid;
    char area[32];
    CHECK(sscanf(text.c_str(), "%d-%d-%d %d:%d:%d %d pid %d %31s", &y, &mo, &d, &h, &mi, &s, &off, &pid, area) == 9,
          "line format: %s", text.c_str());
    CHECK(pid == (int)getpid() && std::string(area) == "unit", "pid %d area %s", pid, area);

    bk::log_set_roll_bytes(400);
    for (int i = 0; i < 20; i++) bk_log("unit", "filler line number %d to reach the roll size", i);
    struct stat st;
    CHECK(stat((dir + "/plugin.log.1").c_str(), &st) == 0, "no plugin.log.1 after the roll size was passed");
    CHECK(stat(path, &st) == 0 && st.st_size < 1200, "current log is %lld bytes after rolling", (long long)st.st_size);
    bk::log_set_roll_bytes(0);

    // a folder that cannot be made: nothing crashes, the line still goes to os_log
    const std::string blocker = g_scratch + "/log-test/blocker";
    write_bytes(blocker, "a file where a folder is wanted");
    bk_log_set_dir((blocker + "/sub").c_str());
    bk_log("unit", "this line has nowhere to go");
    CHECK(stat((blocker + "/sub/plugin.log").c_str(), &st) != 0, "a log appeared under a plain file");
    bk_log_set_dir((g_scratch + "/logs").c_str());
}

// ------------------------------------------------------------------ bring-up
void test_bringup() {
    printf("== bring-up refusals\n");
    char err[256];
    CHECK(std::string(bk_version()).find('.') != std::string::npos, "version '%s'", bk_version());
    CHECK(bk_ready() == 0, "ready before any weights were loaded");

    std::vector<float> x = clip(44100, 1.0, 120);
    bk_reading r;
    size_t mark = log_mark();
    CHECK(bk_analyze_buffer(x.data(), x.size(), 44100, &r, err, sizeof err) == BK_ERR_NO_WEIGHTS, "err: %s", err);
    CHECK(strstr(err, "incomplete") != nullptr, "sentence: %s", err);
    CHECK(log_has_since(mark, "REFUSED: The analyzer is incomplete"), "no log line for the refusal");
    bk_analyzer_config cfg = {48000, "test.host", "TEST"};
    CHECK(bk_analyzer_create(&cfg, err, sizeof err) == nullptr, "an analyzer was created without weights");
    CHECK(strstr(err, "incomplete") != nullptr, "sentence: %s", err);

    const std::string real = read_all(g_weights);
    CHECK(real.size() > 1000000, "the real weights file is %zu bytes", real.size());
    struct Bad {
        const char *name, *want;
        std::string bytes;
    };
    std::string wrong_shape = real;
    wrong_shape[4 + 4 + 2 + 9 + 4] ^= 0x01;       // first tensor's first dimension
    std::string nan_value = real;
    memset(&nan_value[nan_value.size() - 4], 0xff, 4);
    const Bad bad[] = {
        {"garbage", "BKW1", std::string(5000, 'x')},
        {"empty", "cut short", ""},
        {"truncated", "cut short", real.substr(0, real.size() / 2)},
        {"trailing", "after its last tensor", real + "zz"},
        {"wrong-shape", "", wrong_shape},
        {"not-a-number", "not a number", nan_value},
    };
    for (const Bad &b : bad) {
        const std::string p = g_scratch + "/bad-" + b.name + ".bkw";
        write_bytes(p, b.bytes);
        mark = log_mark();
        CHECK(bk_load_weights(p.c_str(), err, sizeof err) == BK_ERR_BAD_WEIGHTS, "%s was accepted", b.name);
        CHECK(strstr(err, b.want) != nullptr, "%s: sentence '%s' lacks '%s'", b.name, err, b.want);
        CHECK(log_has_since(mark, "REFUSED:"), "%s: no log line", b.name);
        CHECK(bk_ready() == 0, "%s: ready after a refused load", b.name);
    }
    CHECK(bk_load_weights((g_scratch + "/no-such-file.bkw").c_str(), err, sizeof err) == BK_ERR_BAD_WEIGHTS, "missing file accepted");
    CHECK(strstr(err, "cannot open") != nullptr, "sentence: %s", err);
    CHECK(bk_load_weights(nullptr, err, sizeof err) == BK_ERR_BAD_WEIGHTS, "NULL path accepted");
    CHECK(bk_load_weights("", nullptr, 0) == BK_ERR_BAD_WEIGHTS, "empty path accepted (and a NULL err must be fine)");

    mark = log_mark();
    CHECK(bk_load_weights(g_weights.c_str(), err, sizeof err) == BK_OK, "the real weights were refused: %s", err);
    CHECK(bk_ready() == 1, "not ready after a good load");
    CHECK(log_has_since(mark, "tempo weights loaded from"), "no log line for the load");
    CHECK(bk_load_weights(g_weights.c_str(), err, sizeof err) == BK_OK, "a second load is a no-op");
    CHECK(bk_load_weights((g_scratch + "/bad-garbage.bkw").c_str(), err, sizeof err) == BK_OK,
          "once loaded, a later load is a no-op whatever the path");
}

// ------------------------------------------------------------------ file
void test_file() {
    printf("== whole clip\n");
    char err[256];
    CHECK(bk_load_weights(g_weights.c_str(), err, sizeof err) == BK_OK, "%s", err);
    bk_reading r;
    std::vector<float> x = clip(48000, 30.0, 120);
    size_t mark = log_mark();
    CHECK(bk_analyze_buffer(x.data(), x.size(), 48000, &r, err, sizeof err) == BK_OK, "%s", err);
    printf("  made-up clip (A minor chord, 120 BPM clicks, 30 s at 48 kHz): %s %.1f%% / %s %.1f%% / %s %.1f%%, bpm %.1f (%.2f), tuning %s%.1f\n",
           r.keys[0].name, r.keys[0].percent, r.keys[1].name, r.keys[1].percent, r.keys[2].name, r.keys[2].percent,
           r.bpm, r.bpm_exact, r.has_tuning ? "" : "(none) ", r.tuning_cents);
    CHECK(std::string(r.keys[0].name) == "Am", "key %s", r.keys[0].name);
    CHECK(std::fabs(r.bpm_exact - 120.0) < 0.05 || std::fabs(r.bpm_exact - 60.0) < 0.05 || std::fabs(r.bpm_exact - 240.0) < 0.05,
          "bpm %.1f exact %.2f", r.bpm, r.bpm_exact);
    CHECK(r.has_bpm == 1 && r.has_bpm_exact == 1, "file readings always carry a BPM");
    CHECK(std::fabs(r.secs - 30.0) < 1e-9, "secs %.3f", r.secs);
    CHECK(log_has_since(mark, " file clip of 30.0 s at 48000 Hz"), "no log line for the analysis");

    // a clip too short for a tempo: BPM 0, as the reference answers
    CHECK(bk_analyze_buffer(x.data(), 48000 * 3, 48000, &r, err, sizeof err) == BK_OK, "%s", err);
    CHECK(r.bpm == 0.0 && r.bpm_exact == 0.0, "3 s clip gave bpm %.1f", r.bpm);
    // nothing at all, and silence: the "no key" answer, no crash
    CHECK(bk_analyze_buffer(x.data(), 0, 48000, &r, err, sizeof err) == BK_OK, "empty clip: %s", err);
    CHECK(std::string(r.keys[0].name) == "C" && r.keys[0].percent == 0.0 && r.has_tuning == 0, "empty clip key %s %.1f", r.keys[0].name, r.keys[0].percent);
    std::vector<float> zeros(48000 * 5, 0.0f);
    CHECK(bk_analyze_buffer(zeros.data(), zeros.size(), 48000, &r, err, sizeof err) == BK_OK, "silence: %s", err);
    CHECK(std::string(r.keys[0].name) == "C" && r.keys[0].percent == 0.0, "silence key %s %.1f", r.keys[0].name, r.keys[0].percent);

    // refusals
    mark = log_mark();
    CHECK(bk_analyze_buffer(nullptr, 10, 48000, &r, err, sizeof err) == BK_ERR_BAD_ARG, "NULL audio accepted");
    CHECK(bk_analyze_buffer(x.data(), 10, 48000, nullptr, err, sizeof err) == BK_ERR_BAD_ARG, "NULL result accepted");
    CHECK(bk_analyze_buffer(x.data(), x.size(), 4000, &r, err, sizeof err) == BK_ERR_BAD_ARG, "4 kHz accepted");
    CHECK(bk_analyze_buffer(x.data(), x.size(), 1e9, &r, err, sizeof err) == BK_ERR_BAD_ARG, "1 GHz accepted");
    CHECK(bk_analyze_buffer(x.data(), x.size(), NAN, &r, err, sizeof err) == BK_ERR_BAD_ARG, "NaN rate accepted");
    std::vector<float> poisoned(x.begin(), x.begin() + 48000);
    poisoned[777] = NAN;
    CHECK(bk_analyze_buffer(poisoned.data(), poisoned.size(), 48000, &r, err, sizeof err) == BK_ERR_BAD_ARG, "NaN sample accepted");
    CHECK(strstr(err, "sample 777") != nullptr, "sentence: %s", err);
    poisoned[777] = 1e20f;
    CHECK(bk_analyze_buffer(poisoned.data(), poisoned.size(), 48000, &r, err, sizeof err) == BK_ERR_BAD_ARG, "1e20 sample accepted");
    CHECK(log_has_since(mark, "REFUSED: sample 777"), "no log line for the refused sample");
}

// ------------------------------------------------------------------ live
bool wait_for(const bk_analyzer *a, uint64_t readings, int timeout_ms) {
    bk_snapshot s;
    for (int waited = 0; waited < timeout_ms; waited += 10) {
        bk_analyzer_snapshot(a, &s);
        if (s.readings >= readings) return true;
        sleep_ms(10);
    }
    return false;
}

void test_live() {
    printf("== live\n");
    char err[256];
    CHECK(bk_load_weights(g_weights.c_str(), err, sizeof err) == BK_OK, "%s", err);
    const double rate = 48000;
    const std::vector<float> x = clip(rate, 40.0, 120);
    const size_t chunk = bk::LiveAnalyzer::chunk_samples(rate);

    // what LiveAnalyzer itself says for the same half-second chunks
    std::vector<bk::LiveEvent> want;
    std::vector<size_t> readings_after;            // readings made once chunk i has gone in
    std::vector<bk::LiveReading> want_readings;
    {
        bk::LiveAnalyzer direct(rate);
        for (size_t at = 0; at + chunk <= x.size(); at += chunk) {
            want.clear();
            direct.push(x.data() + at, chunk, want);
            for (const bk::LiveEvent &e : want)
                if (e.type == bk::LiveEvent::Reading) want_readings.push_back(e.reading);
            readings_after.push_back(want_readings.size());
        }
    }
    CHECK(want_readings.size() >= 10, "the direct run made %zu readings", want_readings.size());

    bk_analyzer_config cfg = {rate, "test.host", "TEST"};
    size_t mark = log_mark();
    bk_analyzer *a = bk_analyzer_create(&cfg, err, sizeof err);
    CHECK(a != nullptr, "create: %s", err);
    if (!a) return;
    CHECK(log_has_since(mark, "instance created: host test.host, format TEST, version"), "no log line for the instance");
    bk_snapshot s;
    bk_analyzer_snapshot(a, &s);
    CHECK(s.has_reading == 0 && s.readings == 0 && s.error == 0, "a fresh analyzer already has a reading");

    // the audio thread: stereo blocks of 512, armed under the tripwire.  Half a second goes in, then
    // the test waits for the worker to have taken it (and made the reading it causes), so the run
    // does not depend on how fast this Mac is and nothing may be dropped.
    std::vector<float> left(x), right(x);
    const float *chans[2] = {left.data(), right.data()};
    long mallocs = 0, locks = 0;
    bool kept_up = true;
    for (size_t i = 0; i < readings_after.size(); i++) {
        const size_t pushed = i * chunk;
        tw_arm();
        for (size_t off = 0; off < chunk; off += 512) {
            const float *p[2] = {chans[0] + pushed + off, chans[1] + pushed + off};
            bk_analyzer_push_channels(a, p, 2, std::min<size_t>(512, chunk - off));
        }
        tw_disarm();
        mallocs += tw_mallocs();
        locks += tw_locks();
        for (int waited = 0; a->ring.available() != 0 && waited < 20000; waited += 2) sleep_ms(2);
        kept_up = kept_up && wait_for(a, readings_after[i], 20000);
    }
    CHECK(mallocs == 0, "the audio-thread path allocated %ld times", mallocs);
    CHECK(locks == 0, "the audio-thread path locked %ld times", locks);
    CHECK(kept_up, "the worker did not make the readings the chunks call for");
    sleep_ms(100);
    bk_analyzer_snapshot(a, &s);
    CHECK(s.readings == want_readings.size(), "worker readings %llu, direct %zu", (unsigned long long)s.readings, want_readings.size());
    CHECK(s.dropped_frames == 0, "dropped %llu frames", (unsigned long long)s.dropped_frames);
    const bk::LiveReading &last = want_readings.back();
    CHECK(s.has_reading == 1, "no reading in the snapshot");
    for (int i = 0; i < 3; i++)
        CHECK(last.keys[i].name == s.reading.keys[i].name && last.keys[i].percent == s.reading.keys[i].percent,
              "key %d: worker %s %.0f, direct %s %.0f", i, s.reading.keys[i].name, s.reading.keys[i].percent,
              last.keys[i].name.c_str(), last.keys[i].percent);
    CHECK(s.reading.has_bpm == (int)last.has_bpm && s.reading.bpm == last.bpm && s.reading.bpm_exact == last.bpm_exact,
          "bpm: worker %.1f (%.2f), direct %.1f (%.2f)", s.reading.bpm, s.reading.bpm_exact, last.bpm, last.bpm_exact);
    CHECK(s.reading.secs == last.secs, "secs: worker %.1f direct %.1f", s.reading.secs, last.secs);
    CHECK(s.reading.has_tuning == (int)last.has_tuning && s.reading.tuning_cents == last.tuning_cents, "tuning differs");
    bool chroma_same = true;
    for (int i = 0; i < 12; i++) chroma_same = chroma_same && s.reading.chroma[i] == last.chroma[i];
    CHECK(chroma_same, "chroma differs between the worker and the direct run");
    CHECK(s.silent == 0 && s.song == 0 && s.reading_song == 0 && s.error == 0, "silent %d song %llu error %d", s.silent, (unsigned long long)s.song, s.error);
    CHECK(s.level_db > -30 && s.level_db < 0, "level %.1f dB", s.level_db);
    CHECK(s.last_reading_ms > 0, "no reading time recorded");
    printf("  worker: %llu readings, newest %s %.0f%% bpm %.1f (%.2f), %.1f ms for the newest reading\n",
           (unsigned long long)s.readings, s.reading.keys[0].name, s.reading.keys[0].percent, s.reading.bpm, s.reading.bpm_exact, s.last_reading_ms);
    CHECK(log_has_since(mark, "reading: "), "no log line for a reading");

    // new song: the song number goes up, the old reading is marked stale by it
    const uint64_t seq_before = s.seq;
    mark = log_mark();
    bk_analyzer_new_song(a);
    for (int waited = 0; waited < 2000; waited += 10) {
        bk_analyzer_snapshot(a, &s);
        if (s.song == 1) break;
        sleep_ms(10);
    }
    CHECK(s.song == 1 && s.reading_song == 0 && s.seq > seq_before, "song %llu reading_song %llu", (unsigned long long)s.song, (unsigned long long)s.reading_song);
    CHECK(log_has_since(mark, "new song: announced"), "no log line for the new song");

    // silence: 3 s of it flips `silent`
    std::vector<float> zeros((size_t)rate * 4, 0.0f);
    mark = log_mark();
    for (size_t off = 0; off < zeros.size(); off += chunk) {
        bk_analyzer_push(a, zeros.data() + off, chunk);
        for (int waited = 0; a->ring.available() != 0 && waited < 20000; waited += 2) sleep_ms(2);
    }
    for (int waited = 0; waited < 2000; waited += 10) {
        bk_analyzer_snapshot(a, &s);
        if (s.silent) break;
        sleep_ms(10);
    }
    CHECK(s.silent == 1, "4 s of zeros did not read as silence");
    CHECK(log_has_since(mark, "silence: 3 s under -50 dB"), "no log line for the silence");

    // garbage from the host: refused, said, heard as silence; the analyzer keeps going
    std::vector<float> garbage(chunk, NAN);
    mark = log_mark();
    bk_analyzer_push(a, garbage.data(), garbage.size());
    for (int waited = 0; waited < 20000 && !log_has_since(mark, "not audio"); waited += 20) sleep_ms(20);
    CHECK(log_has_since(mark, "REFUSED: the host sent samples that are not audio"), "no log line for the garbage chunk");
    for (int waited = 0; waited < 5000; waited += 10) {      // the snapshot follows the log line
        bk_analyzer_snapshot(a, &s);
        if (s.refused_chunks) break;
        sleep_ms(10);
    }
    CHECK(s.error == 0, "a garbage chunk stopped the analyzer");
    CHECK(s.refused_chunks == 1, "refused chunks %llu, want 1", (unsigned long long)s.refused_chunks);

    // overflow: more than the ring holds in one go is dropped, counted, and said
    mark = log_mark();
    size_t took = 0;
    for (int i = 0; i < 6; i++) took += bk_analyzer_push(a, x.data(), (size_t)rate * 4);
    CHECK(took < (size_t)rate * 24, "24 s pushed at once all fitted in the ring (it holds about 11 s)");
    for (int waited = 0; waited < 20000 && !log_has_since(mark, "ring full"); waited += 20) sleep_ms(20);
    bk_analyzer_snapshot(a, &s);
    CHECK(s.dropped_frames == (size_t)rate * 24 - took, "dropped %llu, expected %zu", (unsigned long long)s.dropped_frames, (size_t)rate * 24 - took);
    CHECK(log_has_since(mark, "ring full"), "no log line for the dropped audio");

    mark = log_mark();
    bk_analyzer_destroy(a);
    CHECK(log_has_since(mark, "instance destroyed"), "no log line for the destroy");

    // any order, many times: nothing hangs, nothing crashes, the worker starts again each time
    for (int round = 0; round < 6; round++) {
        bk_analyzer *b[4];
        for (int i = 0; i < 4; i++) {
            bk_analyzer_config c = {i % 2 ? 44100.0 : 96000.0, "test.host", "TEST"};
            b[i] = bk_analyzer_create(&c, err, sizeof err);
            CHECK(b[i] != nullptr, "create %d: %s", i, err);
            if (b[i]) bk_analyzer_push(b[i], x.data(), 20000);
        }
        sleep_ms(round % 2 ? 30 : 0);
        const int order[4] = {round % 4, (round + 2) % 4, (round + 1) % 4, (round + 3) % 4};
        for (int i : order) bk_analyzer_destroy(b[i]);
    }
    bk_analyzer_destroy(nullptr);
    bk_analyzer_snapshot(nullptr, &s);
    CHECK(s.readings == 0, "a NULL analyzer's snapshot is not empty");
    CHECK(bk_analyzer_push(nullptr, x.data(), 10) == 0, "push on NULL took frames");
    bk_analyzer_config bad = {1000.0, nullptr, nullptr};
    CHECK(bk_analyzer_create(&bad, err, sizeof err) == nullptr && strstr(err, "outside 8000"), "1 kHz analyzer: %s", err);
    CHECK(bk_analyzer_create(nullptr, err, sizeof err) == nullptr, "NULL config accepted");
}

}  // namespace

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: core_test <weights.bkw> <scratch folder> [ring|log|bringup|file|live ...]\n");
        return 2;
    }
    g_weights = argv[1];
    g_scratch = argv[2];
    bk_log_set_dir((g_scratch + "/logs").c_str());
    std::vector<std::string> want(argv + 3, argv + argc);
    auto on = [&](const char *name) {
        if (want.empty()) return true;
        for (const std::string &w : want)
            if (w == name) return true;
        return false;
    };
    if (on("ring")) test_ring();
    if (on("log")) test_log();
    if (on("bringup")) test_bringup();      // must run before anything loads the weights
    if (on("file")) test_file();
    if (on("live")) test_live();
    printf("%d checks, %d failed\n", g_checks, g_failed);
    return g_failed ? 1 : 0;
}
