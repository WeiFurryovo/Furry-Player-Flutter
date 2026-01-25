//! Furry Android JNI 绑定
//!
//! 提供 Android 应用调用的 JNI 接口

use std::fs::File;
use std::path::PathBuf;

use jni::objects::{JClass, JString};
use jni::sys::{jboolean, jbyteArray, jint, jlong, jstring, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;

use furry_converter::{detect_format, pack_to_furry, unpack_from_furry, PackOptions};
use furry_crypto::MasterKey;
use furry_format::{FurryReader, MetaKind};

/// 初始化日志（Android）
#[cfg(target_os = "android")]
fn init_logging() {
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Debug)
            .with_tag("FurryPlayer"),
    );
}

#[cfg(not(target_os = "android"))]
fn init_logging() {}

/// JNI: 初始化库
#[no_mangle]
pub extern "system" fn Java_com_furry_player_NativeLib_init(_env: JNIEnv, _class: JClass) {
    init_logging();
}

/// JNI: 初始化库（Flutter 模板包名：com.furry.furry_flutter_app.NativeLib）
#[no_mangle]
pub extern "system" fn Java_com_furry_furry_1flutter_1app_NativeLib_init(
    _env: JNIEnv,
    _class: JClass,
) {
    init_logging();
}

/// JNI: 打包音频文件到 .furry 格式
///
/// @param inputPath 输入文件路径
/// @param outputPath 输出文件路径
/// @param paddingKb 填充大小（KB）
/// @return 0 成功，负数失败
#[no_mangle]
pub extern "system" fn Java_com_furry_player_NativeLib_packToFurry<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    input_path: JString<'local>,
    output_path: JString<'local>,
    padding_kb: jlong,
) -> jint {
    pack_to_furry_impl(&mut env, input_path, output_path, padding_kb)
}

/// JNI: 打包（Flutter 模板包名：com.furry.furry_flutter_app.NativeLib）
#[no_mangle]
pub extern "system" fn Java_com_furry_furry_1flutter_1app_NativeLib_packToFurry<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    input_path: JString<'local>,
    output_path: JString<'local>,
    padding_kb: jlong,
) -> jint {
    pack_to_furry_impl(&mut env, input_path, output_path, padding_kb)
}

fn pack_to_furry_impl(
    env: &mut JNIEnv<'_>,
    input_path: JString<'_>,
    output_path: JString<'_>,
    padding_kb: jlong,
) -> jint {
    let input_str: String = match env.get_string(&input_path) {
        Ok(s) => s.into(),
        Err(_) => return -1,
    };

    let output_str: String = match env.get_string(&output_path) {
        Ok(s) => s.into(),
        Err(_) => return -2,
    };

    let input_path = PathBuf::from(input_str);
    let output_path = PathBuf::from(output_str);

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
        padding_bytes: (padding_kb as u64) * 1024,
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

/// JNI: 解密 .furry 到内存字节数组（用于播放等，不落地文件）
///
/// @param inputPath 输入 .furry 文件路径
/// @return 解密后的原始音频字节数组；失败返回 null
#[no_mangle]
pub extern "system" fn Java_com_furry_player_NativeLib_unpackFromFurryToBytes<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    input_path: JString<'local>,
) -> jbyteArray {
    unpack_from_furry_to_bytes_impl(&mut env, input_path)
}

/// JNI: 解密 .furry 到内存（Flutter 模板包名：com.furry.furry_flutter_app.NativeLib）
#[no_mangle]
pub extern "system" fn Java_com_furry_furry_1flutter_1app_NativeLib_unpackFromFurryToBytes<
    'local,
>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    input_path: JString<'local>,
) -> jbyteArray {
    unpack_from_furry_to_bytes_impl(&mut env, input_path)
}

/// JNI: 解密 `.furry` 到文件
///
/// @param inputPath 输入 .furry 文件路径
/// @param outputPath 输出原始音频文件路径
/// @return 0 成功，负数失败
#[no_mangle]
pub extern "system" fn Java_com_furry_player_NativeLib_unpackToFile<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    input_path: JString<'local>,
    output_path: JString<'local>,
) -> jint {
    unpack_to_file_impl(&mut env, input_path, output_path)
}

/// JNI: 解密 `.furry` 到文件（Flutter 模板包名：com.furry.furry_flutter_app.NativeLib）
#[no_mangle]
pub extern "system" fn Java_com_furry_furry_1flutter_1app_NativeLib_unpackToFile<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    input_path: JString<'local>,
    output_path: JString<'local>,
) -> jint {
    unpack_to_file_impl(&mut env, input_path, output_path)
}

