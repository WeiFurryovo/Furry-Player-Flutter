//! 虚拟音频流
//!
//! 将 .furry 文件的加密 AUDIO chunks 映射为可 seek 的连续字节流，
//! 供 symphonia 解码器使用。

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use furry_crypto::MasterKey;
use furry_format::{FurryReader, IndexEntryV1};

/// 虚拟音频流错误
#[derive(thiserror::Error, Debug)]
pub enum StreamError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Format error: {0}")]
    Format(#[from] furry_format::FormatError),

    #[error("Seek out of bounds")]
    SeekOutOfBounds,
}

/// 虚拟音频流
///
/// 将 .furry 文件中的加密 AUDIO chunks 映射为连续的可读字节流。
pub struct VirtualAudioStream {
    reader: FurryReader<File>,
    /// 排序后的 AUDIO 条目
    audio_entries: Vec<IndexEntryV1>,
    /// 虚拟流总长度
    total_len: u64,
    /// 当前虚拟位置
    position: u64,
    /// 当前缓存的 chunk 数据
    current_chunk: Option<ChunkCache>,
}

struct ChunkCache {
    /// 解密后的数据
    data: Vec<u8>,
    /// 该 chunk 的虚拟起始偏移
    virtual_start: u64,
}

impl VirtualAudioStream {
    /// 打开 .furry 文件并创建虚拟流
    pub fn open(path: &Path, master_key: &MasterKey) -> Result<Self, StreamError> {
        let file = File::open(path)?;
        let reader = FurryReader::open(file, master_key)?;

        let audio_entries: Vec<_> = reader.index.audio_entries().into_iter().cloned().collect();
        let total_len = reader.index.header.audio_stream_len;

        Ok(Self {
            reader,
            audio_entries,
            total_len,
            position: 0,
            current_chunk: None,
        })
    }

    /// 获取原始格式
    pub fn original_format(&self) -> furry_format::OriginalFormat {
        self.reader.index.header.original_format
    }

    /// 获取总长度
    pub fn len(&self) -> u64 {
        self.total_len
    }

    pub fn is_empty(&self) -> bool {
        self.total_len == 0
    }

    /// 查找包含指定虚拟偏移的 chunk 索引
    fn find_chunk_index(&self, virtual_offset: u64) -> Option<usize> {
        self.audio_entries
            .binary_search_by(|entry| {
                let start = entry.virtual_offset;
                let end = start + entry.plain_len as u64;
                if virtual_offset < start {
                    std::cmp::Ordering::Greater
                } else if virtual_offset >= end {
                    std::cmp::Ordering::Less
                } else {
                    std::cmp::Ordering::Equal
                }
            })
            .ok()
    }

    /// 确保当前位置的 chunk 已加载
    fn ensure_chunk_loaded(&mut self) -> Result<(), StreamError> {
        if self.position >= self.total_len {
            return Ok(());
        }

        let need_load = match &self.current_chunk {
            None => true,
            Some(cache) => {
                let end = cache.virtual_start + cache.data.len() as u64;
                self.position < cache.virtual_start || self.position >= end
            }
        };

        if need_load {
            let chunk_idx = self
                .find_chunk_index(self.position)
                .ok_or(StreamError::SeekOutOfBounds)?;

            let entry = &self.audio_entries[chunk_idx];
            let data = self.reader.read_chunk(entry)?;

            self.current_chunk = Some(ChunkCache {
                data,
                virtual_start: entry.virtual_offset,
            });
        }

        Ok(())
    }
}

impl Read for VirtualAudioStream {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.position >= self.total_len {
            return Ok(0);
        }

        self.ensure_chunk_loaded().map_err(std::io::Error::other)?;

        let cache = self.current_chunk.as_ref().unwrap();
        let offset_in_chunk = (self.position - cache.virtual_start) as usize;
        let available = cache.data.len() - offset_in_chunk;
        let to_read = buf.len().min(available);

        buf[..to_read].copy_from_slice(&cache.data[offset_in_chunk..offset_in_chunk + to_read]);
        self.position += to_read as u64;

        Ok(to_read)
    }
}

impl Seek for VirtualAudioStream {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        let new_pos = match pos {
            SeekFrom::Start(offset) => offset as i64,
            SeekFrom::End(offset) => self.total_len as i64 + offset,
            SeekFrom::Current(offset) => self.position as i64 + offset,
        };

        if new_pos < 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "seek to negative position",
            ));
        }

        self.position = new_pos as u64;
        Ok(self.position)
    }
}

/// 为 symphonia 实现 MediaSource trait
impl symphonia::core::io::MediaSource for VirtualAudioStream {
    fn is_seekable(&self) -> bool {
        true
    }

    fn byte_len(&self) -> Option<u64> {
        Some(self.total_len)
    }
}
