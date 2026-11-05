#ifndef TAPE_ATOMICS_H
#define TAPE_ATOMICS_H

#include <stdint.h>

// Lock-free 64 bit atomics for the realtime render path. Swift on macOS 14
// has no standard library atomics, so these wrap the compiler builtins.

static inline int64_t tape_atomic_load(const int64_t *p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline void tape_atomic_store(int64_t *p, int64_t v) {
    __atomic_store_n(p, v, __ATOMIC_RELEASE);
}

static inline int64_t tape_atomic_add(int64_t *p, int64_t d) {
    return __atomic_add_fetch(p, d, __ATOMIC_ACQ_REL);
}

#endif
