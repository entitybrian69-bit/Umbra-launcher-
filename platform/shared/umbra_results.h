// The two one-line result files that sit next to the log, and the block the
// overlay draws from them.
//
// Why this is a header of pure functions: the first version of it lived as
// static functions inside umbra_app.c, so no test could reach it, and the bug it
// shipped with -- the paths were computed only when something was logged, which
// happens *after* the start-up read -- was invisible until an emulator run
// showed "last run: nothing recorded yet" after a restart. Everything here is
// file arithmetic and can be tested on a desktop without a window.
#ifndef UMBRA_RESULTS_H
#define UMBRA_RESULTS_H

#include <stdio.h>
#include <string.h>

// "<dir of base>/<name>", or <name> alone when base has no directory part.
static void umbra_result_path(const char *base, const char *name, char *out, size_t cap) {
    const char *slash = base ? strrchr(base, '/') : NULL;
    if (!slash || cap == 0) {
        if (cap) snprintf(out, cap, "%s", name ? name : "");
        return;
    }
    size_t dirlen = (size_t)(slash - base);
    if (dirlen + 1 + strlen(name) + 1 > cap) {
        snprintf(out, cap, "%s", name);
        return;
    }
    memcpy(out, base, dirlen);
    out[dirlen] = '/';
    snprintf(out + dirlen + 1, cap - dirlen - 1, "%s", name);
}

// One line, overwritten. An empty text is not written: a blank file would read
// back as a result nobody produced.
static void umbra_result_save(const char *path, const char *text) {
    if (!path || !path[0] || !text || !text[0]) return;
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fprintf(f, "%s\n", text);
    fclose(f);
}

// The line, without its newline. Returns its length, or 0 when there is nothing
// to read.
static int umbra_result_load(const char *path, char *out, size_t cap) {
    if (!out || cap == 0) return 0;
    out[0] = 0;
    FILE *f = path && path[0] ? fopen(path, "rb") : NULL;
    if (!f) return 0;
    size_t n = fread(out, 1, cap - 1, f);
    fclose(f);
    out[n] = 0;
    while (n > 0 && (out[n - 1] == '\n' || out[n - 1] == '\r')) out[--n] = 0;
    return (int)n;
}

// "LAST RUN" plus a line per result that exists. Returns the number of lines, 0
// when neither result exists.
static int umbra_last_run_block(char *out, size_t cap, const char *selftest, const char *bench) {
    if (!out || cap == 0) return 0;
    out[0] = 0;
    if (!selftest || !selftest[0]) {
        if (!bench || !bench[0]) return 0;
    }
    int n = snprintf(out, cap, "LAST RUN");
    if (selftest && selftest[0]) {
        n += snprintf(out + n, cap - (size_t)n, "\n%s", selftest);
    }
    if (bench && bench[0]) {
        n += snprintf(out + n, cap - (size_t)n, "\n%s", bench);
    }
    int lines = 1;
    for (const char *q = out; *q; q++) {
        if (*q == '\n') lines++;
    }
    return lines;
}

#endif
