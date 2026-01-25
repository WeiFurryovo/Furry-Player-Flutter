//! Furry FFI (Windows/Linux) - C ABI wrapper for Flutter/Dart FFI.

use std::ffi::{CStr, CString};
use std::fs::File;
use std::io::Read;
use std::os::raw::{c_char, c_int, c_uchar};
use std::path::PathBuf;

use furry_converter::{detect_format, pack_to_furry, unpack_from_furry, PackOptions};
use furry_crypto::MasterKey;
use furry_format::{FurryReader, MetaKind};

fn cstr_to_path(ptr: *const c_char) -> Result<PathBuf, c_int> {
    if ptr.is_null() {
        return Err(-1);
    }
    let s = unsafe { CStr::from_ptr(ptr) }.to_string_lossy().to_string();
    if s.is_empty() {
        return Err(-2);
    }
    Ok(PathBuf::from(s))
}

#[no_mangle]
pub extern "C" fn furry_pack_to_furry(
    input_path: *const c_char,
    output_path: *const c_char,
    padding_kb: u64,
) -> c_int {
    let input_path = match cstr_to_path(input_path) {
        Ok(p) => p,
        Err(e) => return e,
    };
    let output_path = match cstr_to_path(output_path) {
        Ok(p) => p,
        Err(e) => return e,
    };

    let mut input = match File::open(&input_path) {
        Ok(f) => f,
        Err(_) => return -3,
    };
    let mut output = match File::create(&output_path) {
        Ok(f) => f,
        Err(_) => return -4,
    };

    let format = detect_format(&input_path);
    let master_key = MasterKey::default_key();
    let options = PackOptions {
        padding_bytes: padding_kb * 1024,
        ..Default::default()
    };

    match pack_to_furry(
        &mut input,
        &mut output,
        Some(&input_path),
        format,
        &master_key,
        &options,
    ) {
        Ok(_) => 0,
        Err(_) => -5,
    }
}

#[no_mangle]
pub extern "C" fn furry_is_valid_furry_file(file_path: *const c_char) -> bool {
    let path = match cstr_to_path(file_path) {
        Ok(p) => p,
        Err(_) => return false,
    };

    let file = match File::open(&path) {
        Ok(f) => f,
        Err(_) => return false,
    };

    let mut reader = std::io::BufReader::new(file);
    let mut magic = [0u8; 8];
    if reader.read_exact(&mut magic).is_err() {
        return false;
    }
    &magic == b"FURRYFMT"
}

fn original_ext(path: &PathBuf, master_key: &MasterKey) -> Result<&'static str, ()> {
    let file = File::open(path).map_err(|_| ())?;
    let reader = FurryReader::open(file, master_key).map_err(|_| ())?;
    Ok(match reader.index.header.original_format {
        furry_format::OriginalFormat::Mp3 => "mp3",
        furry_format::OriginalFormat::Wav => "wav",
        furry_format::OriginalFormat::Ogg => "ogg",
        furry_format::OriginalFormat::Flac => "flac",
        furry_format::OriginalFormat::Unknown => "",
    })
}

/// Writes original format extension (without dot) into `out_buf` (NUL-terminated).
/// Returns 0 on success, negative on failure.
///
/// # Safety
/// - `file_path` must be a valid NUL-terminated C string pointer (or NULL).
/// - `out_buf` must point to at least `out_len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn furry_get_original_format(
    file_path: *const c_char,
    out_buf: *mut c_char,
    out_len: usize,
) -> c_int {
    if out_buf.is_null() || out_len == 0 {
        return -10;
    }

    let path = match cstr_to_path(file_path) {
        Ok(p) => p,
        Err(e) => return e,
    };

    let master_key = MasterKey::default_key();
    let ext = match original_ext(&path, &master_key) {
        Ok(v) => v,
        Err(_) => return -11,
    };

    let s = match CString::new(ext) {
        Ok(v) => v,
        Err(_) => return -12,
    };
    let bytes = s.as_bytes_with_nul();
    if bytes.len() > out_len {
        return -13;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, out_buf, bytes.len());
    }
    0
}

