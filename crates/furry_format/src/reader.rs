//! .furry 文件读取器

use std::io::{Read, Seek, SeekFrom};

use furry_crypto::{FileKeys, MasterKey};

use crate::{ChunkRecordHeaderV1, ChunkType, FormatError, FurryHeaderV1, FurryIndexV1};

/// .furry 文件读取器
pub struct FurryReader<R: Read + Seek> {
    inner: R,
    pub header: FurryHeaderV1,
    pub keys: FileKeys,
    pub index: FurryIndexV1,
}

impl<R: Read + Seek> FurryReader<R> {
    /// 打开 .furry 文件
    pub fn open(mut inner: R, master_key: &MasterKey) -> Result<Self, FormatError> {
        let file_len = inner.seek(SeekFrom::End(0))?;
        inner.seek(SeekFrom::Start(0))?;
        let header = FurryHeaderV1::read_from(&mut inner)?;

        let keys = furry_crypto::derive_file_keys(master_key, &header.salt)?;
        let index = Self::read_and_decrypt_index(&mut inner, &header, &keys, file_len)?;
        Self::validate_entry_ranges(&header, &index)?;

        Ok(Self {
            inner,
            header,
            keys,
            index,
        })
    }

    fn read_and_decrypt_index(
        inner: &mut R,
        header: &FurryHeaderV1,
        keys: &FileKeys,
        file_len: u64,
    ) -> Result<FurryIndexV1, FormatError> {
        if header.index_offset < header.data_start_offset() {
            return Err(FormatError::InvalidIndexOffset(header.index_offset));
        }
        let min_index_record_len =
            u32::from(crate::CHUNK_HEADER_LEN) + furry_crypto::TAG_LEN as u32;
        if header.index_total_len < min_index_record_len {
            return Err(FormatError::InvalidIndexLength(header.index_total_len));
        }
        let index_end = header
            .index_offset
            .checked_add(header.index_total_len as u64)
            .ok_or(FormatError::InvalidIndexRange {
                offset: header.index_offset,
                len: header.index_total_len,
                file_len,
            })?;
        if index_end > file_len {
            return Err(FormatError::InvalidIndexRange {
                offset: header.index_offset,
                len: header.index_total_len,
                file_len,
            });
        }

        inner.seek(SeekFrom::Start(header.index_offset))?;

        let chunk_header = ChunkRecordHeaderV1::read_from(inner)?;
        if chunk_header.chunk_type != ChunkType::Index {
            return Err(FormatError::CorruptIndex(
                "index_offset not pointing to INDEX chunk",
            ));
        }
        if chunk_header.record_len() != header.index_total_len {
            return Err(FormatError::CorruptIndex("index_total_len mismatch"));
        }

        let mut ciphertext = vec![0u8; chunk_header.plain_len as usize];
        inner.read_exact(&mut ciphertext)?;

        let mut tag = [0u8; furry_crypto::TAG_LEN];
        inner.read_exact(&mut tag)?;

        let nonce = furry_crypto::nonce_for_chunk(&keys.nonce_prefix, chunk_header.chunk_seq);
        let aad = furry_crypto::build_aad_v1(
            &header.file_id,
            header.version,
            header.flags,
            &chunk_header.to_bytes(),
        );

        furry_crypto::decrypt_in_place_detached(
            &keys.aead_key,
            &nonce,
            &aad,
            &mut ciphertext,
            &tag,
        )?;

        FurryIndexV1::parse(&ciphertext)
    }

    fn validate_entry_ranges(
        header: &FurryHeaderV1,
        index: &FurryIndexV1,
    ) -> Result<(), FormatError> {
        let data_start = header.data_start_offset();
        let data_limit = header.index_offset;

        for entry in &index.entries {
            if entry.file_offset < data_start {
                return Err(FormatError::InvalidChunkRange {
                    offset: entry.file_offset,
                    len: entry.record_len,
                    limit: data_limit,
                });
            }

            let file_end = entry
                .file_offset
                .checked_add(entry.record_len as u64)
                .ok_or(FormatError::InvalidChunkRange {
                    offset: entry.file_offset,
                    len: entry.record_len,
                    limit: data_limit,
                })?;
            if file_end > data_limit {
                return Err(FormatError::InvalidChunkRange {
                    offset: entry.file_offset,
                    len: entry.record_len,
                    limit: data_limit,
                });
            }
        }

        Ok(())
    }

