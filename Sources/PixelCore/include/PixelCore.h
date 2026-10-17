#ifndef EVB_PIXEL_CORE_H
#define EVB_PIXEL_CORE_H
#include <stdint.h>
#include <stddef.h>

// RGBA, tightly packed, top row first. A match never changes either image.
// Returns 0: downward shift, 1: unchanged, 2: ambiguous, 3: no overlap.
int evb_match_vertical(const uint8_t *previous, const uint8_t *current,
                       int width, int height, int minimum_overlap,
                       int *shift, double *error);

// Streams a native-resolution RGBA spool to PNG, with bounded working memory.
// Writes to a new destination; removes an incomplete destination on failure.
int evb_write_png(const char *raw_path, const char *png_path,
                  uint32_t width, uint32_t height, char *error, size_t error_size);

// Decode with the established libpng implementation, streaming rows to disk.
int evb_png_to_rgba(const char *png_path, const char *raw_path,
                    uint32_t *width, uint32_t *height, char *error, size_t error_size);
#endif
