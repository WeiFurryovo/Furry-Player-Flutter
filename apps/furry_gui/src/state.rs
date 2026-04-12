//! 应用状态

use std::path::PathBuf;
use std::time::Instant;

use crossbeam_channel::{Receiver, Sender};
use furry_converter::{
    detect_format, inspect_furry, pack_to_furry, padding_bytes_from_kib, unpack_from_furry,
    PackOptions,
};
use furry_crypto::MasterKey;
use furry_player::{PlayerCommand, PlayerEvent};

/// 曲目信息
#[derive(Debug, Clone)]
pub struct TrackItem {
    pub path: PathBuf,
    pub title: String,
    pub artist: String,
    pub duration_str: String,
}

/// 应用状态
pub struct AppState {
    // 播放状态
    pub is_playing: bool,
    pub position: f64,
    pub duration: f64,
    pub volume: f32,

    // 播放列表
    pub playlist: Vec<TrackItem>,
    pub current_index: Option<usize>,
    pub current_track: Option<TrackItem>,

    // UI 状态
    pub search_query: String,
    pub show_converter: bool,

    // 转换器状态
    pub converter_tab: ConverterTab,
    pub pack_input_path: Option<PathBuf>,
    pub pack_output_path: Option<PathBuf>,
    pub pack_padding_kb: u64,
    pub unpack_input_path: Option<PathBuf>,
    pub unpack_output_path: Option<PathBuf>,
    pub converter_running: bool,
    pub converter_last_message: Option<String>,
    pub converter_last_ok: bool,

    // 播放引擎通信
    cmd_tx: Option<Sender<PlayerCommand>>,
    evt_rx: Option<Receiver<PlayerEvent>>,

    // 转换器任务通信
    converter_evt_tx: Sender<ConverterEvent>,
    converter_evt_rx: Receiver<ConverterEvent>,
    master_key: MasterKey,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum ConverterTab {
    #[default]
    Pack,
    Unpack,
}

#[derive(Debug, Clone)]
enum ConverterEvent {
    Finished { ok: bool, message: String },
}

impl Default for AppState {
    fn default() -> Self {
        let (converter_evt_tx, converter_evt_rx) = crossbeam_channel::bounded(8);
        Self {
            is_playing: false,
            position: 0.0,
            duration: 0.0,
            volume: 0.8,
            playlist: Vec::new(),
            current_index: None,
            current_track: None,
            search_query: String::new(),
            show_converter: false,
            converter_tab: ConverterTab::default(),
            pack_input_path: None,
            pack_output_path: None,
            pack_padding_kb: 0,
            unpack_input_path: None,
            unpack_output_path: None,
            converter_running: false,
            converter_last_message: None,
            converter_last_ok: true,
            cmd_tx: None,
            evt_rx: None,
            converter_evt_tx,
            converter_evt_rx,
            master_key: MasterKey::default_key(),
        }
    }
}

impl AppState {
    pub fn new(
        cmd_tx: Sender<PlayerCommand>,
        evt_rx: Receiver<PlayerEvent>,
        master_key: MasterKey,
    ) -> Self {
        Self {
            cmd_tx: Some(cmd_tx),
            evt_rx: Some(evt_rx),
            master_key,
            ..Default::default()
        }
    }

    /// 处理播放引擎事件
    pub fn poll_events(&mut self) {
        // 先收集所有事件
        let events: Vec<_> = if let Some(rx) = &self.evt_rx {
            rx.try_iter().collect()
        } else {
            Vec::new()
        };

        let mut should_next = false;

        for event in events {
            match event {
                PlayerEvent::StateChanged(state) => {
                    self.is_playing = state == furry_player::PlaybackState::Playing;
                }
                PlayerEvent::Position(pos) => {
                    self.position = pos.as_secs_f64();
                }
                PlayerEvent::Duration(dur) => {
                    self.duration = dur.as_secs_f64();
                }
                PlayerEvent::TrackEnded => {
                    should_next = true;
                }
                PlayerEvent::Warning(w) => {
                    eprintln!("Player warning: {}", w);
                }
                PlayerEvent::Error(e) => {
                    eprintln!("Player error: {}", e);
                }
                _ => {}
            }
        }

        if should_next {
            self.next_track();
        }
    }

    /// 处理转换器后台任务事件
    pub fn poll_converter_events(&mut self) {
        let events: Vec<_> = self.converter_evt_rx.try_iter().collect();
        for event in events {
            match event {
                ConverterEvent::Finished { ok, message } => {
                    self.converter_running = false;
                    self.converter_last_ok = ok;
                    self.converter_last_message = Some(message);
                }
            }
        }
    }

    /// 发送命令到播放引擎
    fn send_command(&self, cmd: PlayerCommand) {
        if let Some(tx) = &self.cmd_tx {
            let _ = tx.send(cmd);
        }
    }

