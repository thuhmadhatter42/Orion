/*
 * clip_parity.cpp: the AudioSuite Analyze path (plan step 14) on real files, for plugin/test/audiosuite-parity.sh.
 * Each job's decoded PCM goes through the instance layer exactly as the AAX host processor hands it over
 * (bkp_use_clips, bkp_clip_begin with the length, bkp_clip_add per window of de-interleaved channels,
 * bkp_clip_end), and the reading is printed as one JSON line for the script to hold against the app's answers
 * (the Python goldens in core/test/golden).  It judges nothing.
 *
 *   clip_parity <weights.bkw> < jobs.tsv
 * jobs.tsv, one per line, tab-separated:  id  sample_rate  channels  s16|f32  pcm_path (interleaved little-endian)
 * s16 is turned into float as the app's decode does (bpm.py decode_ffmpeg: int16 / 32768 in float32).
 * Exit 0 = every job produced a reading; a job that did not is printed with "error" and the exit is 1.
 */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "../shared/bkp.h"

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: clip_parity <weights.bkw> < jobs.tsv\n");
        return 2;
    }
    bkp_config cfg = {"AAX", nullptr, argv[1], "clip_parity"};
    bkp_instance *p = bkp_create(&cfg);
    if (!p || !bk_ready()) {
        fprintf(stderr, "clip_parity: the weights did not load from %s\n", argv[1]);
        return 2;
    }
    bkp_use_clips(p);
    int failed = 0;
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty()) continue;
        std::istringstream ss(line);
        std::string id, fmt, path;
        double rate = 0;
        int nch = 0;
        std::getline(ss, id, '\t');
        ss >> rate >> nch;
        ss.ignore(1);
        std::getline(ss, fmt, '\t');
        std::getline(ss, path);
        std::ifstream f(path, std::ios::binary);
        std::vector<char> raw((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        const size_t width = fmt == "s16" ? 2 : 4;
        if (!f.good() && raw.empty()) {
            printf("{\"id\": \"%s\", \"error\": \"cannot read %s\"}\n", id.c_str(), path.c_str());
            failed++;
            continue;
        }
        if (nch < 1 || nch > 2 || (fmt != "s16" && fmt != "f32")) {
            printf("{\"id\": \"%s\", \"error\": \"bad job line\"}\n", id.c_str());
            failed++;
            continue;
        }
        const size_t frames = raw.size() / (width * (size_t)nch);
        // de-interleave into channels, the shape Pro Tools hands an AudioSuite plug-in
        std::vector<std::vector<float>> ch((size_t)nch, std::vector<float>(frames));
        for (size_t i = 0; i < frames; i++)
            for (int c = 0; c < nch; c++) {
                const char *at = raw.data() + (i * (size_t)nch + (size_t)c) * width;
                if (width == 2) {
                    int16_t v;
                    memcpy(&v, at, 2);
                    ch[(size_t)c][i] = (float)v / 32768.0f;
                } else {
                    memcpy(&ch[(size_t)c][i], at, 4);
                }
            }
        char err[256] = {0};
        bk_reading r{};
        int rc = bkp_clip_begin(p, rate, frames, err, sizeof err);
        const float *ptr[2];
        for (size_t at = 0; rc == 0 && at < frames; at += 4096) {
            const uint32_t n = (uint32_t)(frames - at < 4096 ? frames - at : 4096);
            for (int c = 0; c < nch; c++) ptr[c] = ch[(size_t)c].data() + at;
            if (bkp_clip_add(p, ptr, nch, n) != (long)n) rc = -1;
        }
        if (rc == 0) rc = bkp_clip_end(p, "AudioSuite Analyze (parity)", &r, err, sizeof err);
        else bkp_clip_cancel(p, "clip_parity: a window was refused");
        if (rc != 0) {
            printf("{\"id\": \"%s\", \"error\": \"%s\"}\n", id.c_str(), err[0] ? err : "a window was refused (see the log)");
            failed++;
            continue;
        }
        printf("{\"id\": \"%s\", \"frames\": %zu, \"keys\": [[\"%s\", %.1f], [\"%s\", %.1f], [\"%s\", %.1f]], "
               "\"has_tuning\": %d, \"tuning_cents\": %.17g, \"bpm\": %.17g, \"bpm_exact\": %.17g}\n",
               id.c_str(), frames, r.keys[0].name, r.keys[0].percent, r.keys[1].name, r.keys[1].percent, r.keys[2].name,
               r.keys[2].percent, r.has_tuning, r.tuning_cents, r.bpm, r.bpm_exact);
        fflush(stdout);
    }
    bkp_destroy(p);
    return failed ? 1 : 0;
}
