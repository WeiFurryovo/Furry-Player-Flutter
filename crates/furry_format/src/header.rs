//! 文件头定义

use byteorder::{LittleEndian, ReadBytesExt};
use std::io::{Read, Write};

use crate::FormatError;

pub const FURRY_MAGIC: [u8; 8] = *b"FURRYFMT";
pub const FURRY_VERSION: u16 = 1;
pub const FURRY_HEADER_LEN: u16 = 96;
pub const FURRY_KDF_ID: u16 = 1;
pub const FURRY_AEAD_ID: u16 = 1;
pub const FURRY_FILE_CHUNK_HEADER_VERSION: u16 = 1;

/// .furry 文件主头部 (v1, 96 bytes)
#[derive(Debug, Clone)]
pub struct FurryHeaderV1 {
    pub version: u16,
    pub header_size: u16,
    pub flags: u32,
    pub fake_header_len: u32,
    pub file_id: [u8; 16],
    pub salt: [u8; 16],
    pub kdf_id: u16,
    pub aead_id: u16,
    pub chunk_header_version: u16,
    pub index_offset: u64,
    pub index_total_len: u32,
    pub header_crc32: u32,
    pub reserved2: [u8; 16],
}

impl FurryHeaderV1 {
    pub fn new(file_id: [u8; 16], salt: [u8; 16]) -> Self {
        Self {
            version: FURRY_VERSION,
            header_size: FURRY_HEADER_LEN,
            flags: 0,
            fake_header_len: 0,
            file_id,
            salt,
            kdf_id: FURRY_KDF_ID,   // HKDF-SHA256
            aead_id: FURRY_AEAD_ID, // AES-256-GCM
            chunk_header_version: FURRY_FILE_CHUNK_HEADER_VERSION,
            index_offset: 0,
            index_total_len: 0,
            header_crc32: 0,
            reserved2: [0u8; 16],
        }
    }

    pub fn read_from<R: Read>(r: &mut R) -> Result<Self, FormatError> {
        let mut magic = [0u8; 8];
        r.read_exact(&mut magic)?;
        if magic != FURRY_MAGIC {
            return Err(FormatError::InvalidMagic);
        }

        let version = r.read_u16::<LittleEndian>()?;
        if version != FURRY_VERSION {
            return Err(FormatError::UnsupportedVersion(version));
        }

        let header_size = r.read_u16::<LittleEndian>()?;
        if header_size != FURRY_HEADER_LEN {
            return Err(FormatError::InvalidHeaderSize(header_size));
        }

        let flags = r.read_u32::<LittleEndian>()?;
        let fake_header_len = r.read_u32::<LittleEndian>()?;
        let _reserved0 = r.read_u32::<LittleEndian>()?;

        let mut file_id = [0u8; 16];
        r.read_exact(&mut file_id)?;

        let mut salt = [0u8; 16];
        r.read_exact(&mut salt)?;

        let kdf_id = r.read_u16::<LittleEndian>()?;
        if kdf_id != FURRY_KDF_ID {
            return Err(FormatError::UnsupportedKdfId(kdf_id));
        }
        let aead_id = r.read_u16::<LittleEndian>()?;
        if aead_id != FURRY_AEAD_ID {
            return Err(FormatError::UnsupportedAeadId(aead_id));
        }
        let chunk_header_version = r.read_u16::<LittleEndian>()?;
        if chunk_header_version != FURRY_FILE_CHUNK_HEADER_VERSION {
            return Err(FormatError::UnsupportedChunkHeaderVersion(
                chunk_header_version,
            ));
        }
        let _reserved1 = r.read_u16::<LittleEndian>()?;

        let index_offset = r.read_u64::<LittleEndian>()?;
        let index_total_len = r.read_u32::<LittleEndian>()?;
        let header_crc32 = r.read_u32::<LittleEndian>()?;

        let mut reserved2 = [0u8; 16];
        r.read_exact(&mut reserved2)?;

        let header = Self {
            version,
            header_size,
            flags,
            fake_header_len,
            file_id,
            salt,
            kdf_id,
            aead_id,
            chunk_header_version,
            index_offset,
            index_total_len,
            header_crc32,
            reserved2,
        };

        if header.header_crc32 != 0 {
            let expected = header.compute_crc32();
            if header.header_crc32 != expected {
                return Err(FormatError::InvalidHeaderCrc32 {
                    expected,
                    actual: header.header_crc32,
                });
            }
        }

        Ok(header)
    }

    pub fn write_to<W: Write>(&self, w: &mut W) -> Result<(), FormatError> {
        w.write_all(&self.to_bytes_with_crc(self.header_crc32))?;
        Ok(())
    }

    pub fn compute_crc32(&self) -> u32 {
        crc32fast::hash(&self.to_bytes_with_crc(0))
    }

    fn to_bytes_with_crc(&self, crc32: u32) -> [u8; FURRY_HEADER_LEN as usize] {
        let mut out = [0u8; FURRY_HEADER_LEN as usize];
        out[0..8].copy_from_slice(&FURRY_MAGIC);
        out[8..10].copy_from_slice(&self.version.to_le_bytes());
        out[10..12].copy_from_slice(&self.header_size.to_le_bytes());
        out[12..16].copy_from_slice(&self.flags.to_le_bytes());
        out[16..20].copy_from_slice(&self.fake_header_len.to_le_bytes());
        out[20..24].copy_from_slice(&0u32.to_le_bytes());
        out[24..40].copy_from_slice(&self.file_id);
        out[40..56].copy_from_slice(&self.salt);
        out[56..58].copy_from_slice(&self.kdf_id.to_le_bytes());
        out[58..60].copy_from_slice(&self.aead_id.to_le_bytes());
        out[60..62].copy_from_slice(&self.chunk_header_version.to_le_bytes());
        out[62..64].copy_from_slice(&0u16.to_le_bytes());
        out[64..72].copy_from_slice(&self.index_offset.to_le_bytes());
        out[72..76].copy_from_slice(&self.index_total_len.to_le_bytes());
        out[76..80].copy_from_slice(&crc32.to_le_bytes());
        out[80..96].copy_from_slice(&self.reserved2);
        out
    }

    /// 计算数据起始偏移（跳过 fake header）
    pub fn data_start_offset(&self) -> u64 {
        FURRY_HEADER_LEN as u64 + self.fake_header_len as u64
    }
}
