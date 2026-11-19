// midi.cpp: midi_analyze.py, line for line (parse, tempo_us, pitch_class_profile, analyze_midi).
#include "midi.h"

#include <algorithm>
#include <map>
#include <utility>
#include <vector>

#include "error.h"
#include "np.h"

namespace bk {

namespace {

const int kDrumChannel = 9;              // channel 10, zero-based
const int64_t kDefaultTempoUs = 500000;  // 120 BPM
const size_t kMinNotes = 4;              // fewer pitched notes than this is not enough to name a key

struct Note {
    int64_t start, end;
    int pitch;
};

struct Parsed {
    std::vector<Note> notes;
    std::vector<std::pair<int64_t, int64_t>> tempos;   // (tick, us), sorted
    int64_t last = 0;
};

uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }

// _vlq: (value, next index)
size_t vlq(const uint8_t *data, size_t len, size_t i, uint64_t &v) {
    v = 0;
    for (int k = 0; k < 4; k++) {
        if (i >= len) throw Error("truncated MIDI file");
        const uint8_t b = data[i++];
        v = (v << 7) | (b & 0x7F);
        if (!(b & 0x80)) return i;
    }
    throw Error("bad variable-length number");
}

Parsed parse(const uint8_t *data, size_t n) {
    if (n < 14 || data[0] != 'M' || data[1] != 'T' || data[2] != 'h' || data[3] != 'd') throw Error("not a MIDI file");
    const uint64_t hlen = be32(data + 4);
    const unsigned ntrks = be16(data + 10);
    Parsed out;
    uint64_t pos = 8 + hlen;
    for (unsigned t = 0; t < ntrks; t++) {
        if (pos + 8 > n) break;                                  // fewer tracks than the header promised
        const uint8_t *h = data + pos;
        if (h[0] != 'M' || h[1] != 'T' || h[2] != 'r' || h[3] != 'k') throw Error("bad track header");
        const uint64_t tlen = be32(h + 4);
        const uint8_t *body = data + pos + 8;
        const size_t blen = (size_t)std::min<uint64_t>(tlen, n - (pos + 8));   // a slice clamps
        pos += 8 + tlen;
        size_t i = 0;
        int64_t tick = 0;
        int status = 0;
        std::map<std::pair<int, int>, int64_t> on;               // (channel, pitch) -> start tick
        std::vector<std::pair<int, int>> order;                  // insertion order of `on`
        while (i < blen) {
            uint64_t dt;
            i = vlq(body, blen, i, dt);
            tick += (int64_t)dt;
            if (i >= blen) break;
            const uint8_t b = body[i];
            if (b == 0xFF) {                                     // meta
                if (i + 1 >= blen) break;
                const uint8_t mtype = body[i + 1];
                uint64_t ln;
                const size_t j = vlq(body, blen, i + 2, ln);
                const size_t avail = j < blen ? blen - j : 0;
                const size_t plen = (size_t)std::min<uint64_t>(ln, avail);
                i = (size_t)std::min<uint64_t>((uint64_t)j + ln, (uint64_t)blen + 1);
                if (mtype == 0x51 && plen == 3) {
                    const uint8_t *p = body + j;
                    out.tempos.push_back({tick, (int64_t)p[0] << 16 | (int64_t)p[1] << 8 | p[2]});
                } else if (mtype == 0x2F) {
                    break;
                }
                continue;                                        // 0x59 key signature and the rest: ignored
            }
            if (b == 0xF0 || b == 0xF7) {                        // sysex
                uint64_t ln;
                const size_t j = vlq(body, blen, i + 1, ln);
                i = (size_t)std::min<uint64_t>((uint64_t)j + ln, (uint64_t)blen + 1);
                continue;
            }
            if (b & 0x80) {
                status = b;
                i++;
            }
            if (!status) throw Error("data byte with no status");
            const int kind = status & 0xF0, ch = status & 0x0F;
            const size_t na = (kind == 0xC0 || kind == 0xD0) ? 1 : 2;
            const size_t got = i < blen ? std::min(na, blen - i) : 0;
            const uint8_t *args = body + i;
            i += na;
            if (got < na) break;
            const std::pair<int, int> key{ch, args[0]};
            if (kind == 0x90 && args[1] > 0) {
                if (on.emplace(key, tick).second) order.push_back(key);   // setdefault
            } else if (kind == 0x80 || kind == 0x90) {           // note off, or note on with velocity 0
                auto it = on.find(key);
                if (it != on.end()) {
                    const int64_t s = it->second;
                    on.erase(it);
                    order.erase(std::find(order.begin(), order.end(), key));
                    if (ch != kDrumChannel) out.notes.push_back({s, tick, args[0]});
                }
            }
        }
        for (const auto &k : order)                              // still sounding: closed at the track's end
            if (k.first != kDrumChannel) out.notes.push_back({on[k], tick, k.second});
        out.last = std::max(out.last, tick);
    }
    std::sort(out.tempos.begin(), out.tempos.end());
    return out;
}

// The tempo (microseconds per quarter) in force for the most ticks; ties: the first one met.
int64_t tempo_us(const Parsed &p) {
    if (p.tempos.empty()) return kDefaultTempoUs;
    std::vector<std::pair<int64_t, int64_t>> spans;              // (us, ticks), insertion order
    auto add = [&](int64_t us, int64_t ticks) {
        for (auto &s : spans)
            if (s.first == us) { s.second += ticks; return; }
        spans.push_back({us, ticks});
    };
    int64_t cur_tick = 0, cur = kDefaultTempoUs;
    for (const auto &t : p.tempos) {
        add(cur, t.first - cur_tick);
        cur_tick = t.first;
        cur = t.second;
    }
    add(cur, std::max<int64_t>(p.last - cur_tick, 0));
    size_t best = 0;
    for (size_t i = 1; i < spans.size(); i++)
        if (spans[i].second > spans[best].second) best = i;
    return spans[best].first;
}

// Duration-weighted pitch-class histogram (bin 0 = C) of the notes starting in [lo, hi).
void pitch_class_profile(const std::vector<Note> &notes, double lo, double hi, bool has_hi, double out[12]) {
    for (int i = 0; i < 12; i++) out[i] = 0.0;
    for (const Note &n : notes)
        if ((double)n.start >= lo && (!has_hi || (double)n.start < hi))
            out[n.pitch % 12] += (double)std::max<int64_t>(n.end - n.start, 1);
}

void normalise(double p[12]) {                                  // pcp / pcp.max()
    double top = p[0];
    for (int i = 1; i < 12; i++) top = std::max(top, p[i]);
    for (int i = 0; i < 12; i++) p[i] /= top;
}

}  // namespace

