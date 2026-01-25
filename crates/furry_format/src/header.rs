//! 文件头定义

use byteorder::{LittleEndian, ReadBytesExt, WriteBytesExt};
use std::io::{Read, Write};

use crate::FormatError;

pub const FURRY_MAGIC: [u8; 8] = *b"FURRYFMT";
pub const FURRY_VERSION: u16 = 1;
pub const FURRY_HEADER_LEN: u16 = 96;

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
            kdf_id: 1,  // HKDF-SHA256
            aead_id: 1, // AES-256-GCM
            chunk_header_version: 1,
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
        let aead_id = r.read_u16::<LittleEndian>()?;
        let chunk_header_version = r.read_u16::<LittleEndian>()?;
        let _reserved1 = r.read_u16::<LittleEndian>()?;

        let index_offset = r.read_u64::<LittleEndian>()?;
        let index_total_len = r.read_u32::<LittleEndian>()?;
        let header_crc32 = r.read_u32::<LittleEndian>()?;

        let mut reserved2 = [0u8; 16];
        r.read_exact(&mut reserved2)?;

        Ok(Self {
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
        })
    }

    pub fn write_to<W: Write>(&self, w: &mut W) -> Result<(), FormatError> {
        w.write_all(&FURRY_MAGIC)?;
        w.write_u16::<LittleEndian>(self.version)?;
        w.write_u16::<LittleEndian>(self.header_size)?;
        w.write_u32::<LittleEndian>(self.flags)?;
        w.write_u32::<LittleEndian>(self.fake_header_len)?;
        w.write_u32::<LittleEndian>(0)?; // reserved0
        w.write_all(&self.file_id)?;
        w.write_all(&self.salt)?;
        w.write_u16::<LittleEndian>(self.kdf_id)?;
        w.write_u16::<LittleEndian>(self.aead_id)?;
        w.write_u16::<LittleEndian>(self.chunk_header_version)?;
        w.write_u16::<LittleEndian>(0)?; // reserved1
        w.write_u64::<LittleEndian>(self.index_offset)?;
        w.write_u32::<LittleEndian>(self.index_total_len)?;
        w.write_u32::<LittleEndian>(self.header_crc32)?;
        w.write_all(&self.reserved2)?;
        Ok(())
    }

    /// 计算数据起始偏移（跳过 fake header）
    pub fn data_start_offset(&self) -> u64 {
        FURRY_HEADER_LEN as u64 + self.fake_header_len as u64
    }
}
