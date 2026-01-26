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
        inner.seek(SeekFrom::Start(0))?;
        let header = FurryHeaderV1::read_from(&mut inner)?;

        let keys = furry_crypto::derive_file_keys(master_key, &header.salt)?;
        let index = Self::read_and_decrypt_index(&mut inner, &header, &keys)?;

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
    ) -> Result<FurryIndexV1, FormatError> {
        inner.seek(SeekFrom::Start(header.index_offset))?;

        let chunk_header = ChunkRecordHeaderV1::read_from(inner)?;
        if chunk_header.chunk_type != ChunkType::Index {
            return Err(FormatError::CorruptIndex(
                "index_offset not pointing to INDEX chunk",
            ));
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

    /// 读取并解密指定 chunk
    pub fn read_chunk(&mut self, entry: &crate::IndexEntryV1) -> Result<Vec<u8>, FormatError> {
        self.inner.seek(SeekFrom::Start(entry.file_offset))?;

        let chunk_header = ChunkRecordHeaderV1::read_from(&mut self.inner)?;

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
