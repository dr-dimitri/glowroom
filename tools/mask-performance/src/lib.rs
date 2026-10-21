//! Optional measurement prototype. This library is never linked or bundled into
//! Glowroom. The caller owns both buffers for the entire synchronous invocation.
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Gray8, tightly bounded bilinear sampling at pixel centers, using the same
/// Double operation order as Swift. Source/destination must not overlap. Strides
/// are in bytes; lengths include padding. One bounded column-table allocation;
/// no full image copy and no retained pointers.
/// Returns 0 success, 1 invalid shape/pointer/length, 2 cancelled, 3 caught panic.
/// The callback must not unwind across C; it may return nonzero to cancel. A
/// cancelled or failed destination is partial and must never be published.
///
/// # Safety
/// Non-null pointers must reference readable/writable memory of the advertised
/// length. Caller owns lifetime and exclusive destination access. Immutable input
/// may be shared across independent invocations; this kernel has no global state.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowroom_mask_resample_v1(
    source: *const u8,
    source_len: usize,
    width: usize,
    height: usize,
    source_stride: usize,
    destination: *mut u8,
    destination_len: usize,
    output_width: usize,
    output_height: usize,
    destination_stride: usize,
    cancelled: Option<extern "C" fn(*mut std::ffi::c_void) -> i32>,
    context: *mut std::ffi::c_void,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if source.is_null() || destination.is_null()
            || source_len > isize::MAX as usize || destination_len > isize::MAX as usize
            || width == 0 || height == 0 || output_width == 0 || output_height == 0
            || width > 16_384 || height > 16_384 || output_width > 16_384 || output_height > 16_384
            || width.checked_mul(height).is_none_or(|n| n > 16_777_216)
            || output_width.checked_mul(output_height).is_none_or(|n| n > 16_777_216)
            || source_stride < width || destination_stride < output_width
            || source_stride.checked_mul(height).is_none_or(|n| n > source_len)
            || destination_stride.checked_mul(output_height).is_none_or(|n| n > destination_len)
        { return 1; }
        // Verify nonoverlap before constructing Rust references. Pointer-range
        // arithmetic is checked, without dereferencing invalid foreign pointers.
        let Some(source_end) = (source as usize).checked_add(source_len) else { return 1; };
        let Some(destination_end) = (destination as usize).checked_add(destination_len) else { return 1; };
        if (source as usize) < destination_end && (destination as usize) < source_end { return 1; }
        let src = unsafe { std::slice::from_raw_parts(source, source_len) };
        let dst = unsafe { std::slice::from_raw_parts_mut(destination, destination_len) };
        let scale_x = width as f64 / output_width as f64;
        let scale_y = height as f64 / output_height as f64;
        // The same precomputation is used in optimized Swift; do not compare a
        // different algorithm to attribute the entire difference to language.
        let columns: Vec<_> = (0..output_width).map(|x| {
            let sx = ((x as f64 + 0.5) * scale_x - 0.5).clamp(0.0, (width - 1) as f64);
            let x0 = sx.floor() as usize;
            (x0, (x0 + 1).min(width - 1), sx - x0 as f64)
        }).collect();
        for y in 0..output_height {
            if y % 16 == 0 && cancelled.is_some_and(|check| check(context) != 0) { return 2; }
            let sy = ((y as f64 + 0.5) * scale_y - 0.5).clamp(0.0, (height - 1) as f64);
            let y0 = sy.floor() as usize;
            let y1 = (y0 + 1).min(height - 1);
            let fy = sy - y0 as f64;
            for (x, &(x0, x1, fx)) in columns.iter().enumerate() {
                let top = src[y0 * source_stride + x0] as f64 * (1.0 - fx)
                    + src[y0 * source_stride + x1] as f64 * fx;
                let bottom = src[y1 * source_stride + x0] as f64 * (1.0 - fx)
                    + src[y1 * source_stride + x1] as f64 * fx;
                dst[y * destination_stride + x] = (top * (1.0 - fy) + bottom * fy).round() as u8;
            }
        }
        if cancelled.is_some_and(|check| check(context) != 0) { return 2; }
        0
    })).unwrap_or(3)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn center_sampling_and_padded_strides() {
        let input = [0, 64, 99, 128, 255, 99];
        let mut output = [0, 77, 0, 77];
        let result = unsafe { glowroom_mask_resample_v1(input.as_ptr(), input.len(), 2, 2, 3,
            output.as_mut_ptr(), output.len(), 1, 2, 2, None, std::ptr::null_mut()) };
        assert_eq!(result, 0);
        assert_eq!(output, [32, 77, 192, 77]);
    }

    extern "C" fn cancel(_: *mut std::ffi::c_void) -> i32 { 1 }
    #[test]
    fn invalid_shapes_and_cancellation_return_codes() {
        let input = [0, 1, 2, 3];
        let mut output = [91; 4];
        let call = |width, cancelled, output: &mut [u8]| unsafe {
            glowroom_mask_resample_v1(input.as_ptr(), input.len(), width, 2, 2,
                output.as_mut_ptr(), output.len(), 2, 2, 2, cancelled, std::ptr::null_mut())
        };
        assert_eq!(call(3, None, &mut output), 1);
        assert_eq!(call(2, Some(cancel as extern "C" fn(_) -> _), &mut output), 2);
        assert_eq!(output, [91; 4]);
    }

    #[test]
    fn rejects_null_overlap_overflow_and_short_buffers() {
        let input = [0, 1, 2, 3];
        let mut output = [91; 4];
        let call = |src, src_len, width, height, output: &mut [u8]| unsafe {
            glowroom_mask_resample_v1(src, src_len, width, height, width,
                output.as_mut_ptr(), output.len(), 2, 2, 2, None, std::ptr::null_mut())
        };
        assert_eq!(call(std::ptr::null(), 4, 2, 2, &mut output), 1);
        assert_eq!(call(input.as_ptr(), 3, 2, 2, &mut output), 1);
        assert_eq!(call(input.as_ptr(), usize::MAX, 2, 2, &mut output), 1);
        assert_eq!(call(input.as_ptr(), 4, 16_384, 16_384, &mut output), 1);
        assert_eq!(call(output.as_ptr(), 4, 2, 2, &mut output), 1);
        assert_eq!(output, [91; 4]);
    }

    extern "C" fn cancel_second(context: *mut std::ffi::c_void) -> i32 {
        let counter = unsafe { &*(context as *const std::sync::atomic::AtomicUsize) };
        i32::from(counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst) != 0)
    }
    #[test]
    fn cancellation_after_partial_rows_does_not_write_remaining_rows() {
        let input = [19; 32 * 32];
        let mut output = [91; 32 * 32];
        let checks = std::sync::atomic::AtomicUsize::new(0);
        let result = unsafe { glowroom_mask_resample_v1(input.as_ptr(), input.len(), 32, 32, 32,
            output.as_mut_ptr(), output.len(), 32, 32, 32, Some(cancel_second),
            &checks as *const _ as *mut std::ffi::c_void) };
        assert_eq!(result, 2);
        assert!(output[..16 * 32].iter().all(|&byte| byte == 19));
        assert!(output[16 * 32..].iter().all(|&byte| byte == 91));
    }
}
