#include "PixelCore.h"
#include <zlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>

static double difference(const uint8_t *a, const uint8_t *b, int w, int h, int d) {
    int overlap = h - d, samples = 0;
    uint64_t sum = 0;
    // Inner columns avoid window edges/scrollbars; rows cover the whole overlap.
    int margin = w > 8 ? 2 : 0;
    int columns = w - 2 * margin;
    int nx = columns < 37 ? columns : 37;
    int ny = overlap < 43 ? overlap : 43;
    if (nx < 1 || ny < 1) return 1.0;
    for (int j = 0; j < ny; j++) {
        int y = ny == 1 ? 0 : j * (overlap - 1) / (ny - 1);
        for (int i = 0; i < nx; i++) {
            int x = margin + (nx == 1 ? 0 : i * (columns - 1) / (nx - 1));
            size_t ia = ((size_t)(y + d) * w + x) * 4;
            size_t ib = ((size_t)y * w + x) * 4;
            for (int c = 0; c < 3; c++) sum += abs((int)a[ia + c] - b[ib + c]);
            samples += 3;
        }
    }
    return (double)sum / ((double)samples * 255.0);
}

static double dense_difference(const uint8_t *a, const uint8_t *b, int w, int h, int d) {
    int margin = w > 8 ? 2 : 0;
    uint64_t sum = 0;
    for (int y = 0; y < h - d; y++) {
        for (int x = margin; x < w - margin; x++) {
            size_t ia = ((size_t)(y + d) * w + x) * 4;
            size_t ib = ((size_t)y * w + x) * 4;
            for (int c = 0; c < 3; c++) sum += abs((int)a[ia+c] - b[ib+c]);
        }
    }
    return (double)sum / ((double)(h-d) * (w-2*margin) * 3 * 255);
}

int evb_match_vertical(const uint8_t *a, const uint8_t *b, int w, int h,
                       int min_overlap, int *shift, double *error) {
    if (!a || !b || w < 1 || h < 2 || min_overlap < 1 || min_overlap >= h) return 3;
    double stationary = difference(a, b, w, h, 0);
    if (stationary < 0.0015) { *shift = 0; *error = stationary; return 1; }
    int limit = h - min_overlap, best = 0;
    double score = 2.0;
    double *scores = malloc(((size_t)limit + 1) * sizeof(double));
    double *dense = malloc(((size_t)limit + 1) * sizeof(double));
    if (!scores || !dense) { free(scores); free(dense); return 3; }
    for (int d = 1; d <= limit; d++) {
        scores[d] = difference(a, b, w, h, d); dense[d] = 2.0;
        if (scores[d] < score) { score = scores[d]; best = d; }
    }
    if (score > 0.018) { *error = score; free(scores); free(dense); return 3; }
    // Sparse matching locates candidates, but native pixel comparisons decide
    // between repeated lines. This preserves narrow line numbers near the edge.
    double tolerance = fmax(0.0005, score * 0.35), full_best = 2.0;
    for (int d = 1; d <= limit; d++) {
        if (scores[d] <= score + tolerance) {
            dense[d] = dense_difference(a, b, w, h, d);
            if (dense[d] < full_best) { full_best = dense[d]; best = d; }
        }
    }
    double second = 2.0;
    for (int d = 1; d <= limit; d++) {
        if (abs(d-best) > 3 && dense[d] < second) second = dense[d];
    }
    *shift = best; *error = full_best;
    free(scores); free(dense);
    if (full_best > 0.018) return 3;
    if (full_best < 1e-7) return second < 1e-7 ? 2 : 0;
    if (second-full_best < 0.0005 && second < full_best * 1.5 + 0.00005) return 2;
    return 0;
}

