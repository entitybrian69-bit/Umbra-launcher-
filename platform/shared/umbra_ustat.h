// A frame-time ledger with percentiles, and a count of frames that broke a budget.
//
// The benchmark block reports average, 1% low and worst for a whole run. That is the wrong
// shape for the question step 1 must answer ("no frame may block over ~50 ms of CPU
// work"): an average cannot show a spike, a 1% low is a rate, and one worst number says
// nothing about how often it happened or in which phase.
//
// What is here instead is a windowed ledger. A phase resets it, does its work, and
// reports, so "walking at radius 4" is measured while walking at radius 4 and not averaged
// with the loading screen and the self-test.
//
// Header-only and allocation-free: a fixed ring, overwritten when full, so nothing here
// can lengthen the frame it is measuring.

#ifndef UMBRA_USTAT_H
#define UMBRA_USTAT_H

#include <stdint.h>
#include <stdio.h>

#define UMBRA_USTAT_CAP 2048

typedef struct {
    int64_t us[UMBRA_USTAT_CAP];
    int64_t n;
    int64_t head;
    int64_t budget_us;
    int64_t over_budget;
    int64_t worst_us;
    int64_t worst_at_frame;
    int64_t total_us;
} umbra_ustat;

static inline void umbra_ustat_reset(umbra_ustat *p, int64_t budget_ms) {
    p->n = 0;
    p->head = 0;
    p->budget_us = budget_ms * 1000;
    p->over_budget = 0;
    p->worst_us = 0;
    p->worst_at_frame = -1;
    p->total_us = 0;
}

// One frame's CPU time. Returns 1 when it broke the budget.
static inline int umbra_ustat_add(umbra_ustat *p, int64_t us) {
    if (us < 0) us = 0;
    p->us[p->head] = us;
    p->head = (p->head + 1) % UMBRA_USTAT_CAP;
    p->total_us += us;
    if (us > p->worst_us) {
        p->worst_us = us;
        p->worst_at_frame = p->n;
    }
    p->n++;
    if (p->budget_us > 0 && us > p->budget_us) {
        p->over_budget++;
        return 1;
    }
    return 0;
}

// The frames still in the ring, sorted ascending. Insertion sort: no allocation, and the
// ledger is read a handful of times per run, never per frame.
static inline void umbra_ustat_sorted(const umbra_ustat *p, int64_t *out, int64_t *count) {
    int64_t live = p->n < UMBRA_USTAT_CAP ? p->n : UMBRA_USTAT_CAP;
    int64_t start = (p->n <= UMBRA_USTAT_CAP) ? 0 : p->head;
    for (int64_t i = 0; i < live; i++) out[i] = p->us[(start + i) % UMBRA_USTAT_CAP];
    for (int64_t i = 1; i < live; i++) {
        int64_t v = out[i];
        int64_t j = i - 1;
        while (j >= 0 && out[j] > v) { out[j + 1] = out[j]; j--; }
        out[j + 1] = v;
    }
    *count = live;
}

// avg, median, 1% low, worst, and the budget verdict, in ms.
static inline void umbra_ustat_text(const umbra_ustat *p, const char *label, char *out,
                                    size_t cap) {
    int64_t sorted[UMBRA_USTAT_CAP];
    int64_t live = 0;
    if (p->n == 0) {
        snprintf(out, cap, "%s: no frames", label);
        return;
    }
    umbra_ustat_sorted(p, sorted, &live);
    int64_t avg = p->total_us / p->n;
    int64_t median = sorted[live / 2];
    // 1% low is the mean of the slowest 1%, the same definition the benchmark uses, so the
    // two numbers can be put side by side.
    int64_t p1n = live / 100 > 0 ? live / 100 : 1;
    int64_t p1sum = 0;
    for (int64_t i = 0; i < p1n && i < live; i++) p1sum += sorted[live - 1 - i];
    int64_t p1 = p1sum / p1n;
    snprintf(out, cap,
             "%s: %lld frame(s) avg %.1f ms (%lld fps), median %.1f, 1%% low %.1f (%lld fps), "
             "worst %.1f at frame %lld, %lld over %lld ms%s",
             label, (long long)p->n, avg / 1000.0,
             avg > 0 ? (long long)(1000000 / avg) : 0, median / 1000.0, p1 / 1000.0,
             p1 > 0 ? (long long)(1000000 / p1) : 0, p->worst_us / 1000.0,
             (long long)p->worst_at_frame, (long long)p->over_budget,
             (long long)(p->budget_us / 1000),
             p->over_budget > 0 ? " -- OVER BUDGET" : "");
}

#endif
