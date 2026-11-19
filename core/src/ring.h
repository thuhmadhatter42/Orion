/*
 * ring.h: the lock-free single-producer / single-consumer ring between the audio thread and the
 * worker (plan A4.1).  One per analyzer.
 *   push   the AUDIO thread only.  No allocation, no lock, no system call.  When there is no room
 *          it takes what fits, drops the rest and counts the dropped frames; it never waits.
 *   pop    the worker thread only.
 * All memory is allocated in the constructor.  Capacity is rounded up to a power of two.
 */
#ifndef BK_RING_H
#define BK_RING_H

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>

namespace bk {

class Ring {
public:
    explicit Ring(size_t min_capacity) {
        size_t cap = 1024;
        while (cap < min_capacity) cap <<= 1;
        buf_.reset(new float[cap]());
        mask_ = cap - 1;
    }

    size_t capacity() const noexcept { return mask_ + 1; }

    size_t push(const float *x, size_t n) noexcept {
        const uint64_t head = head_.load(std::memory_order_relaxed);
        const uint64_t tail = tail_.load(std::memory_order_acquire);
        const size_t room = capacity() - (size_t)(head - tail);
        const size_t take = n < room ? n : room;
        if (take) {
            const size_t at = (size_t)head & mask_;
            const size_t first = take < capacity() - at ? take : capacity() - at;
            memcpy(buf_.get() + at, x, first * sizeof(float));
            memcpy(buf_.get(), x + first, (take - first) * sizeof(float));
            head_.store(head + take, std::memory_order_release);
        }
        if (take < n) dropped_.fetch_add(n - take, std::memory_order_relaxed);
        return take;
    }

    size_t pop(float *out, size_t max) noexcept {
        const uint64_t tail = tail_.load(std::memory_order_relaxed);
        const uint64_t head = head_.load(std::memory_order_acquire);
        const size_t have = (size_t)(head - tail);
        const size_t take = max < have ? max : have;
        if (take) {
            const size_t at = (size_t)tail & mask_;
            const size_t first = take < capacity() - at ? take : capacity() - at;
            memcpy(out, buf_.get() + at, first * sizeof(float));
            memcpy(out + first, buf_.get(), (take - first) * sizeof(float));
            tail_.store(tail + take, std::memory_order_release);
        }
        return take;
    }

    size_t available() const noexcept {
        return (size_t)(head_.load(std::memory_order_acquire) - tail_.load(std::memory_order_acquire));
    }
    uint64_t dropped() const noexcept { return dropped_.load(std::memory_order_relaxed); }

private:
    std::unique_ptr<float[]> buf_;
    size_t mask_ = 0;
    alignas(64) std::atomic<uint64_t> head_{0};     // written by the producer
    alignas(64) std::atomic<uint64_t> tail_{0};     // written by the consumer
    alignas(64) std::atomic<uint64_t> dropped_{0};  // written by the producer
};

}  // namespace bk

#endif
