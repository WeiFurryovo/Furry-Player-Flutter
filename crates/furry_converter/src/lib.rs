//! furry_converter - 格式转换器
//!
//! 提供音频文件与 .furry 格式之间的转换功能。

use std::io::{Read, Seek, Write};
use std::path::Path;

use furry_crypto::MasterKey;
use furry_format::{FurryReader, FurryWriter, MetaKind, OriginalFormat};
use serde::Serialize;
use symphonia::core::codecs::CODEC_TYPE_NULL;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::{MetadataOptions, StandardTagKey, Value as MetaValue};
use symphonia::core::probe::Hint;

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
    /// 尝试写入 META（tags/cover 等），需要 `input_path` 可用
    pub include_meta: bool,
}

impl Default for PackOptions {
    fn default() -> Self {
        Self {
            chunk_size: 256 * 1024, // 256KB
            padding_bytes: 0,
            padding_chunk_size: 64 * 1024, // 64KB
            include_meta: true,
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
    input_path: Option<&Path>,
    original_format: OriginalFormat,
    master_key: &MasterKey,
    options: &PackOptions,
) -> Result<(), ConverterError>
where
    R: Read + Seek,
    W: Write + Seek,
{
    // 创建 writer
    let mut writer = FurryWriter::create(output, master_key, original_format)?;

    if options.include_meta {
        if let Some(path) = input_path {
            if let Some(meta) = extract_meta_from_path(path, original_format) {
                if let Some(tags_json) = meta.tags_json {
                    let _ = writer.write_meta_chunk(MetaKind::Tags, tags_json.as_bytes(), 0);
                }
                if let Some(cover) = meta.cover {
                    let mut payload = Vec::with_capacity(cover.mime.len() + 1 + cover.bytes.len());
                    payload.extend_from_slice(cover.mime.as_bytes());
                    payload.push(0);
                    payload.extend_from_slice(&cover.bytes);
                    let _ = writer.write_meta_chunk(MetaKind::CoverArt, &payload, 0);
                }
                if let Some(lyrics) = meta.lyrics {
                    let _ = writer.write_meta_chunk(MetaKind::Lyrics, lyrics.as_bytes(), 0);
                }
            }
        }
    }

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

#[derive(Debug)]
struct CoverArt {
    mime: String,
    bytes: Vec<u8>,
}

#[derive(Debug)]
struct ExtractedMeta {
    tags_json: Option<String>,
    cover: Option<CoverArt>,
    lyrics: Option<String>,
}

#[derive(Debug, Serialize)]
struct TagsJsonV1 {
    schema: &'static str,
    original_format: String,
    title: Option<String>,
    artist: Option<String>,
    album: Option<String>,
    album_artist: Option<String>,
    genre: Option<String>,
    track: Option<u32>,
    disc: Option<u32>,
    year: Option<i32>,
    comment: Option<String>,
    duration_ms: Option<u64>,
    sample_rate: Option<u32>,
    channels: Option<u16>,
    codec: Option<String>,
    raw: Vec<(String, String)>,
}

fn extract_meta_from_path(path: &Path, original_format: OriginalFormat) -> Option<ExtractedMeta> {
    let file = std::fs::File::open(path).ok()?;

    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .ok()?;

    let mut raw_tags: Vec<(String, String)> = Vec::new();
    let mut cover: Option<CoverArt> = None;
    let mut lyrics: Option<String> = None;

    let mut title: Option<String> = None;
    let mut artist: Option<String> = None;
    let mut album: Option<String> = None;
    let mut album_artist: Option<String> = None;
    let mut genre: Option<String> = None;
    let mut track: Option<u32> = None;
    let mut disc: Option<u32> = None;
    let mut year: Option<i32> = None;
    let mut comment: Option<String> = None;

    let mut duration_ms: Option<u64> = None;
    let mut sample_rate: Option<u32> = None;
    let mut channels: Option<u16> = None;
    let mut codec: Option<String> = None;

    // Track info (duration/sample_rate/channels/codec)
    if let Some(t) = probed
        .format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
    {
        codec = Some(format!("{:?}", t.codec_params.codec));
        sample_rate = t.codec_params.sample_rate;
        channels = t.codec_params.channels.map(|c| c.count() as u16);
        if let (Some(frames), Some(sr)) = (t.codec_params.n_frames, t.codec_params.sample_rate) {
            duration_ms = Some(((frames as f64 / sr as f64) * 1000.0) as u64);
        }
    }

    // Tags/visuals from both metadata blocks (best-effort)
    for meta in [probed.format.metadata().current(), probed.metadata.get().current()]
        .into_iter()
        .flatten()
    {
        for tag in meta.tags() {
            let key = tag
                .std_key
                .map(|k| format!("{:?}", k))
                .unwrap_or_else(|| tag.key.to_string());
            let val = meta_value_to_string(&tag.value);
            raw_tags.push((key.clone(), val.clone()));

            match tag.std_key {
                Some(StandardTagKey::TrackTitle) => {
                    title.get_or_insert(val);
                }
                Some(StandardTagKey::Artist) => {
                    artist.get_or_insert(val);
                }
                Some(StandardTagKey::Album) => {
                    album.get_or_insert(val);
                }
                Some(StandardTagKey::AlbumArtist) => {
                    album_artist.get_or_insert(val);
                }
                Some(StandardTagKey::Genre) => {
                    genre.get_or_insert(val);
                }
                Some(StandardTagKey::Comment) => {
                    comment.get_or_insert(val);
                }
                Some(StandardTagKey::TrackNumber) => {
                    track = track.or_else(|| val.parse().ok());
                }
                Some(StandardTagKey::DiscNumber) => {
                    disc = disc.or_else(|| val.parse().ok());
                }
                Some(StandardTagKey::Date) => {
                    year = year.or_else(|| parse_year(&val));
                }
                Some(StandardTagKey::Lyrics) => {
                    lyrics.get_or_insert(val);
                }
                _ => {}
            };
        }

        if cover.is_none() {
            for v in meta.visuals() {
                if v.data.is_empty() {
                    continue;
                }
                let mime = if v.media_type.is_empty() { "image/*" } else { v.media_type };
                cover = Some(CoverArt {
                    mime: mime.to_string(),
                    bytes: v.data.to_vec(),
                });
                break;
            }
        }
    }

    let tags = TagsJsonV1 {
        schema: "furry.tags.v1",
        original_format: format!("{:?}", original_format),
        title,
        artist,
        album,
        album_artist,
        genre,
        track,
        disc,
        year,
        comment,
        duration_ms,
        sample_rate,
        channels,
        codec,
        raw: raw_tags,
    };

    let tags_json = serde_json::to_string(&tags).ok();
    Some(ExtractedMeta {
        tags_json,
        cover,
        lyrics,
    })
}

fn parse_year(s: &str) -> Option<i32> {
    // "2024" or "2024-01-01"
    let digits: String = s.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

fn meta_value_to_string(v: &MetaValue) -> String {
    match v {
        MetaValue::Binary(b) => format!("(binary:{} bytes)", b.len()),
        MetaValue::Boolean(b) => b.to_string(),
        MetaValue::Float(f) => f.to_string(),
        MetaValue::SignedInt(i) => i.to_string(),
        MetaValue::String(s) => s.to_string(),
        MetaValue::UnsignedInt(u) => u.to_string(),
    }
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
            None,
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
            None,
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