static int put32(FILE *f, uint32_t n) {
    uint8_t b[4] = {(uint8_t)(n >> 24), (uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n};
    return fwrite(b, 1, 4, f) == 4;
}
static int chunk(FILE *f, const char type[4], const uint8_t *bytes, uint32_t count) {
    if (!put32(f, count) || fwrite(type, 1, 4, f) != 4) return 0;
    if (count && fwrite(bytes, 1, count, f) != count) return 0;
    uLong crc = crc32(0, (const Bytef *)type, 4);
    if (count) crc = crc32(crc, bytes, count);
    return put32(f, (uint32_t)crc);
}

int evb_write_png(const char *raw_path, const char *png_path, uint32_t w, uint32_t h,
                  char *message, size_t message_size) {
    FILE *input = NULL, *output = NULL;
    uint8_t *row = NULL, compressed[65536];
    z_stream stream = {0}; int initialized = 0, ok = 0;
    const char *reason = "Unable to export PNG";
    if (!w || !h || w > 0x7fffffff || h > 0x7fffffff || (uint64_t)w * 4 + 1 > SIZE_MAX) {
        reason = "Dimensions exceed the PNG file format. Pixels were not resized."; goto cleanup;
    }
    input = fopen(raw_path, "rb");
    if (!input) { reason = "Cannot read capture spool"; goto cleanup; }
    struct stat st;
    if (fstat(fileno(input), &st) || (uint64_t)st.st_size != (uint64_t)w * h * 4) {
        reason = "Capture spool length does not match its native pixel dimensions"; goto cleanup;
    }
    // Refuse to overwrite an existing file, including an unrelated partial export.
    output = fopen(png_path, "wbx");
    if (!output) { reason = "Cannot create PNG destination"; goto cleanup; }
    const uint8_t signature[8] = {137,80,78,71,13,10,26,10};
    if (fwrite(signature, 1, 8, output) != 8) { reason = "Disk write failed"; goto cleanup; }
    uint8_t header[13] = {w>>24,w>>16,w>>8,w,h>>24,h>>16,h>>8,h,8,6,0,0,0};
    if (!chunk(output,"IHDR",header,13)) goto disk_error;
    const uint8_t intent = 0;
    if (!chunk(output,"sRGB",&intent,1)) goto disk_error;
    size_t row_size = (size_t)w * 4 + 1;
    row = malloc(row_size);
    if (!row) { reason = "Not enough memory for a single pixel row"; goto cleanup; }
    row[0] = 0; // PNG filter None, preserving the raw RGBA samples exactly.
    if (deflateInit(&stream, 3) != Z_OK) { reason = "Cannot initialize PNG compressor"; goto cleanup; }
    initialized = 1;
    for (uint32_t y = 0; y < h; y++) {
        if (fread(row + 1, 1, row_size - 1, input) != row_size - 1) {
            reason = "Capture spool ended unexpectedly"; goto cleanup;
        }
        size_t consumed = 0;
        while (consumed < row_size) {
            size_t n = row_size - consumed;
            if (n > 1048576) n = 1048576;
            stream.next_in = row + consumed; stream.avail_in = (uInt)n;
            while (stream.avail_in) {
                stream.next_out = compressed; stream.avail_out = sizeof(compressed);
                if (deflate(&stream,Z_NO_FLUSH) != Z_OK) { reason = "PNG compression failed"; goto cleanup; }
                uint32_t size = sizeof(compressed) - stream.avail_out;
                if (size && !chunk(output,"IDAT",compressed,size)) goto disk_error;
            }
            consumed += n;
        }
    }
    int result;
    do {
        stream.next_out = compressed; stream.avail_out = sizeof(compressed);
        result = deflate(&stream,Z_FINISH);
        if (result != Z_OK && result != Z_STREAM_END) { reason = "PNG finalization failed"; goto cleanup; }
        uint32_t size = sizeof(compressed) - stream.avail_out;
        if (size && !chunk(output,"IDAT",compressed,size)) goto disk_error;
    } while (result != Z_STREAM_END);
    if (!chunk(output,"IEND",NULL,0) || fflush(output) || fsync(fileno(output))) goto disk_error;
    ok = 1; goto cleanup;
disk_error:
    reason = "Disk write failed. The capture spool is preserved.";
cleanup:
    if (initialized) deflateEnd(&stream);
    free(row);
    if (input) fclose(input);
    if (output) { if (fclose(output) && ok) { ok = 0; reason = "PNG close failed"; } if (!ok) unlink(png_path); }
    if (!ok && message && message_size) snprintf(message,message_size,"%s (%s)",reason,strerror(errno));
    return ok ? 0 : -1;
}
