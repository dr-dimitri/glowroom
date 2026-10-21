#ifndef GLOWROOM_MASK_RESAMPLE_H
#define GLOWROOM_MASK_RESAMPLE_H
#include <stddef.h>
#include <stdint.h>
/* Experimental benchmark ABI only; not linked into Glowroom.
 * Gray8, immutable src and exclusively owned dst must remain valid and disjoint
 * for the synchronous call. Width/height >0, <=16384, <=16777216 pixels;
 * strides >= width, lengths >= height*stride. No pointers are retained.
 * cancelled(context) may return nonzero; callback must not throw/unwind.
 * Return 0 success, 1 invalid arguments, 2 cancelled, 3 caught Rust panic.
 * On any failure dst is unpublished partial output. Thread-safe, no global state.
 */
int32_t glowroom_mask_resample_v1(const uint8_t *src, size_t src_len,
    size_t width, size_t height, size_t src_stride,
    uint8_t *dst, size_t dst_len, size_t output_width, size_t output_height,
    size_t dst_stride, int32_t (*cancelled)(void *), void *context);
#endif
