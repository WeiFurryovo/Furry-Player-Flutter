//! Chunk 定义

use byteorder::{LittleEndian, ReadBytesExt, WriteBytesExt};
use std::io::{Read, Write};

use crate::FormatError;

pub const CHUNK_MAGIC: [u8; 4] = *b"FRCK";
pub const CHUNK_HEADER_LEN: u16 = 40;
pub const CHUNK_HEADER_VERSION: u16 = 1;

/// Chunk 类型
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChunkType {
    Audio = 0x01,
    Index = 0x02,
    Meta = 0x03,
    Padding = 0x04,
}

impl ChunkType {
    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            0x01 => Some(Self::Audio),
            0x02 => Some(Self::Index),
            0x03 => Some(Self::Meta),
            0x04 => Some(Self::Padding),
            _ => None,
        }
    }
}

/// Chunk 标志位
pub mod chunk_flags {
    /// META chunk 使用 XOR 混淆
    pub const FLAG_META_XOR: u8 = 0x01;
}

/// Chunk 记录头 (v1, 40 bytes)
#[derive(Debug, Clone)]
pub struct ChunkRecordHeaderV1 {
    pub header_len: u16,
    pub header_version: u16,
    pub chunk_type: ChunkType,
    pub chunk_flags: u8,
    pub reserved0: u16,
    pub chunk_seq: u64,
    pub virtual_offset: u64,
    pub plain_len: u32,
    pub reserved1: u32,
    pub reserved2: u32,
}

impl ChunkRecordHeaderV1 {
    pub fn new(chunk_type: ChunkType, chunk_seq: u64, virtual_offset: u64, plain_len: u32) -> Self {
        Self {
            header_len: CHUNK_HEADER_LEN,
            header_version: CHUNK_HEADER_VERSION,
            chunk_type,
            chunk_flags: 0,
            reserved0: 0,
            chunk_seq,
            virtual_offset,
            plain_len,
            reserved1: 0,
            reserved2: 0,
        }
    }

    pub fn read_from<R: Read>(r: &mut R) -> Result<Self, FormatError> {
        let mut magic = [0u8; 4];
        r.read_exact(&mut magic)?;
        if magic != CHUNK_MAGIC {
            return Err(FormatError::InvalidChunkMagic);
        }

        let header_len = r.read_u16::<LittleEndian>()?;
        let header_version = r.read_u16::<LittleEndian>()?;
        if header_version != CHUNK_HEADER_VERSION {
            return Err(FormatError::UnsupportedChunkHeaderVersion(header_version));
        }

        let chunk_type = ChunkType::from_u8(r.read_u8()?)
            .ok_or(FormatError::CorruptIndex("unknown chunk_type"))?;
        let chunk_flags = r.read_u8()?;
        let reserved0 = r.read_u16::<LittleEndian>()?;
        let chunk_seq = r.read_u64::<LittleEndian>()?;
        let virtual_offset = r.read_u64::<LittleEndian>()?;
        let plain_len = r.read_u32::<LittleEndian>()?;
        let reserved1 = r.read_u32::<LittleEndian>()?;
        let reserved2 = r.read_u32::<LittleEndian>()?;

        if header_len != CHUNK_HEADER_LEN {
            return Err(FormatError::CorruptIndex("chunk header_len != 40"));
        }

        Ok(Self {
            header_len,
            header_version,
            chunk_type,
            chunk_flags,
            reserved0,
            chunk_seq,
            virtual_offset,
            plain_len,
            reserved1,
            reserved2,
        })
    }

    pub fn write_to<W: Write>(&self, w: &mut W) -> Result<(), FormatError> {
        w.write_all(&CHUNK_MAGIC)?;
        w.write_u16::<LittleEndian>(self.header_len)?;
        w.write_u16::<LittleEndian>(self.header_version)?;
        w.write_u8(self.chunk_type as u8)?;
        w.write_u8(self.chunk_flags)?;
        w.write_u16::<LittleEndian>(self.reserved0)?;
        w.write_u64::<LittleEndian>(self.chunk_seq)?;
        w.write_u64::<LittleEndian>(self.virtual_offset)?;
        w.write_u32::<LittleEndian>(self.plain_len)?;
        w.write_u32::<LittleEndian>(self.reserved1)?;
        w.write_u32::<LittleEndian>(self.reserved2)?;
        Ok(())
    }

    /// 转换为字节数组（用于 AAD 构建）
    pub fn to_bytes(&self) -> [u8; furry_crypto::CHUNK_HEADER_LEN] {
        let mut out = [0u8; furry_crypto::CHUNK_HEADER_LEN];
        out[0..4].copy_from_slice(&CHUNK_MAGIC);
        out[4..6].copy_from_slice(&self.header_len.to_le_bytes());
        out[6..8].copy_from_slice(&self.header_version.to_le_bytes());
        out[8] = self.chunk_type as u8;
        out[9] = self.chunk_flags;
        out[10..12].copy_from_slice(&self.reserved0.to_le_bytes());
        out[12..20].copy_from_slice(&self.chunk_seq.to_le_bytes());
        out[20..28].copy_from_slice(&self.virtual_offset.to_le_bytes());
        out[28..32].copy_from_slice(&self.plain_len.to_le_bytes());
        out[32..36].copy_from_slice(&self.reserved1.to_le_bytes());
        out[36..40].copy_from_slice(&self.reserved2.to_le_bytes());
        out
    }

    /// 计算整个 chunk record 的总长度（header + ciphertext + tag）
    pub fn record_len(&self) -> u32 {
        CHUNK_HEADER_LEN as u32 + self.plain_len + furry_crypto::TAG_LEN as u32
    }
}
