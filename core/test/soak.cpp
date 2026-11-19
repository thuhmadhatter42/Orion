/*
 * soak.cpp: plan step 6's soak.  Four analyzers at once, each fed in real time by its own "audio
 * thread" (512-frame stereo blocks on a steady clock, as a host would), for N minutes.
 *
 *   soak <weights.bkw> <minutes> <scratch folder> <mono_44100.f32> [more .f32 ...]
 *
 * The audio is real music (the parity PCM); each analyzer loops a different file.  Analyzers 1-4
 * run at 44100, 48000, 96000 and 48000 Hz (the file is simply played at that rate: for a soak only
 * the load matters).
 *
 * It passes when, for every analyzer:
 *   no missed hop   nothing was dropped, and the worker made exactly as many readings as
 *                   LiveAnalyzer makes for the same audio fed directly (counted after the run, same
 *                   chunks): every hop's reading came.  How LATE the worker ever was (the most audio
 *                   seen waiting in the ring, looked at every 50 ms) is printed, not judged: it
 *                   depends on what else the Mac is doing, and a late reading is not a missed one;
 * and when memory did not grow: the heap in use (malloc's own count of live bytes, so page caching
 * and freed-but-kept pages do not blur it), median over the last two minutes, is within 1 MB of
 * its median over minutes 2-3 (every buffer is full after ~35 s).  Runs under four minutes skip
 * the memory verdict and say so.
 * Prints one line every 30 s and a verdict; exit 0 = pass.
 */
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <algorithm>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <string>
#include <sys/resource.h>
#include <thread>
#include <vector>

#include "../include/beatkey.h"
#include "../src/live.h"
#include "../src/worker.h"

namespace {

std::vector<float> read_pcm(const char *path) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) { fprintf(stderr, "soak: cannot open %s\n", path); exit(2); }
    const std::streamsize bytes = f.tellg();
    f.seekg(0);
    std::vector<float> x((size_t)bytes / sizeof(float));
    f.read((char *)x.data(), (std::streamsize)(x.size() * sizeof(float)));
    return x;
}

double footprint_mb() {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return (double)info.phys_footprint / (1024.0 * 1024.0);
}

double heap_mb() {                           // live malloc bytes, every zone
    malloc_statistics_t st;
    malloc_zone_statistics(nullptr, &st);
    return (double)st.size_in_use / (1024.0 * 1024.0);
}

double median(std::vector<double> v, size_t from, size_t to) {
    std::vector<double> w(v.begin() + (long)from, v.begin() + (long)to);
    std::sort(w.begin(), w.end());
    return w[w.size() / 2];
}

double cpu_seconds() {                       // this process, user + system, every thread
    struct rusage u;
    getrusage(RUSAGE_SELF, &u);
    return (double)u.ru_utime.tv_sec + u.ru_utime.tv_usec / 1e6 + (double)u.ru_stime.tv_sec + u.ru_stime.tv_usec / 1e6;
}

