//! .furry 文件写入器

use std::io::{Seek, SeekFrom, Write};

use furry_crypto::{FileKeys, MasterKey};

use crate::{
    ChunkRecordHeaderV1, ChunkType, FormatError, FurryHeaderV1, FurryIndexV1, IndexEntryV1,
    OriginalFormat, FURRY_HEADER_LEN,
};

/// .furry 文件写入器
pub struct FurryWriter<W: Write + Seek> {
    inner: W,
    header: FurryHeaderV1,
    keys: FileKeys,
    index: FurryIndexV1,
    chunk_seq: u64,
    current_offset: u64,
}

impl<W: Write + Seek> FurryWriter<W> {
    /// 创建新的 .furry 文件
    pub fn create(
        mut inner: W,
        master_key: &MasterKey,
        original_format: OriginalFormat,
    ) -> Result<Self, FormatError> {
        let file_id = furry_crypto::generate_file_id()?;
        let salt = furry_crypto::generate_salt()?;
        let keys = furry_crypto::derive_file_keys(master_key, &salt)?;

        let header = FurryHeaderV1::new(file_id, salt);

        // 写入占位头部（稍后更新）
        inner.seek(SeekFrom::Start(0))?;
        header.write_to(&mut inner)?;

        let current_offset = FURRY_HEADER_LEN as u64;

        Ok(Self {
            inner,
            header,
            keys,
            index: FurryIndexV1::new(0, original_format),
            chunk_seq: 0,
            current_offset,
        })
    }

    /// 写入 AUDIO chunk
    pub fn write_audio_chunk(
        &mut self,
        data: &[u8],
        virtual_offset: u64,
    ) -> Result<(), FormatError> {
        self.write_chunk_internal(ChunkType::Audio, data, virtual_offset, 0, 0)
    }

    /// 写入 PADDING chunk
    pub fn write_padding_chunk(&mut self, size: usize) -> Result<(), FormatError> {
        let mut padding = vec![0u8; size];
        furry_crypto::generate_random_bytes(&mut padding)?;
        self.write_chunk_internal(ChunkType::Padding, &padding, 0, 0, 0)
    }

    /// 写入 META chunk
    pub fn write_meta_chunk(
        &mut self,
        kind: crate::MetaKind,
        data: &[u8],
        chunk_flags: u8,
    ) -> Result<(), FormatError> {
        self.write_chunk_internal(ChunkType::Meta, data, 0, kind as u16, chunk_flags)
    }

    fn write_chunk_internal(
        &mut self,
        chunk_type: ChunkType,
        data: &[u8],
        virtual_offset: u64,
        meta_kind: u16,
        chunk_flags: u8,
    ) -> Result<(), FormatError> {
        let chunk_seq = self.chunk_seq;
        self.chunk_seq += 1;

        let mut chunk_header =
            ChunkRecordHeaderV1::new(chunk_type, chunk_seq, virtual_offset, data.len() as u32);
        chunk_header.chunk_flags = chunk_flags;

        // 加密数据
        let mut ciphertext = data.to_vec();
        let nonce = furry_crypto::nonce_for_chunk(&self.keys.nonce_prefix, chunk_seq);
        let aad = furry_crypto::build_aad_v1(
            &self.header.file_id,
            self.header.version,
            self.header.flags,
            &chunk_header.to_bytes(),
        );

        let tag = furry_crypto::encrypt_in_place_detached(
            &self.keys.aead_key,
            &nonce,
            &aad,
            &mut ciphertext,
        )?;

        // 记录文件偏移
        let file_offset = self.current_offset;

        // 写入 chunk
        chunk_header.write_to(&mut self.inner)?;
        self.inner.write_all(&ciphertext)?;
        self.inner.write_all(&tag)?;

        let record_len = chunk_header.record_len();
        self.current_offset += record_len as u64;

        // 添加索引条目
        let entry = match chunk_type {
            ChunkType::Audio => {
                self.index.header.audio_stream_len += data.len() as u64;
                IndexEntryV1::new_audio(
                    chunk_seq,
                    file_offset,
                    record_len,
                    data.len() as u32,
                    virtual_offset,
                )
            }
            ChunkType::Meta => {
                let kind = crate::MetaKind::from_u16(meta_kind);
                IndexEntryV1::new_meta(
                    chunk_seq,
                    file_offset,
                    record_len,
                    data.len() as u32,
                    kind,
                    chunk_flags,
                )
            }
            ChunkType::Padding => {
                IndexEntryV1::new_padding(chunk_seq, file_offset, record_len, data.len() as u32)
            }
            _ => return Ok(()),
        };
        self.index.add_entry(entry);

        Ok(())
    }

    /// 完成写入（写入 INDEX 并更新头部）
    pub fn finish(mut self) -> Result<W, FormatError> {
        // 写入 INDEX chunk
        let index_offset = self.current_offset;
        let index_data = self.index.to_bytes();
        let index_plain_len = index_data.len() as u32;

        let chunk_seq = self.chunk_seq;
        let chunk_header =
            ChunkRecordHeaderV1::new(ChunkType::Index, chunk_seq, 0, index_plain_len);

        let mut ciphertext = index_data;
        let nonce = furry_crypto::nonce_for_chunk(&self.keys.nonce_prefix, chunk_seq);
        let aad = furry_crypto::build_aad_v1(
            &self.header.file_id,
            self.header.version,
            self.header.flags,
            &chunk_header.to_bytes(),
        );

        let tag = furry_crypto::encrypt_in_place_detached(
            &self.keys.aead_key,
            &nonce,
            &aad,
            &mut ciphertext,
        )?;

        chunk_header.write_to(&mut self.inner)?;
        self.inner.write_all(&ciphertext)?;
        self.inner.write_all(&tag)?;

        let index_total_len = chunk_header.record_len();

        // 更新头部
        self.header.index_offset = index_offset;
        self.header.index_total_len = index_total_len;

        self.inner.seek(SeekFrom::Start(0))?;
        self.header.write_to(&mut self.inner)?;

        Ok(self.inner)
    }
}