    /// 读取并解密指定 chunk
    pub fn read_chunk(&mut self, entry: &crate::IndexEntryV1) -> Result<Vec<u8>, FormatError> {
        self.inner.seek(SeekFrom::Start(entry.file_offset))?;

        let chunk_header = ChunkRecordHeaderV1::read_from(&mut self.inner)?;
        if chunk_header.chunk_seq != entry.chunk_seq {
            return Err(FormatError::ChunkRecordMismatch("chunk_seq"));
        }
        if chunk_header.chunk_type != entry.chunk_type {
            return Err(FormatError::ChunkRecordMismatch("chunk_type"));
        }
        if chunk_header.chunk_flags != entry.chunk_flags {
            return Err(FormatError::ChunkRecordMismatch("chunk_flags"));
        }
        if chunk_header.virtual_offset != entry.virtual_offset {
            return Err(FormatError::ChunkRecordMismatch("virtual_offset"));
        }
        if chunk_header.plain_len != entry.plain_len {
            return Err(FormatError::ChunkRecordMismatch("plain_len"));
        }
        if chunk_header.record_len() != entry.record_len {
            return Err(FormatError::ChunkRecordMismatch("record_len"));
        }

        let mut ciphertext = vec![0u8; chunk_header.plain_len as usize];
        self.inner.read_exact(&mut ciphertext)?;

        let mut tag = [0u8; furry_crypto::TAG_LEN];
        self.inner.read_exact(&mut tag)?;

        let nonce = furry_crypto::nonce_for_chunk(&self.keys.nonce_prefix, chunk_header.chunk_seq);
        let aad = furry_crypto::build_aad_v1(
            &self.header.file_id,
            self.header.version,
            self.header.flags,
            &chunk_header.to_bytes(),
        );

        furry_crypto::decrypt_in_place_detached(
            &self.keys.aead_key,
            &nonce,
            &aad,
            &mut ciphertext,
            &tag,
        )?;

        Ok(ciphertext)
    }

    /// 读取指定 kind 的最新 META chunk（按 chunk_seq 最大）
    pub fn read_latest_meta(
        &mut self,
        kind: crate::MetaKind,
    ) -> Result<Option<Vec<u8>>, FormatError> {
        let entry = self
            .index
            .meta_entries_by_kind(kind)
            .last()
            .map(|e| (*e).clone());
        let Some(entry) = entry else {
            return Ok(None);
        };
        // Guard against pathological META payload sizes (can OOM on mobile).
        // Cover art can be large, but should still be bounded.
        const MAX_TAGS_BYTES: u32 = 256 * 1024; // 256 KiB
        const MAX_LYRICS_BYTES: u32 = 2 * 1024 * 1024; // 2 MiB

        // Cover art can be large; keep this high to avoid unexpectedly dropping art.
        // NOTE: Very large covers may increase memory usage on mobile.
        const MAX_COVER_BYTES: u32 = 64 * 1024 * 1024; // 64 MiB (includes mime\0 prefix)
        let max_plain_len = match kind {
            crate::MetaKind::Tags => MAX_TAGS_BYTES,
            crate::MetaKind::Lyrics => MAX_LYRICS_BYTES,
            crate::MetaKind::CoverArt => MAX_COVER_BYTES,
            crate::MetaKind::Unknown => MAX_TAGS_BYTES,
        };
        if entry.plain_len > max_plain_len {
            return Ok(None);
        }
        Ok(Some(self.read_chunk(&entry)?))
    }

    /// 获取内部 reader
    pub fn into_inner(self) -> R {
        self.inner
    }
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use crate::{FormatError, FurryHeaderV1, FurryIndexV1, IndexEntryV1, OriginalFormat};

    use super::FurryReader;

    #[test]
    fn validate_entry_ranges_rejects_chunk_before_data_region() {
        let mut header = FurryHeaderV1::new([1u8; 16], [2u8; 16]);
        header.fake_header_len = 32;
        header.index_offset = 256;

        let mut index = FurryIndexV1::new(3, OriginalFormat::Mp3);
        index.add_entry(IndexEntryV1::new_audio(0, 120, 59, 3, 0));

        let error = FurryReader::<Cursor<Vec<u8>>>::validate_entry_ranges(&header, &index)
            .expect_err("should reject chunk before data region");

        assert!(matches!(
            error,
            FormatError::InvalidChunkRange {
                offset: 120,
                len: 59,
                limit: 256
            }
        ));
    }

    #[test]
    fn validate_entry_ranges_rejects_chunk_crossing_into_index_region() {
        let mut header = FurryHeaderV1::new([1u8; 16], [2u8; 16]);
        header.index_offset = 200;

        let mut index = FurryIndexV1::new(3, OriginalFormat::Mp3);
        index.add_entry(IndexEntryV1::new_audio(0, 160, 59, 3, 0));

        let error = FurryReader::<Cursor<Vec<u8>>>::validate_entry_ranges(&header, &index)
            .expect_err("should reject chunk crossing into index region");

        assert!(matches!(
            error,
            FormatError::InvalidChunkRange {
                offset: 160,
                len: 59,
                limit: 200
            }
        ));
    }
}