fn unpack_to_file_impl(
    env: &mut JNIEnv<'_>,
    input_path: JString<'_>,
    output_path: JString<'_>,
) -> jint {
    let input_str: String = match env.get_string(&input_path) {
        Ok(s) => s.into(),
        Err(_) => return -60,
    };
    let output_str: String = match env.get_string(&output_path) {
        Ok(s) => s.into(),
        Err(_) => return -61,
    };

    let input_path = PathBuf::from(input_str);
    let output_path = PathBuf::from(output_str);

    let mut input = match File::open(&input_path) {
        Ok(f) => f,
        Err(_) => return -62,
    };

    if let Some(parent) = output_path.parent() {
        if std::fs::create_dir_all(parent).is_err() {
            return -63;
        }
    }

    let mut output = match File::create(&output_path) {
        Ok(f) => f,
        Err(_) => return -64,
    };

    let master_key = MasterKey::default_key();
    match unpack_from_furry(&mut input, &mut output, &master_key) {
        Ok(_) => 0,
        Err(_) => -65,
    }
}

fn unpack_from_furry_to_bytes_impl(env: &mut JNIEnv<'_>, input_path: JString<'_>) -> jbyteArray {
    let input_str: String = match env.get_string(&input_path) {
        Ok(s) => s.into(),
        Err(_) => return std::ptr::null_mut(),
    };

    let input_path = PathBuf::from(input_str);

    let mut input = match File::open(&input_path) {
        Ok(f) => f,
        Err(_) => return std::ptr::null_mut(),
    };

    let master_key = MasterKey::default_key();
    let mut output: Vec<u8> = Vec::new();

    if unpack_from_furry(&mut input, &mut output, &master_key).is_err() {
        return std::ptr::null_mut();
    }

    let len_i32 = match i32::try_from(output.len()) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };

    let arr = match env.new_byte_array(len_i32) {
        Ok(a) => a,
        Err(_) => return std::ptr::null_mut(),
    };

    // jbyte 在 JNI 中是 i8，这里用零拷贝的方式重解释为 &[i8]
    let output_i8: &[i8] =
        unsafe { std::slice::from_raw_parts(output.as_ptr() as *const i8, output.len()) };
    if env.set_byte_array_region(&arr, 0, output_i8).is_err() {
        return std::ptr::null_mut();
    }

    arr.into_raw()
}

/// JNI: 检查文件是否为有效的 .furry 格式
#[no_mangle]
pub extern "system" fn Java_com_furry_player_NativeLib_isValidFurryFile<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    file_path: JString<'local>,
) -> jboolean {
    is_valid_furry_file_impl(&mut env, file_path)
}

/// JNI: 检查文件是否为有效的 .furry（Flutter 模板包名：com.furry.furry_flutter_app.NativeLib）
#[no_mangle]
pub extern "system" fn Java_com_furry_furry_1flutter_1app_NativeLib_isValidFurryFile<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    file_path: JString<'local>,
) -> jboolean {
    is_valid_furry_file_impl(&mut env, file_path)
}

fn is_valid_furry_file_impl(env: &mut JNIEnv<'_>, file_path: JString<'_>) -> jboolean {
    let path_str: String = match env.get_string(&file_path) {
        Ok(s) => s.into(),
        Err(_) => return JNI_FALSE,
    };

    let path = PathBuf::from(path_str);

    let file = match File::open(&path) {
        Ok(f) => f,
        Err(_) => return JNI_FALSE,
    };

    use std::io::Read;
    let mut reader = std::io::BufReader::new(file);
    let mut magic = [0u8; 8];

    if reader.read_exact(&mut magic).is_err() {
        return JNI_FALSE;
    }

    if &magic == b"FURRYFMT" {
        JNI_TRUE
    } else {
        JNI_FALSE
    }
}

/// JNI: 获取 .furry 的原始格式扩展名（不带点）
#[no_mangle]
pub extern "system" fn Java_com_furry_player_NativeLib_getOriginalFormat<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    file_path: JString<'local>,
) -> jstring {
    get_original_format_impl(&mut env, file_path)
}

/// JNI: 获取原始格式（Flutter 模板包名：com.furry.furry_flutter_app.NativeLib）
#[no_mangle]
pub extern "system" fn Java_com_furry_furry_1flutter_1app_NativeLib_getOriginalFormat<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    file_path: JString<'local>,
) -> jstring {
    get_original_format_impl(&mut env, file_path)
}

