//! C-ABI exports for cross-platform shared computation engine (Rust Core FFI).

use std::slice;

/// Echoes an input byte array back. Returns length of output buffer, or -1 on error.
/// The caller receives an allocated buffer via `out_ptr` and MUST call `xbridge_ffi_free` to free it.
///
/// # Safety
/// - `in_ptr` must be valid for reading `in_len` bytes.
/// - `out_ptr` and `out_len` must be non-null valid pointers.
#[no_mangle]
pub unsafe extern "C" fn xbridge_ffi_echo(
    in_ptr: *const u8,
    in_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if in_ptr.is_null() || out_ptr.is_null() || out_len.is_null() {
        return -1;
    }

    // For zero-length input, don't allocate — return a null pointer so the
    // caller's xbridge_ffi_free call is a no-op (null check). An empty Vec
    // would yield a dangling but non-null pointer that could be mis-freed.
    if in_len == 0 {
        *out_ptr = std::ptr::null_mut();
        *out_len = 0;
        return 0;
    }

    let input = slice::from_raw_parts(in_ptr, in_len);
    // Use `into_boxed_slice()` which guarantees cap == len, so
    // `Box::from_raw` in `xbridge_ffi_free` can safely reclaim the allocation.
    let boxed = input.to_vec().into_boxed_slice();

    let len = boxed.len();
    let ptr = Box::into_raw(boxed) as *mut u8;

    *out_ptr = ptr;
    *out_len = len;
    0
}

/// Frees a buffer allocated by Rust FFI.
///
/// # Safety
/// - `ptr` must have been allocated by `xbridge_ffi_echo` with length `len`.
/// - Calling with a null `ptr` is a safe no-op.
#[no_mangle]
pub unsafe extern "C" fn xbridge_ffi_free(ptr: *mut u8, len: usize) {
    // Null pointer: nothing to free (zero-length echoes return null).
    if ptr.is_null() {
        return;
    }
    // Reclaim the allocation via `Box::from_raw`. This is safe because
    // `xbridge_ffi_echo` used `into_boxed_slice()` which guarantees
    // cap == len, so the slice header captures the full allocation.
    let slice_ptr = std::ptr::slice_from_raw_parts_mut(ptr, len);
    let _ = Box::from_raw(slice_ptr);
}

/// Returns a fixed status integer for FFI health check (e.g. 200).
#[no_mangle]
pub extern "C" fn xbridge_ffi_ping() -> i32 {
    200
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ffi_echo() {
        let data = b"hello xbridge ffi";
        let mut out_ptr: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;

        unsafe {
            let res = xbridge_ffi_echo(data.as_ptr(), data.len(), &mut out_ptr, &mut out_len);
            assert_eq!(res, 0);
            assert_eq!(out_len, data.len());

            let echo = slice::from_raw_parts(out_ptr, out_len);
            assert_eq!(echo, data);

            xbridge_ffi_free(out_ptr, out_len);
        }
    }

    #[test]
    fn test_ffi_ping() {
        assert_eq!(xbridge_ffi_ping(), 200);
    }

    #[test]
    fn test_ffi_echo_empty() {
        let data: [u8; 0] = [];
        let mut out_ptr: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;

        unsafe {
            let res = xbridge_ffi_echo(data.as_ptr(), data.len(), &mut out_ptr, &mut out_len);
            assert_eq!(res, 0);
            assert_eq!(out_len, 0);
            assert!(out_ptr.is_null());

            // Freeing a null pointer must be a safe no-op.
            xbridge_ffi_free(out_ptr, out_len);
        }
    }
}
