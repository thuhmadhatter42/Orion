#include "tempocnn.h"

#include <Accelerate/Accelerate.h>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>

#include "beatkey.h"
#include "error.h"
#include "log.h"
#include "mel.h"
#include "np.h"

namespace bk {

namespace {

constexpr int kLayers = 12;
// (mels, time) max-pool after these conv layers (tempocnn_np._POOL_AFTER)
int pool_h(int layer) { return (layer == 1 || layer == 3 || layer == 5 || layer == 7 || layer == 9) ? 2 : 1; }
int pool_t(int layer) { return (layer == 1 || layer == 3 || layer == 5 || layer == 7 || layer == 9 || layer == 11) ? 2 : 1; }

struct Conv {
    int cout = 0, cin = 0, k = 0;
    std::vector<float> taps;      // k matrices, each cin x cout row-major: taps[j][c][o] = w[o][c][j]
    std::vector<float> bias;      // cout
    std::vector<float> bn_mul;    // (1 / sqrt(var + eps)) * gamma
    std::vector<float> bn_add;    // beta - mean * mul
};

struct Weights {
    Conv conv[kLayers];
    std::vector<float> head;      // 128 x 256 row-major: head[c][o] = head_w[o][c]
    std::vector<float> head_b;    // 256
    int head_in = 0;
};

struct Tensor {
    std::vector<uint32_t> dims;
    std::vector<float> data;
};

std::mutex g_mu;
std::unique_ptr<const Weights> g_weights;       // set once, never replaced

const Tensor &need(const std::map<std::string, Tensor> &t, const std::string &name, std::vector<uint32_t> dims) {
    auto it = t.find(name);
    if (it == t.end()) throw Error("the weights file has no tensor '" + name + "'");
    if (it->second.dims != dims) throw Error("tensor '" + name + "' has the wrong shape");
    return it->second;
}

std::map<std::string, Tensor> read_bkw(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) throw Error(std::string("cannot open the weights file ") + path + ": " + strerror(errno));
    std::map<std::string, Tensor> out;
    try {
        auto get = [&](void *p, size_t n) {
            if (n && fread(p, 1, n, f) != n) throw Error(std::string("the weights file is cut short: ") + path);
        };
        char magic[4];
        get(magic, 4);
        if (memcmp(magic, "BKW1", 4) != 0) throw Error(std::string("not a Beat Key weights file (no BKW1 header): ") + path);
        uint32_t count = 0;
        get(&count, 4);
        if (count == 0 || count > 1024) throw Error(std::string("the weights file's tensor count is not sane: ") + path);
        for (uint32_t i = 0; i < count; i++) {
            uint16_t len = 0;
            get(&len, 2);
            if (len == 0 || len > 64) throw Error(std::string("a tensor name in the weights file is not sane: ") + path);
            std::string name(len, '\0');
            get(&name[0], len);
            uint32_t ndim = 0;
            get(&ndim, 4);
            if (ndim > 4) throw Error("tensor '" + name + "' has more than 4 dimensions");
            Tensor t;
            t.dims.resize(ndim);
            size_t total = 1;
            for (uint32_t d = 0; d < ndim; d++) {
                get(&t.dims[d], 4);
                if (t.dims[d] == 0 || t.dims[d] > 4096) throw Error("tensor '" + name + "' has a dimension that is not sane");
                total *= t.dims[d];
            }
            if (total > (1u << 24)) throw Error("tensor '" + name + "' is too large");
            t.data.resize(total);
            get(t.data.data(), total * sizeof(float));
            for (float v : t.data)
                if (!std::isfinite(v)) throw Error("tensor '" + name + "' holds a value that is not a number");
            if (!out.emplace(name, std::move(t)).second) throw Error("tensor '" + name + "' is in the weights file twice");
        }
        char extra;
        if (fread(&extra, 1, 1, f) == 1) throw Error(std::string("the weights file has bytes after its last tensor: ") + path);
    } catch (...) {
        fclose(f);
        throw;
    }
    fclose(f);
    return out;
}

std::unique_ptr<const Weights> build(const std::map<std::string, Tensor> &t) {
    std::unique_ptr<Weights> w(new Weights);
    uint32_t prev_out = 1;
    for (int i = 0; i < kLayers; i++) {
        const std::string n = std::to_string(i);
        auto cw = t.find("conv" + n + "_w");
        if (cw == t.end() || cw->second.dims.size() != 3) throw Error("the weights file has no conv" + n + "_w of 3 dimensions");
        const uint32_t cout = cw->second.dims[0], cin = cw->second.dims[1], k = cw->second.dims[2];
        if (cin != prev_out) throw Error("conv" + n + " takes " + std::to_string(cin) + " channels but the layer before gives " + std::to_string(prev_out));
        if (k % 2 != 1) throw Error("conv" + n + " has an even kernel");
        Conv &c = w->conv[i];
        c.cout = (int)cout;
        c.cin = (int)cin;
        c.k = (int)k;
        c.taps.resize((size_t)k * cin * cout);
        for (uint32_t j = 0; j < k; j++)
            for (uint32_t ci = 0; ci < cin; ci++)
                for (uint32_t co = 0; co < cout; co++)
                    c.taps[((size_t)j * cin + ci) * cout + co] = cw->second.data[((size_t)co * cin + ci) * k + j];
        c.bias = need(t, "conv" + n + "_b", {cout}).data;
        const std::vector<float> &gamma = need(t, "bn" + n + "_gamma", {cout}).data;
        const std::vector<float> &beta = need(t, "bn" + n + "_beta", {cout}).data;
        const std::vector<float> &mean = need(t, "bn" + n + "_mean", {cout}).data;
        const std::vector<float> &var = need(t, "bn" + n + "_var", {cout}).data;
        const float eps = need(t, "bn" + n + "_eps", {}).data[0];
        c.bn_mul.resize(cout);
        c.bn_add.resize(cout);
        for (uint32_t o = 0; o < cout; o++) {
            const float mul = (1.0f / std::sqrt(var[o] + eps)) * gamma[o];
            c.bn_mul[o] = mul;
            c.bn_add[o] = beta[o] - mean[o] * mul;
        }
        prev_out = cout;
    }
    const Tensor &hw = need(t, "head_w", {(uint32_t)kTempoClasses, prev_out});
    w->head_in = (int)prev_out;
    w->head.resize((size_t)prev_out * kTempoClasses);
    for (uint32_t c = 0; c < prev_out; c++)
        for (int o = 0; o < kTempoClasses; o++) w->head[(size_t)c * kTempoClasses + o] = hw.data[(size_t)o * prev_out + c];
    w->head_b = need(t, "head_b", {(uint32_t)kTempoClasses}).data;
    if (t.size() != (size_t)kLayers * 7 + 2) throw Error("the weights file holds tensors this network does not use");
    return std::unique_ptr<const Weights>(w.release());
}

const Weights &weights() {
    std::lock_guard<std::mutex> lock(g_mu);
    if (!g_weights) throw Error("The analyzer is incomplete: the tempo weights are not loaded");
    return *g_weights;
}

void sgemm(int m, int n, int k, const float *a, int lda, const float *b, int ldb, float *c, int ldc) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"   // the classic CBLAS: it runs on macOS 12
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, m, n, k, 1.0f, a, lda, b, ldb, 0.0f, c, ldc);
#pragma clang diagnostic pop
}

