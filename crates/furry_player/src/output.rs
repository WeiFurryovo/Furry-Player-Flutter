//! 音频输出
//!
//! 使用 cpal 进行音频播放

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Device, SampleFormat, Stream, StreamConfig};
use crossbeam_channel::{Sender, bounded};

/// 音频输出错误
#[derive(thiserror::Error, Debug)]
pub enum OutputError {
    #[error("No output device available")]
    NoDevice,
    #[error("No supported config")]
    NoConfig,
    #[error("Stream error: {0}")]
    Stream(String),
}

/// 音频输出配置
#[derive(Debug, Clone)]
pub struct OutputConfig {
    pub sample_rate: u32,
    pub channels: u16,
    pub buffer_size: usize,
}

impl Default for OutputConfig {
    fn default() -> Self {
        Self {
            sample_rate: 44100,
            channels: 2,
            buffer_size: 4096,
        }
    }
}

/// 音频输出流
pub struct AudioOutput {
    _stream: Stream,
    sample_tx: Sender<Vec<f32>>,
    is_playing: Arc<AtomicBool>,
    position_samples: Arc<AtomicU64>,
    sample_rate: u32,
    channels: u16,
}

impl AudioOutput {
    /// 创建音频输出
    pub fn new(config: OutputConfig) -> Result<Self, OutputError> {
        let host = cpal::default_host();
        let device = host
            .default_output_device()
            .ok_or(OutputError::NoDevice)?;

        Self::with_device(&device, config)
    }

    /// 使用指定设备创建音频输出
    pub fn with_device(device: &Device, config: OutputConfig) -> Result<Self, OutputError> {
        let supported_config = device
            .supported_output_configs()
            .map_err(|e| OutputError::Stream(e.to_string()))?
            .find(|c| {
                c.channels() == config.channels
                    && c.min_sample_rate().0 <= config.sample_rate
                    && c.max_sample_rate().0 >= config.sample_rate
                    && c.sample_format() == SampleFormat::F32
            })
            .ok_or(OutputError::NoConfig)?;

        let stream_config: StreamConfig = supported_config
            .with_sample_rate(cpal::SampleRate(config.sample_rate))
            .into();

        let (sample_tx, sample_rx) = bounded::<Vec<f32>>(32);
        let is_playing = Arc::new(AtomicBool::new(false));
        let position_samples = Arc::new(AtomicU64::new(0));

        let is_playing_clone = is_playing.clone();
        let position_clone = position_samples.clone();
        let channels = config.channels as usize;

        // 创建环形缓冲区
        let ring_buffer = Arc::new(RingBuffer::new(config.buffer_size * 4));
        let ring_clone = ring_buffer.clone();

        // 启动填充线程
        std::thread::spawn(move || {
            while let Ok(samples) = sample_rx.recv() {
                ring_clone.write(&samples);
            }
        });

        let stream = device
            .build_output_stream(
                &stream_config,
                move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                    if is_playing_clone.load(Ordering::Relaxed) {
                        let read = ring_buffer.read(data);
                        // 填充未读取部分为静音
                        for sample in &mut data[read..] {
                            *sample = 0.0;
                        }
                        // 更新位置
                        position_clone.fetch_add((read / channels) as u64, Ordering::Relaxed);
                    } else {
                        // 暂停时输出静音
                        for sample in data.iter_mut() {
                            *sample = 0.0;
                        }
                    }
                },
                |err| {
                    eprintln!("Audio output error: {}", err);
                },
                None,
            )
            .map_err(|e| OutputError::Stream(e.to_string()))?;

        stream.play().map_err(|e| OutputError::Stream(e.to_string()))?;

        Ok(Self {
            _stream: stream,
            sample_tx,
            is_playing,
            position_samples,
            sample_rate: config.sample_rate,
            channels: config.channels,
        })
    }

    /// 写入采样数据
    pub fn write(&self, samples: Vec<f32>) -> bool {
        self.sample_tx.try_send(samples).is_ok()
    }

    /// 设置播放状态
    pub fn set_playing(&self, playing: bool) {
        self.is_playing.store(playing, Ordering::Relaxed);
    }

    /// 获取当前播放位置（秒）
    pub fn position(&self) -> f64 {
        let samples = self.position_samples.load(Ordering::Relaxed);
        samples as f64 / self.sample_rate as f64
    }

    /// 重置位置
    pub fn reset_position(&self) {
        self.position_samples.store(0, Ordering::Relaxed);
    }

    /// 获取采样率
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// 获取声道数
    pub fn channels(&self) -> u16 {
        self.channels
    }
}

/// 简单的环形缓冲区
struct RingBuffer {
    buffer: std::sync::Mutex<VecDeque<f32>>,
    capacity: usize,
}

impl RingBuffer {
    fn new(capacity: usize) -> Self {
        Self {
            buffer: std::sync::Mutex::new(VecDeque::with_capacity(capacity)),
            capacity,
        }
    }

    fn write(&self, data: &[f32]) {
        let mut buf = self.buffer.lock().unwrap();
        if data.len() >= self.capacity {
            buf.clear();
            buf.extend(data[data.len() - self.capacity..].iter().copied());
            return;
        }

        // 如果缓冲区满了，丢弃旧数据
        let needed = buf.len() + data.len();
        if needed > self.capacity {
            let drain_count = needed - self.capacity;
            buf.drain(..drain_count);
        }

        buf.extend(data.iter().copied());
    }

    fn read(&self, output: &mut [f32]) -> usize {
        let mut buf = self.buffer.lock().unwrap();
        let to_read = output.len().min(buf.len());

        let (a, b) = buf.as_slices();
        let a_len = a.len().min(to_read);
        output[..a_len].copy_from_slice(&a[..a_len]);
        let b_len = to_read - a_len;
        if b_len > 0 {
            output[a_len..to_read].copy_from_slice(&b[..b_len]);
        }

        buf.drain(..to_read);
        to_read
    }
}
