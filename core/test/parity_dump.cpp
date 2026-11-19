/*
 * parity_dump.cpp: runs the core on the parity PCM and writes what it found, in the shape of the
 * goldens (core/test/golden), so core/test/parity.py can hold the two side by side (plan A5).
 * Test code only; it links the core's objects and reads their internals.  It judges nothing.
 *
 *   parity_dump <weights.bkw> <jobs.tsv>
 * jobs.tsv, one job per line, tab-separated:
 *   id  sample_rate  pcm_path  out_prefix  layers(0|1)  stream(0|1)  new_song_at_chunk(-1 = none)
 * Writes <out_prefix>.core.json, and when asked <out_prefix>.<layer>.f32 / .i32 and
 * <out_prefix>.stream.json.  Exit 0 = every job ran; a job that fails is named and the exit is 1.
 */
#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "../include/beatkey.h"
#include "../src/file.h"
#include "../src/live.h"
#include "../src/tempocnn.h"

namespace {

std::string sha256(const void *p, size_t n) {
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(p, (CC_LONG)n, d);
    char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex + 2 * i, 3, "%02x", d[i]);
    return hex;
}

std::string num(double v) {
    char b[40];
    snprintf(b, sizeof b, "%.17g", v);
    return b;
}

bool write_file(const std::string &path, const void *p, size_t n) {
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) { fprintf(stderr, "parity_dump: cannot write %s\n", path.c_str()); return false; }
    const bool ok = n == 0 || fwrite(p, 1, n, f) == n;
    fclose(f);
    if (!ok) fprintf(stderr, "parity_dump: short write on %s\n", path.c_str());
    return ok;
}

std::vector<float> read_pcm(const std::string &path) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) throw std::runtime_error("cannot open " + path);
    const std::streamsize bytes = f.tellg();
    f.seekg(0);
    std::vector<float> x((size_t)bytes / sizeof(float));
    if (bytes && !f.read((char *)x.data(), (std::streamsize)(x.size() * sizeof(float)))) throw std::runtime_error("cannot read " + path);
    return x;
}

const char *grid_name(bk::Grid g) {
    switch (g) {
    case bk::Grid::Same: return "\"same\"";
    case bk::Grid::Phase: return "\"phase\"";
    case bk::Grid::Tempo: return "\"tempo\"";
    default: return "null";
    }
}

std::string event_json(const bk::LiveEvent &e) {
    std::ostringstream o;
    switch (e.type) {
    case bk::LiveEvent::Reading: {
        const bk::LiveReading &r = e.reading;
        char bpm[32];
        snprintf(bpm, sizeof bpm, "\"%.1f\"", r.bpm);          // bpm.py: str(round(bpm, 1))
        o << "{\"event\": \"reading\", \"bpm\": " << (r.has_bpm ? bpm : "null") << ", \"bpm_exact\": "
          << (r.has_bpm_exact ? num(r.bpm_exact) : "null") << ", \"keys\": [";
        for (int i = 0; i < 3; i++) o << (i ? ", " : "") << "[\"" << r.keys[i].name << "\", " << (long)r.keys[i].percent << "]";
        o << "], \"secs\": " << num(r.secs) << ", \"tuning_cents\": " << (r.has_tuning ? num(r.tuning_cents) : "null") << ", \"chroma\": [";
        for (int i = 0; i < 12; i++) o << (i ? ", " : "") << num(r.chroma[i]);
        o << "]}";
        break;
    }
    case bk::LiveEvent::Reset: o << "{\"event\": \"reset\"}"; break;
    case bk::LiveEvent::Silence: o << "{\"event\": \"silence\", \"db\": " << num(e.db) << "}"; break;
    case bk::LiveEvent::Sound: o << "{\"event\": \"sound\", \"db\": " << num(e.db) << ", \"after\": " << num(e.after) << "}"; break;
    case bk::LiveEvent::Boundary:
        o << "{\"event\": \"boundary\", \"reason\": \"" << e.reason << "\"";
        if (e.has_scores)
            o << ", \"scores\": {\"disappeared\": " << num(e.scores.disappeared) << ", \"grid\": " << grid_name(e.scores.grid)
              << ", \"harmonic\": " << num(e.scores.harmonic) << ", \"bpm_ref\": " << num(e.scores.bpm_ref)
              << ", \"dphase\": " << num(e.scores.dphase) << ", \"grid_ref\": " << num(e.scores.grid_ref)
              << ", \"grid_cur\": " << num(e.scores.grid_cur) << "}";
        o << "}";
        break;
    }
    return o.str();
}

