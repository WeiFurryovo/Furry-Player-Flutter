//! 播放引擎

use std::path::PathBuf;
use std::thread;
use std::time::Duration;

use crossbeam_channel::{bounded, Receiver, Sender};
use furry_crypto::MasterKey;

use crate::{
    AudioDecoder, AudioOutput, OutputConfig, PlaybackState, PlayerCommand, PlayerEvent, TrackInfo,
    VirtualAudioStream,
};

/// 播放引擎句柄
pub struct PlayerHandle {
    pub cmd_tx: Sender<PlayerCommand>,
    pub evt_rx: Receiver<PlayerEvent>,
}

/// 启动播放引擎
pub fn spawn_player(master_key: MasterKey) -> PlayerHandle {
    let (cmd_tx, cmd_rx) = bounded(32);
    let (evt_tx, evt_rx) = bounded(64);

    thread::spawn(move || {
        run_engine(cmd_rx, evt_tx, master_key);
    });

    PlayerHandle { cmd_tx, evt_rx }
}

fn run_engine(cmd_rx: Receiver<PlayerCommand>, evt_tx: Sender<PlayerEvent>, master_key: MasterKey) {
    let mut state = EngineState::new(master_key, evt_tx);

    let _ = state
        .evt_tx
        .send(PlayerEvent::StateChanged(PlaybackState::Idle));

    loop {
        // 非阻塞检查命令
        match cmd_rx.try_recv() {
            Ok(cmd) => {
                if !state.handle_command(cmd) {
                    break;
                }
            }
            Err(crossbeam_channel::TryRecvError::Empty) => {}
            Err(crossbeam_channel::TryRecvError::Disconnected) => break,
        }

        // 如果正在播放，更新进度并解码
        if state.playback_state == PlaybackState::Playing {
            state.decode_and_play();
            state.update_position();
        }

        // 避免 CPU 空转
        thread::sleep(Duration::from_millis(5));
    }
}

struct EngineState {
    master_key: MasterKey,
    evt_tx: Sender<PlayerEvent>,
    playback_state: PlaybackState,
    current_track: Option<LoadedTrack>,
    volume: f32,
    position_base: Duration,
    last_position_update: std::time::Instant,
}

struct LoadedTrack {
    decoder: AudioDecoder,
    output: AudioOutput,
}

impl EngineState {
    fn new(master_key: MasterKey, evt_tx: Sender<PlayerEvent>) -> Self {
        Self {
            master_key,
            evt_tx,
            playback_state: PlaybackState::Idle,
            current_track: None,
            volume: 1.0,
            position_base: Duration::ZERO,
            last_position_update: std::time::Instant::now(),
        }
    }

    fn handle_command(&mut self, cmd: PlayerCommand) -> bool {
        match cmd {
            PlayerCommand::Load(path) => {
                self.load_track(path);
            }
            PlayerCommand::Play => {
                self.play();
            }
            PlayerCommand::Pause => {
                self.pause();
            }
            PlayerCommand::Stop => {
                self.stop();
            }
            PlayerCommand::Seek(pos) => {
                self.seek(pos);
            }
            PlayerCommand::SetVolume(vol) => {
                self.volume = vol.clamp(0.0, 1.0);
            }
            PlayerCommand::Shutdown => {
                return false;
            }
        }
        true
    }