// One patch through the network.  in: (40 mels, 256 frames, 1) row-major.  out: 256 softmax values.
void predict_one(const Weights &w, const float *patch, float *out) {
    int H = kMelBands, T = kPatchFrames, C = 1;
    std::vector<float> x(patch, patch + (size_t)H * T), xp, y, tmp;
    for (int i = 0; i < kLayers; i++) {
        const Conv &cv = w.conv[i];
        const int k = cv.k, pad = (k - 1) / 2, TP = T + k - 1, CO = cv.cout;
        // time-padded copy: xp[h][pad + t][c]
        xp.assign((size_t)H * TP * C, 0.0f);
        for (int h = 0; h < H; h++)
            memcpy(&xp[((size_t)h * TP + pad) * C], &x[(size_t)h * T * C], (size_t)T * C * sizeof(float));
        // out = sum over taps j of xp[:, j : j + T, :] @ tap_j, one sgemm per tap over every row at once
        // (the k - 1 rows between mel bands are computed and skipped)
        const int rows = H * TP - (k - 1);
        y.assign((size_t)H * T * CO, 0.0f);
        tmp.resize((size_t)rows * CO);
        for (int j = 0; j < k; j++) {
            sgemm(rows, CO, C, &xp[(size_t)j * C], C, &cv.taps[(size_t)j * C * CO], CO, tmp.data(), CO);
            for (int h = 0; h < H; h++) {
                const float *src = &tmp[(size_t)h * TP * CO];
                float *dst = &y[(size_t)h * T * CO];
                for (size_t e = 0; e < (size_t)T * CO; e++) dst[e] += src[e];
            }
        }
        // + bias -> ReLU -> BatchNorm
        for (size_t r = 0; r < (size_t)H * T; r++) {
            float *row = &y[r * CO];
            for (int o = 0; o < CO; o++) {
                float v = row[o] + cv.bias[(size_t)o];
                v = v > 0.0f ? v : 0.0f;
                row[o] = v * cv.bn_mul[(size_t)o] + cv.bn_add[(size_t)o];
            }
        }
        // max-pool (mels, time)
        const int ph = pool_h(i), pt = pool_t(i), H2 = H / ph, T2 = T / pt;
        if (ph == 1 && pt == 1) {
            x.swap(y);
        } else {
            x.assign((size_t)H2 * T2 * CO, 0.0f);
            for (int h = 0; h < H2; h++)
                for (int t = 0; t < T2; t++)
                    for (int o = 0; o < CO; o++) {
                        float best = y[(((size_t)h * ph) * T + (size_t)t * pt) * CO + o];
                        for (int a = 0; a < ph; a++)
                            for (int b = 0; b < pt; b++) {
                                const float v = y[(((size_t)h * ph + a) * T + (size_t)t * pt + b) * CO + o];
                                if (v > best) best = v;
                            }
                        x[((size_t)h * T2 + t) * CO + o] = best;
                    }
        }
        H = H2;
        T = T2;
        C = CO;
    }
    if (C != w.head_in || H < 1 || T < 1) throw Error("the network's last layer does not fit its head");
    // 1x1 conv to 256 + ReLU, mean over (mels, time), softmax
    const int pos = H * T;
    y.resize((size_t)pos * kTempoClasses);
    sgemm(pos, kTempoClasses, C, x.data(), C, w.head.data(), kTempoClasses, y.data(), kTempoClasses);
    float logits[kTempoClasses];
    for (int o = 0; o < kTempoClasses; o++) {
        float acc = 0.0f;
        for (int p = 0; p < pos; p++) {
            float v = y[(size_t)p * kTempoClasses + o] + w.head_b[(size_t)o];
            v = v > 0.0f ? v : 0.0f;
            acc = p == 0 ? v : acc + v;
        }
        logits[o] = acc / (float)pos;
    }
    float top = logits[0];
    for (int o = 1; o < kTempoClasses; o++)
        if (logits[o] > top) top = logits[o];
    float e[kTempoClasses];
    for (int o = 0; o < kTempoClasses; o++) e[o] = std::exp(logits[o] - top);
    const float sum = np::pairwise_sum(e, (size_t)kTempoClasses);
    for (int o = 0; o < kTempoClasses; o++) out[o] = e[o] / sum;
}

}  // namespace

