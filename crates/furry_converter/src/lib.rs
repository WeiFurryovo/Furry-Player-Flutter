//! furry_converter - 格式转换器
//!
//! 提供音频文件与 .furry 格式之间的转换功能。

use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

use furry_crypto::MasterKey;
use furry_format::{FurryReader, FurryWriter, OriginalFormat};

/// 转换器错误
#[derive(thiserror::Error, Debug)]
pub enum ConverterError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Format error: {0}")]
    Format(#[from] furry_format::FormatError),

    #[error("Unsupported format: {0}")]
    UnsupportedFormat(String),
}

/// 封装选项
#[derive(Debug, Clone)]
pub struct PackOptions {
    /// AUDIO chunk 目标大小（字节）
    pub chunk_size: usize,
    /// 总 padding 字节数（负压缩率）
    pub padding_bytes: u64,
    /// 单个 padding chunk 大小
    pub padding_chunk_size: usize,
}

impl Default for PackOptions {
    fn default() -> Self {
        Self {
            chunk_size: 256 * 1024, // 256KB
            padding_bytes: 0,
            padding_chunk_size: 64 * 1024, // 64KB
        }
    }
}

/// 从文件扩展名检测格式
pub fn detect_format(path: &Path) -> OriginalFormat {
    path.extension()
        .and_then(|ext| ext.to_str())
        .map(OriginalFormat::from_extension)
        .unwrap_or(OriginalFormat::Unknown)
}

/// 透传封装：将原始音频文件封装为 .furry
///
/// 不重编码，直接将原始字节流切分加密封装。
pub fn pack_to_furry<R, W>(
    input: &mut R,
    output: &mut W,
    original_format: OriginalFormat,
    master_key: &MasterKey,
    options: &PackOptions,
) -> Result<(), ConverterError>
where
    R: Read + Seek,
    W: Write + Seek,
{
    // 获取输入文件大小
    let input_size = input.seek(SeekFrom::End(0))?;
    input.seek(SeekFrom::Start(0))?;

    // 创建 writer
    let mut writer = FurryWriter::create(output, master_key, original_format)?;

    // 分块读取并写入
    let mut buffer = vec![0u8; options.chunk_size];
    let mut virtual_offset: u64 = 0;

    loop {
        let bytes_read = read_full(input, &mut buffer)?;
        if bytes_read == 0 {
            break;
        }

        writer.write_audio_chunk(&buffer[..bytes_read], virtual_offset)?;
        virtual_offset += bytes_read as u64;
    }

    // 写入 padding chunks（负压缩率）
    if options.padding_bytes > 0 {
        let mut remaining = options.padding_bytes;
        while remaining > 0 {
            let chunk_size = remaining.min(options.padding_chunk_size as u64) as usize;
            writer.write_padding_chunk(chunk_size)?;
            remaining -= chunk_size as u64;
        }
    }

    // 完成写入
    writer.finish()?;

    Ok(())
}

/// 从 .furry 解包为原始音频流
pub fn unpack_from_furry<R, W>(
    input: &mut R,
    output: &mut W,
    master_key: &MasterKey,
) -> Result<OriginalFormat, ConverterError>
where
    R: Read + Seek,
    W: Write,
{
    let mut reader = FurryReader::open(input, master_key)?;

    let original_format = reader.index.header.original_format;

    // 按 virtual_offset 顺序读取所有 AUDIO chunks
    let audio_entries: Vec<_> = reader.index.audio_entries().into_iter().cloned().collect();

    for entry in &audio_entries {
        let data = reader.read_chunk(entry)?;
        output.write_all(&data)?;
    }

    Ok(original_format)
}

/// 读取尽可能多的字节（处理短读）
fn read_full<R: Read>(reader: &mut R, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut total = 0;
    while total < buf.len() {
        match reader.read(&mut buf[total..]) {
            Ok(0) => break,
            Ok(n) => total += n,
            Err(ref e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(total)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn test_pack_unpack_roundtrip() {
        let master_key = MasterKey::default_key();
        let original_data = b"This is fake MP3 audio data for testing purposes. ".repeat(100);

        // Pack
        let mut input = Cursor::new(&original_data);
        let mut furry_output = Cursor::new(Vec::new());

        pack_to_furry(
            &mut input,
            &mut furry_output,
            OriginalFormat::Mp3,
            &master_key,
            &PackOptions {
                chunk_size: 1024,
                ..Default::default()
            },
        )
        .unwrap();

        let furry_data = furry_output.into_inner();
        assert!(furry_data.len() > original_data.len()); // 加密后应该更大

        // Unpack
        let mut furry_input = Cursor::new(&furry_data);
        let mut unpacked_output = Cursor::new(Vec::new());

        let format = unpack_from_furry(&mut furry_input, &mut unpacked_output, &master_key).unwrap();

        assert_eq!(format, OriginalFormat::Mp3);
        assert_eq!(unpacked_output.into_inner(), original_data);
    }

    #[test]
    fn test_pack_with_padding() {
        let master_key = MasterKey::default_key();
        let original_data = b"Short audio data";

        let mut input = Cursor::new(&original_data[..]);
        let mut furry_output = Cursor::new(Vec::new());

        pack_to_furry(
            &mut input,
            &mut furry_output,
            OriginalFormat::Wav,
            &master_key,
            &PackOptions {
                chunk_size: 1024,
                padding_bytes: 10000, // 添加 10KB padding
                padding_chunk_size: 2000,
            },
        )
        .unwrap();

        let furry_data = furry_output.into_inner();

        // 验证文件大小包含 padding
        assert!(furry_data.len() > 10000);

        // 验证解包后数据正确
        let mut furry_input = Cursor::new(&furry_data);
        let mut unpacked_output = Cursor::new(Vec::new());

        unpack_from_furry(&mut furry_input, &mut unpacked_output, &master_key).unwrap();

        assert_eq!(unpacked_output.into_inner(), original_data);
    }
}
