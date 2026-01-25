//! 索引定义

use byteorder::{LittleEndian, ReadBytesExt};
use std::io::{Cursor, Read};

use crate::{ChunkType, FormatError};

pub const INDEX_MAGIC: [u8; 8] = *b"FURRYIDX";
pub const INDEX_VERSION: u16 = 1;
pub const INDEX_HEADER_LEN: usize = 32;
pub const INDEX_ENTRY_LEN: usize = 48;

/// 原始音频格式
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OriginalFormat {
    Unknown = 0,
    Wav = 1,
    Mp3 = 2,
    Ogg = 3,
    Flac = 4,
}

impl OriginalFormat {
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::Wav,
            2 => Self::Mp3,
            3 => Self::Ogg,
            4 => Self::Flac,
            _ => Self::Unknown,
        }
    }

    pub fn from_extension(ext: &str) -> Self {
        match ext.to_lowercase().as_str() {
            "wav" => Self::Wav,
            "mp3" => Self::Mp3,
            "ogg" | "opus" => Self::Ogg,
            "flac" => Self::Flac,
            _ => Self::Unknown,
        }
    }
}

/// 索引头 (v1, 32 bytes)
#[derive(Debug, Clone)]
pub struct IndexHeaderV1 {
    pub version: u16,
    pub flags: u16,
    pub entry_count: u32,
    pub audio_stream_len: u64,
    pub original_format: OriginalFormat,
    pub reserved: [u8; 7],
}

impl IndexHeaderV1 {
    pub fn new(entry_count: u32, audio_stream_len: u64, original_format: OriginalFormat) -> Self {
        Self {
            version: INDEX_VERSION,
            flags: 0,
            entry_count,
            audio_stream_len,
            original_format,
            reserved: [0u8; 7],
        }
    }
}

/// 索引条目 (v1, 48 bytes)
#[derive(Debug, Clone)]
pub struct IndexEntryV1 {
    pub chunk_seq: u64,
    pub file_offset: u64,
    pub record_len: u32,
    pub plain_len: u32,
    pub virtual_offset: u64,
    pub chunk_type: ChunkType,
    pub chunk_flags: u8,
    pub reserved0: u16,
    pub meta_kind: u16,
    pub reserved1: u16,
    pub reserved2: u32,
    pub reserved3: u32,
}

impl IndexEntryV1 {
    pub fn new_audio(
        chunk_seq: u64,
        file_offset: u64,
        record_len: u32,
        plain_len: u32,
        virtual_offset: u64,
    ) -> Self {
        Self {
            chunk_seq,
            file_offset,
            record_len,
            plain_len,
            virtual_offset,
            chunk_type: ChunkType::Audio,
            chunk_flags: 0,
            reserved0: 0,
            meta_kind: 0,
            reserved1: 0,
            reserved2: 0,
            reserved3: 0,
        }
    }

    pub fn new_meta(
        chunk_seq: u64,
        file_offset: u64,
        record_len: u32,
        plain_len: u32,
        meta_kind: MetaKind,
        chunk_flags: u8,
    ) -> Self {
        Self {
            chunk_seq,
            file_offset,
            record_len,
            plain_len,
            virtual_offset: 0,
            chunk_type: ChunkType::Meta,
            chunk_flags,
            reserved0: 0,
            meta_kind: meta_kind as u16,
            reserved1: 0,
            reserved2: 0,
            reserved3: 0,
        }
    }

    pub fn new_padding(chunk_seq: u64, file_offset: u64, record_len: u32, plain_len: u32) -> Self {
        Self {
            chunk_seq,
            file_offset,
            record_len,
            plain_len,
            virtual_offset: 0,
            chunk_type: ChunkType::Padding,
            chunk_flags: 0,
            reserved0: 0,
            meta_kind: 0,
            reserved1: 0,
            reserved2: 0,
            reserved3: 0,
        }
    }
}

/// META 类型
#[repr(u16)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MetaKind {
    Unknown = 0,
    CoverArt = 1,
    Lyrics = 2,
    Tags = 3,
}

impl MetaKind {
    pub fn from_u16(v: u16) -> Self {
        match v {
            1 => Self::CoverArt,
            2 => Self::Lyrics,
            3 => Self::Tags,
            _ => Self::Unknown,
        }
    }
}

/// 完整索引
#[derive(Debug, Clone)]
pub struct FurryIndexV1 {
    pub header: IndexHeaderV1,
    pub entries: Vec<IndexEntryV1>,
}

impl FurryIndexV1 {
    pub fn new(audio_stream_len: u64, original_format: OriginalFormat) -> Self {
        Self {
            header: IndexHeaderV1::new(0, audio_stream_len, original_format),
            entries: Vec::new(),
        }
    }

    pub fn add_entry(&mut self, entry: IndexEntryV1) {
        self.entries.push(entry);
        self.header.entry_count = self.entries.len() as u32;
    }