int weights_load(const char *path, char *err, size_t err_cap) {
    if (!path || !path[0]) {
        fail("weights", err, err_cap, "no weights file path was given");
        return BK_ERR_BAD_WEIGHTS;
    }
    {
        std::lock_guard<std::mutex> lock(g_mu);
        if (g_weights) return BK_OK;
    }
    try {
        std::unique_ptr<const Weights> w = build(read_bkw(path));
        std::lock_guard<std::mutex> lock(g_mu);
        if (!g_weights) {
            g_weights = std::move(w);
            logf("weights", "tempo weights loaded from %s", path);
        }
        return BK_OK;
    } catch (const std::exception &e) {
        fail("weights", err, err_cap, "%s", e.what());
        return BK_ERR_BAD_WEIGHTS;
    }
}

bool weights_ready() {
    std::lock_guard<std::mutex> lock(g_mu);
    return g_weights != nullptr;
}

Tempo tempo_from_bands(const std::vector<float> &bands, size_t n_frames) {
    const Weights &w = weights();
    Tempo out;
    const size_t n = n_frames >= (size_t)kPatchFrames ? (n_frames - kPatchFrames) / kPatchHop + 1 : 0;
    if (n == 0) return out;
    out.pred.resize(n * kTempoClasses);
    out.classes.resize(n);
    const size_t flat_n = (size_t)kPatchFrames * kMelBands;
    std::vector<float> dev(flat_n), patch(flat_n);
    for (size_t p = 0; p < n; p++) {
        // TensorNormalize('standard') per patch, float32, numpy's sum order
        const float *flat = &bands[p * kPatchHop * kMelBands];
        const float mean = np::pairwise_sum(flat, flat_n) / (float)flat_n;
        for (size_t i = 0; i < flat_n; i++) {
            const float d = flat[i] - mean;
            dev[i] = d * d;
        }
        float std = std::sqrt(np::pairwise_sum(dev.data(), flat_n) / (float)flat_n);
        if (std == 0.0f) std = 1.0f;
        // (frames, mels) -> (mels, frames)
        for (int t = 0; t < kPatchFrames; t++)
            for (int m = 0; m < kMelBands; m++)
                patch[(size_t)m * kPatchFrames + t] = (flat[(size_t)t * kMelBands + m] - mean) / std;
        float *row = &out.pred[p * kTempoClasses];
        predict_one(w, patch.data(), row);
        int best = 0;
        for (int o = 1; o < kTempoClasses; o++)
            if (row[o] > row[best]) best = o;
        out.classes[p] = best;
    }
    // 'majority': the most-voted class; ties go to the class seen first
    int best = out.classes[0], best_votes = 0;
    std::vector<int> seen;
    for (int c : out.classes) {
        bool was = false;
        for (int s : seen) was = was || s == c;
        if (was) continue;
        int votes = 0;
        for (int d : out.classes) votes += d == c;
        if (votes > best_votes) { best = c; best_votes = votes; }
        seen.push_back(c);
    }
    out.global_bpm = (double)(best + kBpmOffset);
    return out;
}

Tempo tempo(const float *audio_11k, size_t n) {
    size_t n_frames = 0;
    const std::vector<float> bands = mel_bands(audio_11k, n, &n_frames);
    return tempo_from_bands(bands, n_frames);
}

}  // namespace bk
