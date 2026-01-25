//! 音频解码器
//!
//! 使用 symphonia 解码音频流

use std::io::{Read, Seek};
use std::time::Duration;

use symphonia::core::audio::{SampleBuffer, SignalSpec};
use symphonia::core::codecs::{Decoder, DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::{MediaSource, MediaSourceStream};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

/// 解码器错误
#[derive(thiserror::Error, Debug)]
pub enum DecoderError {
    #[error("No supported audio track found")]
    NoTrack,
    #[error("Unsupported codec")]
    UnsupportedCodec,
    #[error("Decode error: {0}")]
    Decode(String),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

impl From<SymphoniaError> for DecoderError {
    fn from(e: SymphoniaError) -> Self {
        DecoderError::Decode(e.to_string())
    }
}

/// 音频信息
#[derive(Debug, Clone)]
pub struct AudioInfo {
    pub sample_rate: u32,
    pub channels: usize,
    pub duration: Option<Duration>,
    pub codec: String,
}

/// 音频解码器
pub struct AudioDecoder {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn Decoder>,
    track_id: u32,
    spec: SignalSpec,
    sample_buf: Option<SampleBuffer<f32>>,
    pub info: AudioInfo,
}

impl AudioDecoder {
    /// 从可读流创建解码器
    pub fn new<R: Read + Seek + Send + Sync + MediaSource + 'static>(
        source: R,
        hint: Option<&str>,
    ) -> Result<Self, DecoderError> {
        let mss = MediaSourceStream::new(Box::new(source), Default::default());

        let mut probe_hint = Hint::new();
        if let Some(ext) = hint {
            probe_hint.with_extension(ext);
        }

        let probed = symphonia::default::get_probe()
            .format(
                &probe_hint,
                mss,
                &FormatOptions::default(),
                &MetadataOptions::default(),
            )
            .map_err(|e| DecoderError::Decode(e.to_string()))?;

        let format = probed.format;

        // 查找第一个音频轨道
        let track = format
            .tracks()
            .iter()
            .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
            .ok_or(DecoderError::NoTrack)?;

        let track_id = track.id;
        let codec_params = &track.codec_params;

        // 获取音频信息
        let sample_rate = codec_params.sample_rate.unwrap_or(44100);
        let channels = codec_params
            .channels
            .map(|c| c.count())
            .unwrap_or(2);

        let duration = codec_params.n_frames.map(|frames| {
            Duration::from_secs_f64(frames as f64 / sample_rate as f64)
        });

        let codec = format!("{:?}", codec_params.codec);

        let info = AudioInfo {
            sample_rate,
            channels,
            duration,
            codec,
        };

        // 创建解码器
        let decoder = symphonia::default::get_codecs()
            .make(codec_params, &DecoderOptions::default())
            .map_err(|_| DecoderError::UnsupportedCodec)?;

        let spec = SignalSpec::new(sample_rate, codec_params.channels.unwrap_or_default());

        Ok(Self {
            format,
            decoder,
            track_id,
            spec,
            sample_buf: None,
            info,
        })
    }

    /// 获取信号规格
    pub fn spec(&self) -> SignalSpec {
        self.spec
    }

    /// 解码下一帧，返回 f32 采样数据
    pub fn decode_next(&mut self) -> Result<Option<Vec<f32>>, DecoderError> {
        loop {
            let packet = match self.format.next_packet() {
                Ok(p) => p,
                Err(SymphoniaError::IoError(e))
                    if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    return Ok(None); // 文件结束
                }
                Err(e) => return Err(e.into()),
            };

            // 跳过非目标轨道
            if packet.track_id() != self.track_id {
                continue;
            }

            let decoded = match self.decoder.decode(&packet) {
                Ok(d) => d,
                Err(SymphoniaError::DecodeError(_)) => {
                    // 解码错误，尝试下一个包
                    continue;
                }
                Err(e) => return Err(e.into()),
            };

            // 转换为 f32
            let spec = *decoded.spec();
            let duration = decoded.capacity() as u64;

            if self.sample_buf.is_none()
                || self.sample_buf.as_ref().unwrap().capacity() < duration as usize
            {
                self.sample_buf = Some(SampleBuffer::new(duration, spec));
            }

            let sample_buf = self.sample_buf.as_mut().unwrap();
            sample_buf.copy_interleaved_ref(decoded);

            return Ok(Some(sample_buf.samples().to_vec()));
        }
    }

    /// 跳转到指定时间
    pub fn seek(&mut self, time: Duration) -> Result<(), DecoderError> {
        let seek_to = SeekTo::Time {
            time: symphonia::core::units::Time::from(time.as_secs_f64()),
            track_id: Some(self.track_id),
        };

        self.format
            .seek(SeekMode::Accurate, seek_to)
            .map_err(|e| DecoderError::Decode(e.to_string()))?;

        // 重置解码器状态
        self.decoder.reset();

        Ok(())
    }
}
