/*
 * np.h: the pieces of numpy / Python arithmetic the analyzer's answers depend on, written the way
 * numpy 1.26 and CPython compute them, so the core's rounding lands where the reference's does.
 * One owner for each: nothing else in core/ re-implements a sum order, a rounding rule or a
 * percentile.
 */
#ifndef BK_NP_H
#define BK_NP_H

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace bk {
namespace np {

// numpy's pairwise summation (umath loops, @TYPE@_pairwise_sum): what np.sum / np.mean do over a
// contiguous run.  n < 8: plain loop.  n <= 128: eight running sums.  Larger: split in two.
template <typename T>
T pairwise_sum(const T *a, size_t n) {
    if (n < 8) {
        T res = 0;
        for (size_t i = 0; i < n; i++) res += a[i];
        return res;
    }
    if (n <= 128) {
        T r[8];
        for (int j = 0; j < 8; j++) r[j] = a[j];
        size_t i;
        for (i = 8; i < n - (n % 8); i += 8)
            for (int j = 0; j < 8; j++) r[j] += a[i + j];
        T res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]));
        for (; i < n; i++) res += a[i];
        return res;
    }
    size_t n2 = n / 2;
    n2 -= n2 % 8;
    return pairwise_sum(a, n2) + pairwise_sum(a + n2, n - n2);
}

inline double mean(const std::vector<double> &v) { return pairwise_sum(v.data(), v.size()) / (double)v.size(); }

// CPython's round(x, ndigits) for a float: the correctly rounded decimal string, read back.
inline double py_round(double x, int ndigits) {
    char buf[64];
    snprintf(buf, sizeof buf, "%.*f", ndigits, x);
    return strtod(buf, nullptr);
}

// CPython's round(x) with no digits: to the nearest whole number, halves to the even one.
inline long py_round_int(double x) { return std::lrint(std::nearbyint(x)); }

// np.percentile(v, q) with the default "linear" method.  Sorts a copy.
inline double percentile(std::vector<double> v, double q) {
    const size_t n = v.size();
    std::sort(v.begin(), v.end());
    const double idx = q / 100.0 * (double)(n - 1);
    const size_t lo = (size_t)std::floor(idx);
    const size_t hi = std::min(lo + 1, n - 1);
    const double t = idx - (double)lo, a = v[lo], b = v[hi], d = b - a;
    return t >= 0.5 ? b - d * (1.0 - t) : a + d * t;      // numpy's _lerp
}

// np.convolve(a, np.ones(15) / 15, mode='same'), for len(a) >= 15.
inline std::vector<double> smooth15(const std::vector<double> &a) {
    const long n = (long)a.size();
    const double w = 1.0 / 15.0;
    std::vector<double> out(a.size());
    for (long i = 0; i < n; i++) {
        double s = 0;
        for (long k = std::max<long>(0, i - 7); k <= std::min<long>(n - 1, i + 7); k++) s += a[k] * w;
        out[i] = s;
    }
    return out;
}

// np.nan_to_num(np.corrcoef(x, y)[0, 1]): Pearson r in double, 0 when either side is constant.
template <typename X, typename Y>
double corrcoef(const X *x, const Y *y, size_t n) {
    std::vector<double> dx(n), dy(n);
    for (size_t i = 0; i < n; i++) { dx[i] = (double)x[i]; dy[i] = (double)y[i]; }
    const double mx = mean(dx), my = mean(dy);
    double sxx = 0, syy = 0, sxy = 0;
    for (size_t i = 0; i < n; i++) {
        dx[i] -= mx;
        dy[i] -= my;
        sxx += dx[i] * dx[i];
        syy += dy[i] * dy[i];
        sxy += dx[i] * dy[i];
    }
    const double f = (double)(n - 1);
    double r = (sxy / f) / std::sqrt(sxx / f) / std::sqrt(syy / f);
    if (std::isnan(r)) return 0.0;                        // nan_to_num
    return std::min(1.0, std::max(-1.0, r));              // corrcoef clips to [-1, 1]
}

// np.hanning(m).astype(np.float32)
inline std::vector<float> hanning_f32(int m) {
    std::vector<float> w((size_t)m);
    for (int i = 0; i < m; i++) w[(size_t)i] = (float)(0.5 + 0.5 * std::cos(M_PI * (double)(1 - m + 2 * i) / (double)(m - 1)));
    return w;
}

}  // namespace np
}  // namespace bk

#endif