bool run_file(const std::string &prefix, const std::vector<float> &pcm, double rate, bool layers) {
    const auto t0 = std::chrono::steady_clock::now();
    const bk::FileAnalysis a = bk::analyze_buffer(pcm.data(), pcm.size(), rate, true);
    const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();

    std::ostringstream o;
    o << "{\n \"analyze_ms\": " << num(ms) << ",\n \"key\": {\"keys\": [";
    for (int i = 0; i < 3; i++) o << (i ? ", " : "") << "[\"" << a.key.keys[i].name << "\", " << num(a.key.keys[i].percent) << "]";
    o << "], \"tuning_cents\": " << (a.key.has_tuning ? num(a.key.tuning_cents) : "null")
      << ", \"tuning_raw\": " << (a.key.has_tuning_raw ? num(a.key.tuning_raw) : "null")
      << ", \"retuned\": " << (a.key.retuned ? "true" : "false") << ", \"chroma\": [";
    for (int i = 0; i < 12; i++) o << (i ? ", " : "") << num(a.key.chroma[i]);
    o << "], \"pcp12\": [";
    for (int i = 0; i < 12; i++) o << (i ? ", " : "") << num((double)a.key.pcp12[i]);
    o << "], \"scores\": {";
    if (a.key.has_scores)
        for (int i = 0; i < 24; i++) o << (i ? ", " : "") << "\"" << bk::key_name(i) << "\": " << num(a.key.scores[i]);
    size_t n_peaks = 0;
    for (const bk::Peaks &p : a.peaks) n_peaks += p.freq.size();
    o << "}, \"n_frames\": " << a.hpcp.size() << ", \"n_peaks\": " << n_peaks << "},\n \"tempo\": {\"classes\": [";
    for (size_t i = 0; i < a.tempo.classes.size(); i++) o << (i ? ", " : "") << a.tempo.classes[i];
    o << "], \"margins\": [";                       // top softmax value minus the runner-up, per patch
    for (size_t i = 0; i < a.tempo.classes.size(); i++) {
        const float *row = &a.tempo.pred[i * bk::kTempoClasses];
        float first = 0, second = 0;
        for (int c = 0; c < bk::kTempoClasses; c++) {
            if (row[c] > first) { second = first; first = row[c]; }
            else if (row[c] > second) second = row[c];
        }
        o << (i ? ", " : "") << num((double)(first - second));
    }
    o << "], \"global_bpm\": " << num(a.tempo.global_bpm) << ", \"bpm\": " << num(a.bpm) << ", \"bpm_exact\": " << num(a.bpm_exact)
      << ", \"n_frames\": " << a.n_mel_frames << "},\n \"resampled\": {\"key_44100\": {\"samples\": " << a.a_key.size()
      << ", \"sha256\": \"" << sha256(a.a_key.data(), a.a_key.size() * sizeof(float)) << "\"}, \"tempo_11025\": {\"samples\": "
      << a.a_bpm.size() << ", \"sha256\": \"" << sha256(a.a_bpm.data(), a.a_bpm.size() * sizeof(float)) << "\"}}\n}\n";
    const std::string s = o.str();
    bool ok = write_file(prefix + ".core.json", s.data(), s.size());

    if (layers) {
        std::vector<float> flat;
        for (const bk::HpcpFrame &f : a.hpcp) flat.insert(flat.end(), f.begin(), f.end());
        ok = write_file(prefix + ".hpcp.f32", flat.data(), flat.size() * sizeof(float)) && ok;
        std::vector<int32_t> counts;
        flat.clear();
        for (const bk::Peaks &p : a.peaks) {
            counts.push_back((int32_t)p.freq.size());
            for (size_t i = 0; i < p.freq.size(); i++) {
                flat.push_back(p.freq[i]);
                flat.push_back(p.mag[i]);
                flat.push_back(p.white[i]);
            }
        }
        ok = write_file(prefix + ".peak_counts.i32", counts.data(), counts.size() * sizeof(int32_t)) && ok;
        ok = write_file(prefix + ".peaks.f32", flat.data(), flat.size() * sizeof(float)) && ok;
        ok = write_file(prefix + ".mel.f32", a.bands.data(), a.bands.size() * sizeof(float)) && ok;
        ok = write_file(prefix + ".cnn.f32", a.tempo.pred.data(), a.tempo.pred.size() * sizeof(float)) && ok;
        ok = write_file(prefix + ".key44100.f32", a.a_key.data(), a.a_key.size() * sizeof(float)) && ok;
        ok = write_file(prefix + ".tempo11025.f32", a.a_bpm.data(), a.a_bpm.size() * sizeof(float)) && ok;
    }
    return ok;
}

