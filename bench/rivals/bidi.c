/* The rows of bench/bidi.zig through SheenBidi 3.0.0 and ICU4C (ubidi): the
 * same paragraphs and line ends. By hand, see README.md. Each row is timed
 * in batches grown to a millisecond, 31 samples, the median printed in
 * microseconds a unit. ICU is given UTF-16, its own form, converted once
 * outside the timing; SheenBidi the UTF-8. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <SheenBidi/SheenBidi.h>
#include <unicode/ubidi.h>
#include <unicode/ustring.h>

static const char *sentences[] = {
#include "sentences.inc"
};
static const char *names[] = {"english", "hebrew", "arabic", "mixed"};
enum { kinds = 4, size = 16 * 1024 };

typedef struct {
    char *text;
    size_t len;
    size_t breaks[1024];
    size_t nbreaks;
    UChar *u16;
    int32_t u16len;
    int32_t ubreaks[1024];
} Input;

static Input inputs[kinds];
static volatile size_t sink;

static double now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e9 + t.tv_nsec;
}

typedef void (*Work)(Input *);

static int cmp(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static void row(const char *rival, const char *what, int k, Work f) {
    uint64_t batch = 1;
    for (;;) {
        double t = now_ns();
        for (uint64_t i = 0; i < batch; i++) f(&inputs[k]);
        if (now_ns() - t > 1e6 || batch > (1u << 24)) break;
        batch *= 2;
    }
    double samples[31];
    for (int s = 0; s < 31; s++) {
        double t = now_ns();
        for (uint64_t i = 0; i < batch; i++) f(&inputs[k]);
        samples[s] = (now_ns() - t) / batch;
    }
    qsort(samples, 31, sizeof samples[0], cmp);
    printf("{\"row\":\"bidi %s %s\",\"rival\":\"%s\",\"median_us\":%.1f,\"best_us\":%.1f}\n", what, names[k], rival, samples[15] / 1000, samples[0] / 1000);
}

static void sheen_resolve(Input *in) {
    SBCodepointSequence seq = {SBStringEncodingUTF8, in->text, in->len};
    SBAlgorithmRef algo = SBAlgorithmCreate(&seq);
    SBParagraphRef p = SBAlgorithmCreateParagraph(algo, 0, in->len, SBLevelDefaultLTR);
    sink += SBParagraphGetBaseLevel(p);
    SBParagraphRelease(p);
    SBAlgorithmRelease(algo);
}

static void sheen_lines(Input *in) {
    SBCodepointSequence seq = {SBStringEncodingUTF8, in->text, in->len};
    SBAlgorithmRef algo = SBAlgorithmCreate(&seq);
    SBParagraphRef p = SBAlgorithmCreateParagraph(algo, 0, in->len, SBLevelDefaultLTR);
    size_t start = 0;
    for (size_t b = 0; b < in->nbreaks; b++) {
        SBLineRef line = SBParagraphCreateLine(p, start, in->breaks[b] - start);
        sink += SBLineGetRunCount(line);
        SBLineRelease(line);
        start = in->breaks[b];
    }
    SBParagraphRelease(p);
    SBAlgorithmRelease(algo);
}

static UBiDi *para, *line;

static void icu_resolve(Input *in) {
    UErrorCode e = U_ZERO_ERROR;
    ubidi_setPara(para, in->u16, in->u16len, UBIDI_DEFAULT_LTR, NULL, &e);
    sink += ubidi_getParaLevel(para);
}

static void icu_lines(Input *in) {
    UErrorCode e = U_ZERO_ERROR;
    ubidi_setPara(para, in->u16, in->u16len, UBIDI_DEFAULT_LTR, NULL, &e);
    int32_t start = 0;
    for (size_t b = 0; b < in->nbreaks; b++) {
        ubidi_setLine(para, start, in->ubreaks[b], line, &e);
        sink += ubidi_countRuns(line, &e);
        start = in->ubreaks[b];
    }
}

int main(int argc, char **argv) {
    const char *only = argc > 1 ? argv[1] : "";
    for (int k = 0; k < kinds; k++) {
        Input *in = &inputs[k];
        size_t sl = strlen(sentences[k]);
        size_t n = (size + sl - 1) / sl;
        in->text = malloc(n * sl);
        for (size_t i = 0; i < n; i++) memcpy(in->text + i * sl, sentences[k], sl);
        in->len = n * sl;
        size_t start = 0;
        while (start < in->len) {
            size_t end = start + 80 < in->len ? start + 80 : in->len;
            if (end < in->len) {
                while (end > start && in->text[end - 1] != ' ') end--;
                if (end == start) end = start + 80 < in->len ? start + 80 : in->len;
            }
            in->breaks[in->nbreaks++] = end;
            start = end;
        }
        UErrorCode e = U_ZERO_ERROR;
        in->u16 = malloc(in->len * 2);
        u_strFromUTF8(in->u16, (int32_t)in->len, &in->u16len, in->text, (int32_t)in->len, &e);
        for (size_t b = 0; b < in->nbreaks; b++) {
            int32_t units = 0;
            u_strFromUTF8(NULL, 0, &units, in->text, (int32_t)in->breaks[b], &e);
            e = U_ZERO_ERROR;
            in->ubreaks[b] = units;
        }
    }
    UErrorCode e = U_ZERO_ERROR;
    para = ubidi_openSized(size * 2, 0, &e);
    line = ubidi_openSized(size * 2, 0, &e);
    for (int k = 0; k < kinds; k++) {
        if (strstr("resolve", only) || !*only) row("SheenBidi 3.0.0", "resolve", k, sheen_resolve);
        if (strstr("resolve", only) || !*only) row("ICU4C " U_ICU_VERSION, "resolve", k, icu_resolve);
    }
    for (int k = 0; k < kinds; k++) {
        row("SheenBidi 3.0.0", "lines", k, sheen_lines);
        row("ICU4C " U_ICU_VERSION, "lines", k, icu_lines);
    }
    return 0;
}
