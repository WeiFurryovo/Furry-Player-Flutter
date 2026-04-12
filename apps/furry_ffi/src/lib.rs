//! Furry FFI (Windows/Linux) - C ABI wrapper for Flutter/Dart FFI.

use std::ffi::{CStr, CString};
use std::fs::File;
use std::os::raw::{c_char, c_int, c_uchar};
use std::path::{Path, PathBuf};
use std::sync::{Once, OnceLock};

use furry_converter::{
    detect_format, pack_to_furry, padding_bytes_from_kib, unpack_from_furry, PackOptions,
};
use furry_crypto::{LoadedMasterKey, MasterKey, MASTER_KEY_ENV_VAR};
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

fn log_master_key_error_once(message: &str) {
    static ERROR_ONCE: Once = Once::new();
    ERROR_ONCE.call_once(|| {
        eprintln!("Master key configuration error: {}", message);
    });
}

fn warn_default_master_key_once() {
    static WARN_ONCE: Once = Once::new();
    WARN_ONCE.call_once(|| {
        eprintln!(
            "Warning: {} is not set, using the built-in development master key.",
            MASTER_KEY_ENV_VAR
        );
    });
}

fn load_master_key() -> Result<MasterKey, c_int> {
    static MASTER_KEY: OnceLock<Result<LoadedMasterKey, String>> = OnceLock::new();

    let loaded = MASTER_KEY.get_or_init(|| {
        MasterKey::load_runtime_from_env_policy().map_err(|error| error.to_string())
    });
    match loaded {
        Ok(loaded) => {
            if loaded.uses_default_fallback() {
                warn_default_master_key_once();
            }
            Ok(loaded.clone_key())
        }
        Err(error) => {
            log_master_key_error_once(error);
            Err(-90)
        }
    }
}

fn is_valid_furry_path(path: &Path) -> Result<bool, c_int> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(_) => return Ok(false),
    };

    let master_key = load_master_key()?;
    Ok(FurryReader::open(file, &master_key).is_ok())
}

fn padding_bytes_for_ffi(padding_kb: u64) -> Result<u64, c_int> {
    padding_bytes_from_kib(padding_kb).map_err(|_| -6)
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
    let master_key = match load_master_key() {
        Ok(master_key) => master_key,
        Err(error_code) => return error_code,
    };
    let padding_bytes = match padding_bytes_for_ffi(padding_kb) {
        Ok(bytes) => bytes,
        Err(error_code) => return error_code,
    };
    let options = PackOptions {
        padding_bytes,
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

    matches!(is_valid_furry_path(&path), Ok(true))
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

    let master_key = match load_master_key() {
        Ok(master_key) => master_key,
        Err(error_code) => return error_code,
    };
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

    let master_key = match load_master_key() {
        Ok(master_key) => master_key,
        Err(error_code) => return error_code,
    };
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

/// Decrypts `.furry` and writes decrypted bytes into `output_path`.
/// Returns 0 on success.
///
/// # Safety
/// - `input_path` and `output_path` must be valid NUL-terminated C string pointers (or NULL).
#[no_mangle]
pub unsafe extern "C" fn furry_unpack_from_furry_to_file(
    input_path: *const c_char,
    output_path: *const c_char,
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
        Err(_) => return -23,
    };

    if let Some(parent) = output_path.parent() {
        if std::fs::create_dir_all(parent).is_err() {
            return -24;
        }
    }

    let mut output = match File::create(&output_path) {
        Ok(f) => f,
        Err(_) => return -25,
    };

    let master_key = match load_master_key() {
        Ok(master_key) => master_key,
        Err(error_code) => return error_code,
    };
    match unpack_from_furry(&mut input, &mut output, &master_key) {
        Ok(_) => 0,
        Err(_) => -26,
    }
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

    let master_key = match load_master_key() {
        Ok(master_key) => master_key,
        Err(error_code) => return error_code,
    };
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

    let master_key = match load_master_key() {
        Ok(master_key) => master_key,
        Err(error_code) => return error_code,
    };
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn unique_temp_path(prefix: &str, ext: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        std::env::temp_dir().join(format!("{prefix}_{}_{}.{}", std::process::id(), nanos, ext))
    }

    #[test]
    fn detects_valid_furry_file_by_full_parse() {
        let input_path = unique_temp_path("furry_valid_input", "mp3");
        let output_path = unique_temp_path("furry_valid_output", "furry");

        std::fs::write(&input_path, b"fake audio payload").unwrap();

        let master_key = MasterKey::default_key();
        let mut input = File::open(&input_path).unwrap();
        let mut output = File::create(&output_path).unwrap();

        pack_to_furry(
            &mut input,
            &mut output,
            Some(&input_path),
            detect_format(&input_path),
            &master_key,
            &PackOptions::default(),
        )
        .unwrap();

        assert!(matches!(is_valid_furry_path(&output_path), Ok(true)));

        let _ = std::fs::remove_file(input_path);
        let _ = std::fs::remove_file(output_path);
    }

    #[test]
    fn rejects_magic_only_truncated_file() {
        let path = unique_temp_path("furry_invalid_magic_only", "furry");
        let mut file = File::create(&path).unwrap();
        file.write_all(b"FURRYFMT").unwrap();
        file.flush().unwrap();

        assert!(matches!(is_valid_furry_path(&path), Ok(false)));

        let _ = std::fs::remove_file(path);
    }
}