    /// 从解密后的明文解析索引
    pub fn parse(plain: &[u8]) -> Result<Self, FormatError> {
        if plain.len() < INDEX_HEADER_LEN {
            return Err(FormatError::CorruptIndex("index header too short"));
        }

        let mut cur = Cursor::new(plain);

        // 读取魔数
        let mut magic = [0u8; 8];
        cur.read_exact(&mut magic)?;
        if magic != INDEX_MAGIC {
            return Err(FormatError::InvalidIndexMagic);
        }

        let version = cur.read_u16::<LittleEndian>()?;
        if version != INDEX_VERSION {
            return Err(FormatError::UnsupportedIndexVersion(version));
        }

        let flags = cur.read_u16::<LittleEndian>()?;
        let entry_count = cur.read_u32::<LittleEndian>()?;
        let audio_stream_len = cur.read_u64::<LittleEndian>()?;
        let original_format = OriginalFormat::from_u8(cur.read_u8()?);

        let mut reserved = [0u8; 7];
        cur.read_exact(&mut reserved)?;

        let header = IndexHeaderV1 {
            version,
            flags,
            entry_count,
            audio_stream_len,
            original_format,
            reserved,
        };

        // 验证长度
        let expected_len = INDEX_HEADER_LEN + (entry_count as usize) * INDEX_ENTRY_LEN;
        if plain.len() != expected_len {
            return Err(FormatError::CorruptIndex("index length mismatch"));
        }

        // 读取条目
        let mut entries = Vec::with_capacity(entry_count as usize);
        for _ in 0..entry_count {
            let chunk_seq = cur.read_u64::<LittleEndian>()?;
            let file_offset = cur.read_u64::<LittleEndian>()?;
            let record_len = cur.read_u32::<LittleEndian>()?;
            let plain_len = cur.read_u32::<LittleEndian>()?;
            let virtual_offset = cur.read_u64::<LittleEndian>()?;
            let chunk_type = ChunkType::from_u8(cur.read_u8()?)
                .ok_or(FormatError::CorruptIndex("unknown chunk_type in index"))?;
            let chunk_flags = cur.read_u8()?;
            let reserved0 = cur.read_u16::<LittleEndian>()?;
            let meta_kind = cur.read_u16::<LittleEndian>()?;
            let reserved1 = cur.read_u16::<LittleEndian>()?;
            let reserved2 = cur.read_u32::<LittleEndian>()?;
            let reserved3 = cur.read_u32::<LittleEndian>()?;

            entries.push(IndexEntryV1 {
                chunk_seq,
                file_offset,
                record_len,
                plain_len,
                virtual_offset,
                chunk_type,
                chunk_flags,
                reserved0,
                meta_kind,
                reserved1,
                reserved2,
                reserved3,
            });
        }

        Ok(Self { header, entries })
    }

    /// 序列化为字节（加密前）
    pub fn to_bytes(&self) -> Vec<u8> {
        let len = INDEX_HEADER_LEN + self.entries.len() * INDEX_ENTRY_LEN;
        let mut buf = Vec::with_capacity(len);

        // 写入头部
        buf.extend_from_slice(&INDEX_MAGIC);
        buf.extend_from_slice(&self.header.version.to_le_bytes());
        buf.extend_from_slice(&self.header.flags.to_le_bytes());
        buf.extend_from_slice(&self.header.entry_count.to_le_bytes());
        buf.extend_from_slice(&self.header.audio_stream_len.to_le_bytes());
        buf.push(self.header.original_format as u8);
        buf.extend_from_slice(&self.header.reserved);

        // 写入条目
        for entry in &self.entries {
            buf.extend_from_slice(&entry.chunk_seq.to_le_bytes());
            buf.extend_from_slice(&entry.file_offset.to_le_bytes());
            buf.extend_from_slice(&entry.record_len.to_le_bytes());
            buf.extend_from_slice(&entry.plain_len.to_le_bytes());
            buf.extend_from_slice(&entry.virtual_offset.to_le_bytes());
            buf.push(entry.chunk_type as u8);
            buf.push(entry.chunk_flags);
            buf.extend_from_slice(&entry.reserved0.to_le_bytes());
            buf.extend_from_slice(&entry.meta_kind.to_le_bytes());
            buf.extend_from_slice(&entry.reserved1.to_le_bytes());
            buf.extend_from_slice(&entry.reserved2.to_le_bytes());
            buf.extend_from_slice(&entry.reserved3.to_le_bytes());
        }

        buf
    }

    /// 获取所有 AUDIO 条目（按 virtual_offset 排序）
    pub fn audio_entries(&self) -> Vec<&IndexEntryV1> {
        let mut entries: Vec<_> = self
            .entries
            .iter()
            .filter(|e| e.chunk_type == ChunkType::Audio)
            .collect();
        entries.sort_by_key(|e| e.virtual_offset);
        entries
    }

    /// 获取所有 META 条目
    pub fn meta_entries(&self) -> Vec<&IndexEntryV1> {
        self.entries
            .iter()
            .filter(|e| e.chunk_type == ChunkType::Meta)
            .collect()
    }
}
