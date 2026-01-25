//! furry_crypto - 加密模块
//!
//! 提供 .furry 格式的加密/解密功能：
//! - AES-256-GCM AEAD 加密
//! - HKDF-SHA256 密钥派生
//! - BLAKE3 XOF 用于 META 混淆

use aes_gcm::aead::generic_array::GenericArray;
use aes_gcm::aead::{AeadInPlace, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroize;

// ============================================================================
// 常量定义
// ============================================================================

pub const FILE_ID_LEN: usize = 16;
pub const SALT_LEN: usize = 16;
pub const AEAD_KEY_LEN: usize = 32;
pub const NONCE_PREFIX_LEN: usize = 4;
pub const NONCE_LEN: usize = 12;
pub const TAG_LEN: usize = 16;
pub const CHUNK_HEADER_LEN: usize = 40;

pub const AAD_PREFIX: [u8; 8] = *b"FURRYAAD";
pub const AAD_LEN: usize = 8 + 2 + 4 + FILE_ID_LEN + CHUNK_HEADER_LEN; // 70 bytes

/// 硬编码主密钥（生产环境应更换）
pub const MASTER_KEY_BYTES: [u8; AEAD_KEY_LEN] = [
    0x46, 0x55, 0x52, 0x52, 0x59, 0x5f, 0x4d, 0x41, // FURRY_MA
    0x53, 0x54, 0x45, 0x52, 0x5f, 0x4b, 0x45, 0x59, // STER_KEY
    0x5f, 0x32, 0x30, 0x32, 0x36, 0x5f, 0x56, 0x31, // _2026_V1
    0x5f, 0x53, 0x45, 0x43, 0x52, 0x45, 0x54, 0x21, // _SECRET!
];

// ============================================================================
// 错误类型
// ============================================================================

#[derive(thiserror::Error, Debug)]
pub enum CryptoError {
    #[error("HKDF expand failed")]
    HkdfExpand,
    #[error("AEAD operation failed (authentication failed or invalid key)")]
    Aead,
    #[error("Random generation failed")]
    Random,
}

// ============================================================================
// 主密钥
// ============================================================================

/// 主密钥封装，提供安全的内存处理
#[derive(Clone)]
pub struct MasterKey([u8; AEAD_KEY_LEN]);

impl MasterKey {
    /// 从字节数组创建主密钥
    pub const fn new(bytes: [u8; AEAD_KEY_LEN]) -> Self {
        Self(bytes)
    }

    /// 使用默认硬编码密钥
    pub const fn default_key() -> Self {
        Self(MASTER_KEY_BYTES)
    }

    /// 获取密钥字节
    pub fn bytes(&self) -> &[u8; AEAD_KEY_LEN] {
        &self.0
    }
}

impl Drop for MasterKey {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

// ============================================================================
// 文件密钥组
// ============================================================================

/// 每文件派生的密钥组
#[derive(Clone)]
pub struct FileKeys {
    /// AES-256-GCM 加密密钥
    pub aead_key: [u8; AEAD_KEY_LEN],
    /// Nonce 前缀（4 字节）
    pub nonce_prefix: [u8; NONCE_PREFIX_LEN],
    /// META 混淆密钥
    pub meta_xor_key: [u8; AEAD_KEY_LEN],
}

impl Drop for FileKeys {
    fn drop(&mut self) {
        self.aead_key.zeroize();
        self.nonce_prefix.zeroize();
        self.meta_xor_key.zeroize();
    }
}

// ============================================================================
// 密钥派生
// ============================================================================

/// 从主密钥和 salt 派生文件密钥组
pub fn derive_file_keys(
    master_key: &MasterKey,
    salt: &[u8; SALT_LEN],
) -> Result<FileKeys, CryptoError> {
    let hk = Hkdf::<Sha256>::new(Some(salt), master_key.bytes());

    let mut aead_key = [0u8; AEAD_KEY_LEN];
    hk.expand(b"furry/v1/aead_key", &mut aead_key)
        .map_err(|_| CryptoError::HkdfExpand)?;

    let mut nonce_prefix = [0u8; NONCE_PREFIX_LEN];
    hk.expand(b"furry/v1/nonce_prefix", &mut nonce_prefix)
        .map_err(|_| CryptoError::HkdfExpand)?;

    let mut meta_xor_key = [0u8; AEAD_KEY_LEN];
    hk.expand(b"furry/v1/meta_xor_key", &mut meta_xor_key)
        .map_err(|_| CryptoError::HkdfExpand)?;

    Ok(FileKeys {
        aead_key,
        nonce_prefix,
        meta_xor_key,
    })
}

// ============================================================================
// Nonce 生成
// ============================================================================

/// 为指定 chunk 生成 nonce
///
/// nonce = nonce_prefix (4B) || chunk_seq_le (8B)
pub fn nonce_for_chunk(nonce_prefix: &[u8; NONCE_PREFIX_LEN], chunk_seq: u64) -> [u8; NONCE_LEN] {
    let mut nonce = [0u8; NONCE_LEN];
    nonce[0..NONCE_PREFIX_LEN].copy_from_slice(nonce_prefix);
    nonce[NONCE_PREFIX_LEN..NONCE_LEN].copy_from_slice(&chunk_seq.to_le_bytes());
    nonce
}

// ============================================================================
// AAD 构建
// ============================================================================

/// 构建 AAD（Additional Authenticated Data）
///
/// AAD = "FURRYAAD" || header_version_le || header_flags_le || file_id || chunk_header_bytes
pub fn build_aad_v1(
    file_id: &[u8; FILE_ID_LEN],
    header_version: u16,
    header_flags: u32,
    chunk_header_bytes: &[u8; CHUNK_HEADER_LEN],
) -> [u8; AAD_LEN] {
    let mut aad = [0u8; AAD_LEN];
    aad[0..8].copy_from_slice(&AAD_PREFIX);
    aad[8..10].copy_from_slice(&header_version.to_le_bytes());
    aad[10..14].copy_from_slice(&header_flags.to_le_bytes());
    aad[14..30].copy_from_slice(file_id);
    aad[30..70].copy_from_slice(chunk_header_bytes);
    aad
}

// ============================================================================
// AES-GCM 加密/解密
// ============================================================================

/// 原地加密，返回分离的 tag
pub fn encrypt_in_place_detached(
    aead_key: &[u8; AEAD_KEY_LEN],
    nonce: &[u8; NONCE_LEN],
    aad: &[u8],
    buffer: &mut [u8],
) -> Result<[u8; TAG_LEN], CryptoError> {
    let cipher = Aes256Gcm::new_from_slice(aead_key).map_err(|_| CryptoError::Aead)?;
    let tag = cipher
        .encrypt_in_place_detached(Nonce::from_slice(nonce), aad, buffer)
        .map_err(|_| CryptoError::Aead)?;

    let mut out = [0u8; TAG_LEN];
    out.copy_from_slice(tag.as_slice());
    Ok(out)
}

/// 原地解密，验证 tag
pub fn decrypt_in_place_detached(
    aead_key: &[u8; AEAD_KEY_LEN],
    nonce: &[u8; NONCE_LEN],
    aad: &[u8],
    buffer: &mut [u8],
    tag: &[u8; TAG_LEN],
) -> Result<(), CryptoError> {
    let cipher = Aes256Gcm::new_from_slice(aead_key).map_err(|_| CryptoError::Aead)?;
    let tag = GenericArray::from_slice(tag);
    cipher
        .decrypt_in_place_detached(Nonce::from_slice(nonce), aad, buffer, tag)
        .map_err(|_| CryptoError::Aead)?;
    Ok(())
}

// ============================================================================
// META XOR 混淆
// ============================================================================

/// META 数据 XOR 混淆（加密前/解密后调用）
///
/// 使用 BLAKE3 keyed XOF 生成与数据等长的 mask
pub fn xor_meta_in_place(meta_xor_key: &[u8; AEAD_KEY_LEN], chunk_seq: u64, data: &mut [u8]) {
    const CTX: &[u8] = b"furry/v1/meta_xor";

    let mut hasher = blake3::Hasher::new_keyed(meta_xor_key);
    hasher.update(CTX);
    hasher.update(&chunk_seq.to_le_bytes());
    let mut reader = hasher.finalize_xof();

    // 分块处理，避免大内存分配
    let mut offset = 0usize;
    let mut mask = [0u8; 1024];
    while offset < data.len() {
        let n = (data.len() - offset).min(mask.len());
        reader.fill(&mut mask[..n]);
        for i in 0..n {
            data[offset + i] ^= mask[i];
        }
        offset += n;
    }
}

// ============================================================================
// 随机数生成
// ============================================================================

/// 生成随机 salt
pub fn generate_salt() -> Result<[u8; SALT_LEN], CryptoError> {
    let mut salt = [0u8; SALT_LEN];
    getrandom::getrandom(&mut salt).map_err(|_| CryptoError::Random)?;
    Ok(salt)
}

/// 生成随机 file_id
pub fn generate_file_id() -> Result<[u8; FILE_ID_LEN], CryptoError> {
    let mut file_id = [0u8; FILE_ID_LEN];
    getrandom::getrandom(&mut file_id).map_err(|_| CryptoError::Random)?;
    Ok(file_id)
}

/// 生成随机字节
pub fn generate_random_bytes(buf: &mut [u8]) -> Result<(), CryptoError> {
    getrandom::getrandom(buf).map_err(|_| CryptoError::Random)?;
    Ok(())
}

// ============================================================================
// 测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_key_derivation() {
        let master = MasterKey::default_key();
        let salt = [0u8; SALT_LEN];
        let keys = derive_file_keys(&master, &salt).unwrap();

        // 确保派生的密钥不全为零
        assert_ne!(keys.aead_key, [0u8; AEAD_KEY_LEN]);
        assert_ne!(keys.nonce_prefix, [0u8; NONCE_PREFIX_LEN]);
        assert_ne!(keys.meta_xor_key, [0u8; AEAD_KEY_LEN]);
    }

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let master = MasterKey::default_key();
        let salt = generate_salt().unwrap();
        let keys = derive_file_keys(&master, &salt).unwrap();

        let file_id = generate_file_id().unwrap();
        let chunk_header = [0u8; CHUNK_HEADER_LEN];
        let nonce = nonce_for_chunk(&keys.nonce_prefix, 0);
        let aad = build_aad_v1(&file_id, 1, 0, &chunk_header);

        let original = b"Hello, Furry World!";
        let mut buffer = original.to_vec();

        // 加密
        let tag = encrypt_in_place_detached(&keys.aead_key, &nonce, &aad, &mut buffer).unwrap();

        // 确保密文与原文不同
        assert_ne!(&buffer[..], &original[..]);

        // 解密
        decrypt_in_place_detached(&keys.aead_key, &nonce, &aad, &mut buffer, &tag).unwrap();

        // 验证还原
        assert_eq!(&buffer[..], &original[..]);
    }

    #[test]
    fn test_tamper_detection() {
        let master = MasterKey::default_key();
        let salt = generate_salt().unwrap();
        let keys = derive_file_keys(&master, &salt).unwrap();

        let file_id = generate_file_id().unwrap();
        let chunk_header = [0u8; CHUNK_HEADER_LEN];
        let nonce = nonce_for_chunk(&keys.nonce_prefix, 0);
        let aad = build_aad_v1(&file_id, 1, 0, &chunk_header);

        let mut buffer = b"Secret data".to_vec();
        let tag = encrypt_in_place_detached(&keys.aead_key, &nonce, &aad, &mut buffer).unwrap();

        // 篡改密文
        buffer[0] ^= 0xFF;

        // 解密应失败
        let result = decrypt_in_place_detached(&keys.aead_key, &nonce, &aad, &mut buffer, &tag);
        assert!(result.is_err());
    }

    #[test]
    fn test_meta_xor_roundtrip() {
        let master = MasterKey::default_key();
        let salt = generate_salt().unwrap();
        let keys = derive_file_keys(&master, &salt).unwrap();

        let original = b"Metadata content here";
        let mut buffer = original.to_vec();

        // 混淆
        xor_meta_in_place(&keys.meta_xor_key, 42, &mut buffer);
        assert_ne!(&buffer[..], &original[..]);

        // 反混淆
        xor_meta_in_place(&keys.meta_xor_key, 42, &mut buffer);
        assert_eq!(&buffer[..], &original[..]);
    }
}
