#include "PixelCore.h"
#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    FILE *input, *output;
    png_structp png;
    png_infop info;
    unsigned char *row;
    char *error;
    size_t error_size;
    int success;
} Decode;

static void decode_error(png_structp png, png_const_charp message) {
    Decode *state = png_get_error_ptr(png);
    if (state->error && state->error_size) snprintf(state->error, state->error_size, "%s", message);
    png_longjmp(png, 1);
}
static void decode_warning(png_structp png, png_const_charp message) { (void)png; (void)message; }

int evb_png_to_rgba(const char *input, const char *output, uint32_t *width, uint32_t *height, char *error, size_t error_size) {
    Decode *s = calloc(1, sizeof(*s));
    if (!s) return -1;
    s->error = error; s->error_size = error_size;
    s->input = fopen(input, "rb");
    if (!s->input) { snprintf(error,error_size,"Cannot read the original PNG"); goto cleanup; }
    s->png = png_create_read_struct(PNG_LIBPNG_VER_STRING, s, decode_error, decode_warning);
    if (!s->png) goto cleanup;
    s->info = png_create_info_struct(s->png);
    if (!s->info) goto cleanup;
    if (setjmp(png_jmpbuf(s->png))) goto cleanup;
    png_set_user_limits(s->png, PNG_UINT_31_MAX, PNG_UINT_31_MAX);
    png_init_io(s->png, s->input); png_read_info(s->png, s->info);
    png_uint_32 w = png_get_image_width(s->png,s->info), h = png_get_image_height(s->png,s->info);
    int depth = png_get_bit_depth(s->png,s->info), color = png_get_color_type(s->png,s->info);
    if (depth > 8) png_error(s->png,"The editor currently supports 8-bit captures. The original image was not changed.");
    if (color == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(s->png);
    if (color == PNG_COLOR_TYPE_GRAY && depth < 8) png_set_expand_gray_1_2_4_to_8(s->png);
    int transparent = png_get_valid(s->png,s->info,PNG_INFO_tRNS);
    if (transparent) png_set_tRNS_to_alpha(s->png);
    if (color == PNG_COLOR_TYPE_GRAY || color == PNG_COLOR_TYPE_GRAY_ALPHA) png_set_gray_to_rgb(s->png);
    if (!(color & PNG_COLOR_MASK_ALPHA) && !transparent) png_set_add_alpha(s->png,255,PNG_FILLER_AFTER);
    int passes = png_set_interlace_handling(s->png);
    png_read_update_info(s->png,s->info);
    size_t row_size = png_get_rowbytes(s->png,s->info);
    if (row_size != (size_t)w * 4) png_error(s->png,"Unexpected PNG pixel layout");
    s->row = malloc(row_size);
    if (!s->row) png_error(s->png,"Not enough memory for one image row");
    s->output = fopen(output,"wb+x");
    if (!s->output) png_error(s->png,"Cannot create the editor pixel spool");
    for (int pass = 0; pass < passes; pass++) {
        for (png_uint_32 y = 0; y < h; y++) {
            if (passes > 1) {
                if (fseeko(s->output,(off_t)y * row_size,SEEK_SET)) png_error(s->png,"Cannot seek the editor spool");
                if (pass > 0 && fread(s->row,1,row_size,s->output) != row_size) png_error(s->png,"Cannot read an interlaced row");
                if (pass == 0) memset(s->row,0,row_size);
            }
            png_read_row(s->png,s->row,NULL);
            if (passes > 1 && fseeko(s->output,(off_t)y * row_size,SEEK_SET)) png_error(s->png,"Cannot seek the editor spool");
            if (fwrite(s->row,1,row_size,s->output) != row_size) png_error(s->png,"Disk write failed while preparing the editor");
        }
    }
    png_read_end(s->png,s->info);
    if (fflush(s->output) || fsync(fileno(s->output))) png_error(s->png,"Cannot finish the editor pixel spool");
    *width = w; *height = h; s->success = 1;
cleanup:
    if (s->png) png_destroy_read_struct(&s->png,s->info ? &s->info : NULL,NULL);
    free(s->row);
    if (s->input) fclose(s->input);
    if (s->output) { if (fclose(s->output)) s->success = 0; if (!s->success) unlink(output); }
    int result = s->success ? 0 : -1;
    free(s); return result;
}