/// Decrypts `.furry` to in-memory bytes.
/// On success returns 0 and sets `*out_ptr`/`*out_len`. Caller must call `furry_free_bytes`.
///
/// # Safety
/// - `input_path` must be a valid NUL-terminated C string pointer (or NULL).
/// - `out_ptr` and `out_len` must be valid writable pointers.
#[no_mangle]
pub unsafe extern "C" fn furry_unpack_from_furry_to_bytes(
    input_path: *const c_char,
    out_ptr: *mut *mut c_uchar,
    out_len: *mut usize,
) -> c_int {
    if out_ptr.is_null() || out_len.is_null() {
        return -20;
    }

    let input_path = match cstr_to_path(input_path) {
        Ok(p) => p,
        Err(e) => return e,
    };

    let mut input = match File::open(&input_path) {
        Ok(f) => f,
        Err(_) => return -21,
    };

    let master_key = MasterKey::default_key();
    let mut output: Vec<u8> = Vec::new();
    if unpack_from_furry(&mut input, &mut output, &master_key).is_err() {
        return -22;
    }

    let len = output.len();
    let ptr = output.as_mut_ptr();
    std::mem::forget(output);

    unsafe {
        *out_ptr = ptr;
        *out_len = len;
    }
    0
}

/// Returns embedded tags JSON (UTF-8) from `.furry` META chunk.
/// On success returns 0 and sets `*out_ptr`/`*out_len`. Caller must call `furry_free_bytes`.
///
/// # Safety
/// - `input_path` must be a valid NUL-terminated C string pointer (or NULL).
/// - `out_ptr` and `out_len` must be valid writable pointers.
#[no_mangle]
pub unsafe extern "C" fn furry_get_tags_json_to_bytes(
    input_path: *const c_char,
    out_ptr: *mut *mut c_uchar,
    out_len: *mut usize,
) -> c_int {
    if out_ptr.is_null() || out_len.is_null() {
        return -30;
    }

    let input_path = match cstr_to_path(input_path) {
        Ok(p) => p,
        Err(e) => return e,
    };

    let file = match File::open(&input_path) {
        Ok(f) => f,
        Err(_) => return -31,
    };

    let master_key = MasterKey::default_key();
    let mut reader = match FurryReader::open(file, &master_key) {
        Ok(r) => r,
        Err(_) => return -32,
    };

    let bytes = match reader.read_latest_meta(MetaKind::Tags) {
        Ok(Some(b)) => b,
        Ok(None) => Vec::new(),
        Err(_) => return -33,
    };

    let len = bytes.len();
    let mut bytes = bytes;
    let ptr = bytes.as_mut_ptr();
    std::mem::forget(bytes);

    unsafe {
        *out_ptr = ptr;
        *out_len = len;
    }
    0
}

/// Returns embedded cover art payload bytes from `.furry` META chunk.
/// Payload format: `mime\\0<image-bytes>`.
/// On success returns 0 and sets `*out_ptr`/`*out_len`. Caller must call `furry_free_bytes`.
///
/// # Safety
/// - `input_path` must be a valid NUL-terminated C string pointer (or NULL).
/// - `out_ptr` and `out_len` must be valid writable pointers.
#[no_mangle]
pub unsafe extern "C" fn furry_get_cover_art_to_bytes(
    input_path: *const c_char,
    out_ptr: *mut *mut c_uchar,
    out_len: *mut usize,
) -> c_int {
    if out_ptr.is_null() || out_len.is_null() {
        return -40;
    }

    let input_path = match cstr_to_path(input_path) {
        Ok(p) => p,
        Err(e) => return e,
    };

    let file = match File::open(&input_path) {
        Ok(f) => f,
        Err(_) => return -41,
    };

    let master_key = MasterKey::default_key();
    let mut reader = match FurryReader::open(file, &master_key) {
        Ok(r) => r,
        Err(_) => return -42,
    };

    let bytes = match reader.read_latest_meta(MetaKind::CoverArt) {
        Ok(Some(b)) => b,
        Ok(None) => Vec::new(),
        Err(_) => return -43,
    };

    let len = bytes.len();
    let mut bytes = bytes;
    let ptr = bytes.as_mut_ptr();
    std::mem::forget(bytes);

    unsafe {
        *out_ptr = ptr;
        *out_len = len;
    }
    0
}

/// Frees bytes allocated by `furry_unpack_from_furry_to_bytes`.
///
/// # Safety
/// - `ptr`/`len` must come from this library (via `*_to_bytes` functions), and be freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn furry_free_bytes(ptr: *mut c_uchar, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    unsafe {
        drop(Vec::from_raw_parts(ptr, len, len));
    }
}
