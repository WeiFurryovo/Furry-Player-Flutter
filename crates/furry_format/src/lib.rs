//! furry_format - .furry 文件格式读写库

mod chunk;
mod header;
mod index;
mod reader;
mod writer;

pub use chunk::*;
pub use header::*;
pub use index::*;
pub use reader::*;
pub use writer::*;

/// 格式错误
#[derive(thiserror::Error, Debug)]
pub enum FormatError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Invalid FURRY magic")]
    InvalidMagic,

    #[error("Unsupported version: {0}")]
    UnsupportedVersion(u16),

    #[error("Invalid header size: {0}")]
    InvalidHeaderSize(u16),

    #[error("Unsupported KDF id: {0}")]
    UnsupportedKdfId(u16),

    #[error("Unsupported AEAD id: {0}")]
    UnsupportedAeadId(u16),

    #[error("Invalid chunk magic")]
    InvalidChunkMagic,

    #[error("Unsupported chunk header version: {0}")]
    UnsupportedChunkHeaderVersion(u16),

    #[error("Invalid index magic")]
    InvalidIndexMagic,

    #[error("Unsupported index version: {0}")]
    UnsupportedIndexVersion(u16),

    #[error("Invalid index offset: {0}")]
    InvalidIndexOffset(u64),

    #[error("Invalid index length: {0}")]
    InvalidIndexLength(u32),

    #[error("Crypto error: {0}")]
    Crypto(#[from] furry_crypto::CryptoError),

    #[error("Corrupt index: {0}")]
    CorruptIndex(&'static str),
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use furry_crypto::MasterKey;

    use crate::{
        FormatError, FurryHeaderV1, FurryIndexV1, FurryReader, FurryWriter, IndexEntryV1, MetaKind,
        OriginalFormat,
    };

    #[test]
    fn reader_writer_roundtrip_preserves_audio_and_latest_meta() {
        let master_key = MasterKey::default_key();
        let cursor = Cursor::new(Vec::new());
        let mut writer =
            FurryWriter::create(cursor, &master_key, OriginalFormat::Mp3).expect("create writer");

        writer
            .write_audio_chunk(b"abc", 0)
            .expect("write first audio chunk");
        writer
            .write_audio_chunk(b"defg", 3)
            .expect("write second audio chunk");
        writer
            .write_meta_chunk(MetaKind::Tags, br#"{"title":"old"}"#, 0)
            .expect("write first meta chunk");
        writer
            .write_meta_chunk(MetaKind::Tags, br#"{"title":"new"}"#, 0)
            .expect("write second meta chunk");

        let cursor = writer.finish().expect("finish writer");
        let mut reader =
            FurryReader::open(Cursor::new(cursor.into_inner()), &master_key).expect("open reader");

        assert!(reader.header.index_offset > 96);
        assert!(reader.header.index_total_len > 0);
        assert_eq!(reader.index.header.original_format, OriginalFormat::Mp3);

        let audio_entries = reader.index.audio_entries();
        assert_eq!(audio_entries.len(), 2);
        assert_eq!(audio_entries[0].virtual_offset, 0);
        assert_eq!(audio_entries[1].virtual_offset, 3);

        let second_audio = (*audio_entries[1]).clone();
        let tags = reader
            .read_latest_meta(MetaKind::Tags)
            .expect("read latest tags")
            .expect("tags should exist");

        assert_eq!(
            reader.read_chunk(&second_audio).expect("read second audio"),
            b"defg"
        );
        assert_eq!(tags, br#"{"title":"new"}"#);
    }

    #[test]
    fn header_rejects_invalid_magic() {
        let mut cursor = Cursor::new(b"NOTFURRY".to_vec());
        let error = FurryHeaderV1::read_from(&mut cursor).expect_err("should reject invalid magic");

        assert!(matches!(error, FormatError::InvalidMagic));
    }

    #[test]
    fn index_parse_rejects_length_mismatch() {
        let mut index = FurryIndexV1::new(3, OriginalFormat::Mp3);
        index.add_entry(IndexEntryV1::new_audio(0, 96, 59, 3, 0));

        let mut plain = index.to_bytes();
        plain.pop();

        let error = FurryIndexV1::parse(&plain).expect_err("should reject truncated index");

        assert!(matches!(
            error,
            FormatError::CorruptIndex("index length mismatch")
        ));
    }

    #[test]
    fn header_rejects_unsupported_kdf_id() {
        let mut header = FurryHeaderV1::new([1u8; 16], [2u8; 16]);
        header.kdf_id = 9;

        let mut bytes = Vec::new();
        header.write_to(&mut bytes).expect("write header");

        let error = FurryHeaderV1::read_from(&mut Cursor::new(bytes))
            .expect_err("should reject unsupported kdf id");

        assert!(matches!(error, FormatError::UnsupportedKdfId(9)));
    }

    #[test]
    fn header_rejects_unsupported_aead_id() {
        let mut header = FurryHeaderV1::new([1u8; 16], [2u8; 16]);
        header.aead_id = 7;

        let mut bytes = Vec::new();
        header.write_to(&mut bytes).expect("write header");

        let error = FurryHeaderV1::read_from(&mut Cursor::new(bytes))
            .expect_err("should reject unsupported aead id");

        assert!(matches!(error, FormatError::UnsupportedAeadId(7)));
    }

    #[test]
    fn header_rejects_unsupported_chunk_header_version() {
        let mut header = FurryHeaderV1::new([1u8; 16], [2u8; 16]);
        header.chunk_header_version = 2;

        let mut bytes = Vec::new();
        header.write_to(&mut bytes).expect("write header");

        let error = FurryHeaderV1::read_from(&mut Cursor::new(bytes))
            .expect_err("should reject unsupported chunk header version");

        assert!(matches!(
            error,
            FormatError::UnsupportedChunkHeaderVersion(2)
        ));
    }

    #[test]
    fn reader_rejects_index_offset_before_data_start() {
        let master_key = MasterKey::default_key();
        let mut header = FurryHeaderV1::new([1u8; 16], [2u8; 16]);
        header.fake_header_len = 32;
        header.index_offset = 96;
        header.index_total_len = 56;

        let mut bytes = Vec::new();
        header.write_to(&mut bytes).expect("write header");

        let error = match FurryReader::open(Cursor::new(bytes), &master_key) {
            Ok(_) => panic!("should reject invalid index offset"),
            Err(error) => error,
        };

        assert!(matches!(error, FormatError::InvalidIndexOffset(96)));
    }

    #[test]
    fn reader_rejects_too_small_index_length() {
        let master_key = MasterKey::default_key();
        let mut header = FurryHeaderV1::new([1u8; 16], [2u8; 16]);
        header.index_offset = 96;
        header.index_total_len = 20;

        let mut bytes = Vec::new();
        header.write_to(&mut bytes).expect("write header");

        let error = match FurryReader::open(Cursor::new(bytes), &master_key) {
            Ok(_) => panic!("should reject too small index length"),
            Err(error) => error,
        };

        assert!(matches!(error, FormatError::InvalidIndexLength(20)));
    }
}