// LiveAnalyzer fed as tools/parity/make_goldens.py feeds bpm.py's: 0.5 s per push, then finish().
bool run_stream(const std::string &prefix, const std::vector<float> &pcm, double rate, long new_song_at) {
    bk::LiveAnalyzer live(rate);
    const size_t chunk = bk::LiveAnalyzer::chunk_samples(rate);
    std::ostringstream o;
    o << "{\"events\": [\n";
    bool first = true;
    size_t chunks = 0;
    double worst_ms = 0, total_ms = 0, last_ms = 0;
    size_t readings = 0;
    std::vector<double> full_reading_ms;           // pushes that made a reading with a BPM in it
    std::vector<bk::LiveEvent> events;
    auto flush = [&](size_t index) {
        for (const bk::LiveEvent &e : events) {
            o << (first ? "" : ",\n") << " [" << index << ", " << event_json(e) << "]";
            first = false;
            readings += e.type == bk::LiveEvent::Reading;
            if (e.type == bk::LiveEvent::Reading && e.reading.has_bpm) full_reading_ms.push_back(last_ms);
        }
        events.clear();
    };
    for (size_t start = 0, i = 0; start < pcm.size(); start += chunk, i++) {
        if (new_song_at >= 0 && (long)i == new_song_at) live.new_song("title", events);
        const size_t n = pcm.size() - start < chunk ? pcm.size() - start : chunk;
        const auto t0 = std::chrono::steady_clock::now();
        live.push(pcm.data() + start, n, events);
        const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        total_ms += ms;
        last_ms = ms;
        if (ms > worst_ms) worst_ms = ms;
        flush(i);
        chunks = i + 1;
    }
    live.finish(events);
    flush(chunks);
    std::sort(full_reading_ms.begin(), full_reading_ms.end());
    o << "\n], \"chunks\": " << chunks << ", \"readings\": " << readings << ", \"worst_push_ms\": " << num(worst_ms)
      << ", \"total_push_ms\": " << num(total_ms) << ", \"full_readings\": " << full_reading_ms.size()
      << ", \"median_full_reading_ms\": " << (full_reading_ms.empty() ? "null" : num(full_reading_ms[full_reading_ms.size() / 2])) << "}\n";
    const std::string s = o.str();
    return write_file(prefix + ".stream.json", s.data(), s.size());
}

}  // namespace

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: parity_dump <weights.bkw> <jobs.tsv>\n");
        return 2;
    }
    char err[512];
    if (bk_load_weights(argv[1], err, sizeof err) != BK_OK) {
        fprintf(stderr, "parity_dump: REFUSED: %s\n", err);
        return 1;
    }
    std::ifstream jobs(argv[2]);
    if (!jobs) {
        fprintf(stderr, "parity_dump: cannot read %s\n", argv[2]);
        return 1;
    }
    std::string line;
    int failed = 0, ran = 0;
    while (std::getline(jobs, line)) {
        if (line.empty()) continue;
        std::vector<std::string> f;
        std::stringstream ss(line);
        std::string cell;
        while (std::getline(ss, cell, '\t')) f.push_back(cell);
        if (f.size() != 7) {
            fprintf(stderr, "parity_dump: bad job line (want 7 tab-separated fields): %s\n", line.c_str());
            failed++;
            continue;
        }
        try {
            const std::vector<float> pcm = read_pcm(f[2]);
            const double rate = atof(f[1].c_str());
            bool ok = run_file(f[3], pcm, rate, f[4] == "1");
            if (f[5] == "1") ok = run_stream(f[3], pcm, rate, atol(f[6].c_str())) && ok;
            if (!ok) failed++;
            ran++;
        } catch (const std::exception &e) {
            fprintf(stderr, "parity_dump: job %s FAILED: %s\n", f[0].c_str(), e.what());
            failed++;
        }
    }
    fprintf(stderr, "parity_dump: %d job(s) ran, %d failed\n", ran, failed);
    return failed ? 1 : 0;
}