MidiAnalysis analyze_midi(const uint8_t *data, size_t n) {
    const Parsed p = parse(data, n);
    const int64_t us = tempo_us(p);
    if (us <= 0) throw Error("the MIDI file's tempo is zero");
    const double exact = 60000000.0 / (double)us;
    MidiAnalysis out;
    out.notes = p.notes.size();
    if (p.notes.size() < kMinNotes) {
        out.keys[0] = {"C", 0.0};                                // NO_KEYS
        out.keys[1] = {"Am", 0.0};
        out.keys[2] = {"G", 0.0};
    } else {
        double pcp[12];
        pitch_class_profile(p.notes, 0.0, 0.0, false, pcp);
        normalise(pcp);
        const KeyScores scores = key_scores_f64(pcp);
        const int win = key_winner(scores);
        // agreement over four equal slices of the piece, like the audio path's 10 s windows
        int64_t end = p.notes[0].end;
        for (const Note &note : p.notes) end = std::max(end, note.end);
        size_t wins = 0, count = 0;
        for (int k = 0; k < 4; k++) {
            double seg[12];
            pitch_class_profile(p.notes, (double)(end * k) / 4.0, (double)(end * (k + 1)) / 4.0, true, seg);
            int nonzero = 0;
            for (double v : seg) nonzero += v != 0.0;
            if (nonzero >= 3) {
                normalise(seg);
                wins += key_winner(key_scores_f64(seg)) == win;
                count++;
            }
        }
        key_top3(scores, count ? (double)wins / (double)count : 1.0, out.keys);
    }
    out.bpm = np::py_round(exact, 1);
    out.bpm_exact = np::py_round(exact, 2);
    return out;
}

}  // namespace bk