    fn load_track(&mut self, path: PathBuf) {
        self.set_state(PlaybackState::Loading);
        self.position_base = Duration::ZERO;

        // 停止当前播放
        if let Some(track) = self.current_track.take() {
            track.output.set_playing(false);
        }

        // 尝试打开 .furry 文件
        let stream = match VirtualAudioStream::open(&path, &self.master_key) {
            Ok(s) => s,
            Err(e) => {
                let _ = self
                    .evt_tx
                    .send(PlayerEvent::Error(format!("Failed to open file: {}", e)));
                self.set_state(PlaybackState::Idle);
                return;
            }
        };

        // 获取原始格式作为解码提示
        let format_hint = match stream.original_format() {
            furry_format::OriginalFormat::Mp3 => Some("mp3"),
            furry_format::OriginalFormat::Ogg => Some("ogg"),
            furry_format::OriginalFormat::Flac => Some("flac"),
            furry_format::OriginalFormat::Wav => Some("wav"),
            _ => None,
        };

        // 创建解码器
        let decoder = match AudioDecoder::new(stream, format_hint) {
            Ok(d) => d,
            Err(e) => {
                let _ = self
                    .evt_tx
                    .send(PlayerEvent::Error(format!("Failed to decode: {}", e)));
                self.set_state(PlaybackState::Idle);
                return;
            }
        };

        let info = &decoder.info;
        let duration = info.duration.unwrap_or(Duration::ZERO);

        // 创建音频输出
        let output_config = OutputConfig {
            sample_rate: info.sample_rate,
            channels: info.channels as u16,
            buffer_size: 8192,
        };

        let output = match AudioOutput::new(output_config) {
            Ok(o) => o,
            Err(e) => {
                let _ = self
                    .evt_tx
                    .send(PlayerEvent::Error(format!("Audio output error: {}", e)));
                self.set_state(PlaybackState::Idle);
                return;
            }
        };

        // 发送曲目信息
        let track_info = TrackInfo {
            path: path.clone(),
            format: info.codec.clone(),
            sample_rate: info.sample_rate,
            channels: info.channels as u16,
            duration,
        };

        let _ = self.evt_tx.send(PlayerEvent::TrackInfo(track_info));
        let _ = self.evt_tx.send(PlayerEvent::Duration(duration));

        self.current_track = Some(LoadedTrack { decoder, output });

        self.set_state(PlaybackState::Paused);
    }

    fn play(&mut self) {
        if let Some(track) = &self.current_track {
            if self.playback_state != PlaybackState::Playing {
                track.output.set_playing(true);
                self.set_state(PlaybackState::Playing);
            }
        }
    }

    fn pause(&mut self) {
        if let Some(track) = &self.current_track {
            if self.playback_state == PlaybackState::Playing {
                track.output.set_playing(false);
                self.set_state(PlaybackState::Paused);
            }
        }
    }

    fn stop(&mut self) {
        if let Some(track) = self.current_track.take() {
            track.output.set_playing(false);
        }
        self.position_base = Duration::ZERO;
        self.set_state(PlaybackState::Stopped);
    }

    fn seek(&mut self, pos: Duration) {
        if let Some(track) = &mut self.current_track {
            if let Err(e) = track.decoder.seek(pos) {
                let _ = self
                    .evt_tx
                    .send(PlayerEvent::Error(format!("Seek error: {}", e)));
            } else {
                track.output.reset_position();
                self.position_base = pos;
                let _ = self.evt_tx.send(PlayerEvent::Position(pos));
            }
        }
    }

    fn decode_and_play(&mut self) {
        if let Some(track) = &mut self.current_track {
            // 解码并发送到输出
            match track.decoder.decode_next() {
                Ok(Some(samples)) => {
                    // 应用音量
                    let mut samples = samples;
                    for sample in &mut samples {
                        *sample *= self.volume;
                    }

                    track.output.write(samples);
                }
                Ok(None) => {
                    // 播放结束
                    track.output.set_playing(false);
                    self.set_state(PlaybackState::Stopped);
                    let _ = self.evt_tx.send(PlayerEvent::TrackEnded);
                }
                Err(e) => {
                    let _ = self
                        .evt_tx
                        .send(PlayerEvent::Error(format!("Decode error: {}", e)));
                }
            }
        }
    }

    fn update_position(&mut self) {
        // 每 100ms 更新一次位置
        if self.last_position_update.elapsed() >= Duration::from_millis(100) {
            if let Some(track) = &self.current_track {
                let pos = track.output.position();
                let pos = self.position_base + Duration::from_secs_f64(pos);
                let _ = self.evt_tx.send(PlayerEvent::Position(pos));
            }
            self.last_position_update = std::time::Instant::now();
        }
    }

    fn set_state(&mut self, state: PlaybackState) {
        if self.playback_state != state {
            self.playback_state = state;
            let _ = self.evt_tx.send(PlayerEvent::StateChanged(state));
        }
    }
}
