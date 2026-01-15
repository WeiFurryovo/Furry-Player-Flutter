//! furry_format - .furry 文件格式读写库

mod header;
mod chunk;
mod index;
mod reader;
mod writer;

pub use header::*;
pub use chunk::*;
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

    #[error("Invalid chunk magic")]
    InvalidChunkMagic,

    #[error("Unsupported chunk header version: {0}")]
    UnsupportedChunkHeaderVersion(u16),

    #[error("Invalid index magic")]
    InvalidIndexMagic,

    #[error("Unsupported index version: {0}")]
    UnsupportedIndexVersion(u16),

    #[error("Crypto error: {0}")]
    Crypto(#[from] furry_crypto::CryptoError),

    #[error("Corrupt index: {0}")]
    CorruptIndex(&'static str),
}