    pub fn toggle_play(&mut self) {
        if self.is_playing {
            self.send_command(PlayerCommand::Pause);
        } else {
            self.send_command(PlayerCommand::Play);
        }
    }

    pub fn play_track(&mut self, index: usize) {
        if let Some(track) = self.playlist.get(index) {
            self.current_index = Some(index);
            self.current_track = Some(track.clone());
            self.send_command(PlayerCommand::Load(track.path.clone()));
            self.send_command(PlayerCommand::Play);
        }
    }

    pub fn next_track(&mut self) {
        if let Some(idx) = self.current_index {
            let next = (idx + 1) % self.playlist.len().max(1);
            if next < self.playlist.len() {
                self.play_track(next);
            }
        }
    }

    pub fn previous_track(&mut self) {
        if let Some(idx) = self.current_index {
            let prev = if idx == 0 {
                self.playlist.len().saturating_sub(1)
            } else {
                idx - 1
            };
            if prev < self.playlist.len() {
                self.play_track(prev);
            }
        }
    }

    pub fn seek(&mut self, position: f64) {
        self.position = position;
        self.send_command(PlayerCommand::Seek(std::time::Duration::from_secs_f64(
            position,
        )));
    }

    pub fn open_file_dialog(&mut self) {
        if let Some(paths) = rfd::FileDialog::new()
            .add_filter("Furry Audio", &["furry"])
            .add_filter("All Files", &["*"])
            .pick_files()
        {
            for path in paths {
                self.add_file(path);
            }
        }
    }

    pub fn add_file(&mut self, path: PathBuf) {
        let title = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("Unknown")
            .to_string();

        self.playlist.push(TrackItem {
            path,
            title,
            artist: "Unknown Artist".to_string(),
            duration_str: "--:--".to_string(),
        });
    }

    pub fn pick_pack_input(&mut self) {
        if let Some(path) = rfd::FileDialog::new()
            .add_filter("Audio", &["mp3", "wav", "ogg", "flac", "opus"])
            .pick_file()
        {
            self.pack_input_path = Some(path);
        }
    }

    pub fn pick_pack_output(&mut self) {
        if let Some(path) = rfd::FileDialog::new()
            .add_filter("Furry Audio", &["furry"])
            .set_file_name("output.furry")
            .save_file()
        {
            self.pack_output_path = Some(path);
        }
    }

    pub fn pick_unpack_input(&mut self) {
        if let Some(path) = rfd::FileDialog::new()
            .add_filter("Furry Audio", &["furry"])
            .pick_file()
        {
            self.unpack_input_path = Some(path);
        }
    }

    pub fn pick_unpack_output(&mut self) {
        if let Some(path) = rfd::FileDialog::new()
            .add_filter("Audio", &["mp3", "wav", "ogg", "flac"])
            .set_file_name("output")
            .save_file()
        {
            self.unpack_output_path = Some(path);
        }
    }

    pub fn start_pack(&mut self) {
        if self.converter_running {
            return;
        }

        let Some(input_path) = self.pack_input_path.clone() else {
            self.converter_last_ok = false;
            self.converter_last_message = Some("请选择输入音频文件".to_string());
            return;
        };
        let Some(output_path) = self.pack_output_path.clone() else {
            self.converter_last_ok = false;
            self.converter_last_message = Some("请选择输出 .furry 路径".to_string());
            return;
        };

        let padding_kb = self.pack_padding_kb;
        let tx = self.converter_evt_tx.clone();
        let master_key = self.master_key.clone();

        self.converter_running = true;
        self.converter_last_ok = true;
        self.converter_last_message = Some("正在打包...".to_string());

        std::thread::spawn(move || {
            let started = Instant::now();
            let result: Result<String, String> = (|| {
                if let Some(parent) = output_path.parent() {
                    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                }

                let format = detect_format(&input_path);
                let padding_bytes =
                    padding_bytes_from_kib(padding_kb).map_err(|e| e.to_string())?;
                let options = PackOptions {
                    padding_bytes,
                    ..Default::default()
                };

                let mut input = std::fs::File::open(&input_path).map_err(|e| e.to_string())?;
                let mut output = std::fs::File::create(&output_path).map_err(|e| e.to_string())?;
                pack_to_furry(
                    &mut input,
                    &mut output,
                    Some(&input_path),
                    format,
                    &master_key,
                    &options,
                )
                .map_err(|e| e.to_string())?;

                let input_size = std::fs::metadata(&input_path)
                    .map(|m| m.len())
                    .map_err(|e| e.to_string())?;
                let output_size = std::fs::metadata(&output_path)
                    .map(|m| m.len())
                    .map_err(|e| e.to_string())?;

                Ok(format!(
                    "打包完成：\n- 格式: {:?}\n- 输入: {} bytes\n- 输出: {} bytes\n- 比例: {:.2}x\n- 耗时: {:?}\n- 输出文件: {}",
                    format,
                    input_size,
                    output_size,
                    output_size as f64 / input_size.max(1) as f64,
                    started.elapsed(),
                    output_path.display()
                ))
            })();

            let _ = match result {
                Ok(message) => tx.send(ConverterEvent::Finished { ok: true, message }),
                Err(err) => tx.send(ConverterEvent::Finished {
                    ok: false,
                    message: format!("打包失败：{}", err),
                }),
            };
        });
    }