struct Feed {
    double rate = 0;
    std::vector<float> audio;
    bk_analyzer *a = nullptr;
    std::atomic<uint64_t> pushed{0};
    std::atomic<uint64_t> refused{0};
};

}  // namespace

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: soak <weights.bkw> <minutes> <scratch folder> <mono_44100.f32> [more .f32 ...]\n");
        return 2;
    }
    const double minutes = atof(argv[2]);
    bk_log_set_dir((std::string(argv[3]) + "/logs").c_str());
    char err[256];
    if (bk_load_weights(argv[1], err, sizeof err) != BK_OK) {
        fprintf(stderr, "soak: REFUSED: %s\n", err);
        return 2;
    }
    const double rates[4] = {44100, 48000, 96000, 48000};
    Feed feeds[4];
    double audio_mb = 0;
    for (int i = 0; i < 4; i++) {
        feeds[i].rate = rates[i];
        feeds[i].audio = read_pcm(argv[4 + i % (argc - 4)]);
        audio_mb += (double)feeds[i].audio.size() * sizeof(float) / (1024.0 * 1024.0);
        if (feeds[i].audio.size() < 4096) { fprintf(stderr, "soak: %s is too short\n", argv[4 + i % (argc - 4)]); return 2; }
        bk_analyzer_config cfg = {rates[i], "soak", "TEST"};
        feeds[i].a = bk_analyzer_create(&cfg, err, sizeof err);
        if (!feeds[i].a) { fprintf(stderr, "soak: REFUSED: %s\n", err); return 2; }
    }

    printf("the test's own music in memory: %.0f MB of every heap and footprint figure below\n", audio_mb);
    const double cpu_start = cpu_seconds();
    const auto start = std::chrono::steady_clock::now();
    const auto end = start + std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(minutes * 60.0));
    std::atomic<bool> stop{false};
    std::vector<std::thread> audio;
    for (int i = 0; i < 4; i++) {
        audio.emplace_back([&, i] {
            Feed &f = feeds[i];
            const size_t block = 512;
            const size_t total = (size_t)(minutes * 60.0 * f.rate) / block * block;
            size_t at = 0;
            std::vector<float> l(block), r(block);
            for (size_t sent = 0; sent < total && !stop; sent += block) {
                for (size_t k = 0; k < block; k++) {
                    l[k] = r[k] = f.audio[at];
                    at = at + 1 == f.audio.size() ? 0 : at + 1;
                }
                const float *ch[2] = {l.data(), r.data()};
                const size_t took = bk_analyzer_push_channels(f.a, ch, 2, block);
                f.refused += block - took;
                f.pushed += block;
                std::this_thread::sleep_until(start + std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                                                          std::chrono::duration<double>((double)(sent + block) / f.rate)));
            }
        });
    }

    std::vector<double> mem;                       // one sample a second, by the clock
    double worst_lag[4] = {0, 0, 0, 0}, worst_ms[4] = {0, 0, 0, 0};
    double next_mem = 1.0, next_line = 30.0;
    while (std::chrono::steady_clock::now() < end) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        for (int i = 0; i < 4; i++) {
            const double lag = (double)feeds[i].a->ring.available() / feeds[i].rate;
            if (lag > worst_lag[i]) worst_lag[i] = lag;
            bk_snapshot s;
            bk_analyzer_snapshot(feeds[i].a, &s);
            if (s.last_reading_ms > worst_ms[i]) worst_ms[i] = s.last_reading_ms;
        }
        if (elapsed >= next_mem) {
            mem.push_back(heap_mb());
            next_mem += 1.0;
        }
        if (elapsed >= next_line) {
            next_line += 30.0;
            bk_snapshot s[4];
            for (int i = 0; i < 4; i++) bk_analyzer_snapshot(feeds[i].a, &s[i]);
            printf("%5.0f s  heap %.2f MB  footprint %.1f MB  readings %llu %llu %llu %llu  dropped %llu %llu %llu %llu  worst lag %.2f %.2f %.2f %.2f s\n",
                   elapsed, mem.back(), footprint_mb(), (unsigned long long)s[0].readings, (unsigned long long)s[1].readings,
                   (unsigned long long)s[2].readings, (unsigned long long)s[3].readings, (unsigned long long)s[0].dropped_frames,
                   (unsigned long long)s[1].dropped_frames, (unsigned long long)s[2].dropped_frames, (unsigned long long)s[3].dropped_frames,
                   worst_lag[0], worst_lag[1], worst_lag[2], worst_lag[3]);
            fflush(stdout);
        }
    }
    for (std::thread &t : audio) t.join();
    std::this_thread::sleep_for(std::chrono::milliseconds(1500));      // the worker finishes what is queued
    const double cpu_used = cpu_seconds() - cpu_start;
    printf("CPU: the whole process (worker + four feeder threads) used %.1f s over %.0f s = %.1f %% of one core, %.1f %% per analyzer\n",
           cpu_used, minutes * 60.0, 100.0 * cpu_used / (minutes * 60.0), 25.0 * cpu_used / (minutes * 60.0));

    bool pass = true;
    for (int i = 0; i < 4; i++) {
        Feed &f = feeds[i];
        bk_snapshot s;
        bk_analyzer_snapshot(f.a, &s);
        // the same audio, the same half-second chunks, fed to LiveAnalyzer directly
        bk::LiveAnalyzer direct(f.rate);
        const size_t chunk = bk::LiveAnalyzer::chunk_samples(f.rate);
        std::vector<bk::LiveEvent> ev;
        std::vector<float> buf(chunk);
        uint64_t want = 0;
        size_t at = 0;
        for (uint64_t done = 0; done + chunk <= f.pushed; done += chunk) {
            for (size_t k = 0; k < chunk; k++) {
                buf[k] = f.audio[at];
                at = at + 1 == f.audio.size() ? 0 : at + 1;
            }
            ev.clear();
            direct.push(buf.data(), chunk, ev);
            for (const bk::LiveEvent &e : ev) want += e.type == bk::LiveEvent::Reading;
        }
        const bool ok = s.dropped_frames == 0 && f.refused == 0 && s.readings == want && s.error == 0;
        pass = pass && ok;
        printf("analyzer %d (%.0f Hz): %s  readings %llu (direct run %llu), dropped %llu, most audio ever waiting %.2f s, slowest reading %.0f ms, songs %llu\n",
               i + 1, f.rate, ok ? "ok" : "FAIL", (unsigned long long)s.readings, (unsigned long long)want,
               (unsigned long long)s.dropped_frames, worst_lag[i], worst_ms[i], (unsigned long long)s.song);
    }
    if (mem.size() >= 240) {
        const double early = median(mem, 60, 180), late = median(mem, mem.size() - 120, mem.size());
        const bool ok = late - early < 1.0;
        pass = pass && ok;
        printf("memory: %s  heap in use, median of minutes 2-3 %.2f MB, of the last two minutes %.2f MB, growth %+.2f MB\n", ok ? "ok" : "FAIL", early, late, late - early);
    } else {
        printf("memory: NOT JUDGED (a run under four minutes is too short to compare its start with its end)\n");
    }
    for (int i = 0; i < 4; i++) bk_analyzer_destroy(feeds[i].a);
    printf("%s\n", pass ? "SOAK PASS" : "SOAK FAIL");
    return pass ? 0 : 1;
}