fn get_original_format_impl(env: &mut JNIEnv<'_>, file_path: JString<'_>) -> jstring {
    fn to_jstring(env: &mut JNIEnv<'_>, s: &str) -> jstring {
        match env.new_string(s) {
            Ok(v) => v.into_raw(),
            Err(_) => std::ptr::null_mut(),
        }
    }

    let path_str: String = match env.get_string(&file_path) {
        Ok(s) => s.into(),
        Err(_) => return to_jstring(env, ""),
    };

    let path = PathBuf::from(path_str);
    let file = match File::open(&path) {
        Ok(f) => f,
        Err(_) => return to_jstring(env, ""),
    };

    let master_key = MasterKey::default_key();
    let reader = match FurryReader::open(file, &master_key) {
        Ok(r) => r,
        Err(_) => return to_jstring(env, ""),
    };

    let ext = match reader.index.header.original_format {
        furry_format::OriginalFormat::Mp3 => "mp3",
        furry_format::OriginalFormat::Wav => "wav",
        furry_format::OriginalFormat::Ogg => "ogg",
        furry_format::OriginalFormat::Flac => "flac",
        furry_format::OriginalFormat::Unknown => "",
    };

    to_jstring(env, ext)
}

/// JNI: 获取 tags JSON（com.furry_player.NativeLib）
#[no_mangle]
pub extern "system" fn Java_com_furry_player_NativeLib_getTagsJson<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    file_path: JString<'local>,
) -> jstring {
    get_tags_json_impl(&mut env, file_path)
}

/// JNI: 获取 tags JSON（com.furry.furry_flutter_app.NativeLib）
#[no_mangle]
pub extern "system" fn Java_com_furry_furry_1flutter_1app_NativeLib_getTagsJson<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    file_path: JString<'local>,
) -> jstring {
    get_tags_json_impl(&mut env, file_path)
}

fn get_tags_json_impl(env: &mut JNIEnv<'_>, file_path: JString<'_>) -> jstring {
    fn to_jstring(env: &mut JNIEnv<'_>, s: &str) -> jstring {
        match env.new_string(s) {
            Ok(v) => v.into_raw(),
            Err(_) => std::ptr::null_mut(),
        }
    }

    let path_str: String = match env.get_string(&file_path) {
        Ok(s) => s.into(),
        Err(_) => return to_jstring(env, ""),
    };
    let path = PathBuf::from(path_str);

    let file = match File::open(&path) {
        Ok(f) => f,
        Err(_) => return to_jstring(env, ""),
    };

    let master_key = MasterKey::default_key();
    let mut reader = match FurryReader::open(file, &master_key) {
        Ok(r) => r,
        Err(_) => return to_jstring(env, ""),
    };

    let bytes = match reader.read_latest_meta(MetaKind::Tags) {
        Ok(Some(b)) => b,
        _ => Vec::new(),
    };

    let s = String::from_utf8(bytes).unwrap_or_default();

    to_jstring(env, &s)
}

/// JNI: 获取封面字节（payload: mime\\0<bytes>）(com.furry_player.NativeLib)
#[no_mangle]
pub extern "system" fn Java_com_furry_player_NativeLib_getCoverArt<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    file_path: JString<'local>,
) -> jbyteArray {
    get_cover_art_impl(&mut env, file_path)
}

/// JNI: 获取封面字节（payload: mime\\0<bytes>）(com.furry.furry_flutter_app.NativeLib)
#[no_mangle]
pub extern "system" fn Java_com_furry_furry_1flutter_1app_NativeLib_getCoverArt<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    file_path: JString<'local>,
) -> jbyteArray {
    get_cover_art_impl(&mut env, file_path)
}

fn get_cover_art_impl(env: &mut JNIEnv<'_>, file_path: JString<'_>) -> jbyteArray {
    let path_str: String = match env.get_string(&file_path) {
        Ok(s) => s.into(),
        Err(_) => return std::ptr::null_mut(),
    };
    let path = PathBuf::from(path_str);

    let file = match File::open(&path) {
        Ok(f) => f,
        Err(_) => return std::ptr::null_mut(),
    };

    let master_key = MasterKey::default_key();
    let mut reader = match FurryReader::open(file, &master_key) {
        Ok(r) => r,
        Err(_) => return std::ptr::null_mut(),
    };

    let bytes = match reader.read_latest_meta(MetaKind::CoverArt) {
        Ok(Some(b)) => b,
        _ => Vec::new(),
    };
    if bytes.is_empty() {
        return std::ptr::null_mut();
    }

    let len_i32 = match i32::try_from(bytes.len()) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };
    let arr = match env.new_byte_array(len_i32) {
        Ok(a) => a,
        Err(_) => return std::ptr::null_mut(),
    };
    let bytes_i8: &[i8] =
        unsafe { std::slice::from_raw_parts(bytes.as_ptr() as *const i8, bytes.len()) };
    if env.set_byte_array_region(&arr, 0, bytes_i8).is_err() {
        return std::ptr::null_mut();
    }
    arr.into_raw()
}