    pub fn start_unpack(&mut self) {
        if self.converter_running {
            return;
        }

        let Some(input_path) = self.unpack_input_path.clone() else {
            self.converter_last_ok = false;
            self.converter_last_message = Some("请选择输入 .furry 文件".to_string());
            return;
        };
        let Some(output_path) = self.unpack_output_path.clone() else {
            self.converter_last_ok = false;
            self.converter_last_message = Some("请选择输出文件路径".to_string());
            return;
        };

        let tx = self.converter_evt_tx.clone();
        let master_key = self.master_key.clone();

        self.converter_running = true;
        self.converter_last_ok = true;
        self.converter_last_message = Some("正在解包...".to_string());

        std::thread::spawn(move || {
            let started = Instant::now();
            let result: Result<String, String> = (|| {
                let mut input = std::fs::File::open(&input_path).map_err(|e| e.to_string())?;
                let _ = inspect_furry(&mut input, &master_key).map_err(|e| e.to_string())?;
                if let Some(parent) = output_path.parent() {
                    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                }
                let mut output = std::fs::File::create(&output_path).map_err(|e| e.to_string())?;
                let format = unpack_from_furry(&mut input, &mut output, &master_key)
                    .map_err(|e| e.to_string())?;

                let output_size = std::fs::metadata(&output_path)
                    .map(|m| m.len())
                    .map_err(|e| e.to_string())?;

                Ok(format!(
                    "解包完成：\n- 原始格式: {:?}\n- 输出: {} bytes\n- 耗时: {:?}\n- 输出文件: {}",
                    format,
                    output_size,
                    started.elapsed(),
                    output_path.display()
                ))
            })();

            let _ = match result {
                Ok(message) => tx.send(ConverterEvent::Finished { ok: true, message }),
                Err(err) => tx.send(ConverterEvent::Finished {
                    ok: false,
                    message: format!("解包失败：{}", err),
                }),
            };
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use furry_player::PlaybackState;

    fn sample_track(name: &str) -> TrackItem {
        TrackItem {
            path: PathBuf::from(format!("/tmp/{name}.furry")),
            title: name.to_string(),
            artist: "tester".to_string(),
            duration_str: "00:10".to_string(),
        }
    }

    #[test]
    fn track_ended_event_advances_playlist_and_sends_commands() {
        let (cmd_tx, cmd_rx) = crossbeam_channel::unbounded();
        let (evt_tx, evt_rx) = crossbeam_channel::unbounded();
        let mut state = AppState::new(cmd_tx, evt_rx, MasterKey::default_key());
        let first = sample_track("first");
        let second = sample_track("second");
        state.playlist = vec![first.clone(), second.clone()];
        state.current_index = Some(0);
        state.current_track = Some(first);

        evt_tx
            .send(PlayerEvent::StateChanged(PlaybackState::Playing))
            .unwrap();
        evt_tx.send(PlayerEvent::TrackEnded).unwrap();

        state.poll_events();

        assert_eq!(state.current_index, Some(1));
        assert_eq!(
            state
                .current_track
                .as_ref()
                .map(|track| track.title.as_str()),
            Some("second")
        );
        assert!(state.is_playing);

        let commands: Vec<_> = cmd_rx.try_iter().collect();
        assert_eq!(commands.len(), 2);
        match &commands[0] {
            PlayerCommand::Load(path) => assert_eq!(path, &second.path),
            other => panic!("unexpected first command: {other:?}"),
        }
        assert!(matches!(commands[1], PlayerCommand::Play));
    }

    #[test]
    fn converter_validation_rejects_missing_pack_input() {
        let mut state = AppState::default();
        state.pack_output_path = Some(PathBuf::from("/tmp/output.furry"));

        state.start_pack();

        assert!(!state.converter_running);
        assert!(!state.converter_last_ok);
        assert_eq!(
            state.converter_last_message.as_deref(),
            Some("请选择输入音频文件")
        );
    }

    #[test]
    fn poll_converter_events_applies_backend_result() {
        let mut state = AppState::default();
        state.converter_running = true;
        state
            .converter_evt_tx
            .send(ConverterEvent::Finished {
                ok: false,
                message: "解包失败：bad file".to_string(),
            })
            .unwrap();

        state.poll_converter_events();

        assert!(!state.converter_running);
        assert!(!state.converter_last_ok);
        assert_eq!(
            state.converter_last_message.as_deref(),
            Some("解包失败：bad file")
        );
    }
}
