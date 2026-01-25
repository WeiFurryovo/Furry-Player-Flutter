//! 播放命令和事件定义

use std::path::PathBuf;
use std::time::Duration;

/// 播放器命令（UI -> 引擎）
#[derive(Debug, Clone)]
pub enum PlayerCommand {
    /// 加载 .furry 文件
    Load(PathBuf),
    /// 播放
    Play,
    /// 暂停
    Pause,
    /// 停止
    Stop,
    /// 跳转到指定位置
    Seek(Duration),
    /// 设置音量 (0.0 - 1.0)
    SetVolume(f32),
    /// 关闭引擎
    Shutdown,
}

/// 播放器事件（引擎 -> UI）
#[derive(Debug, Clone)]
pub enum PlayerEvent {
    /// 状态变更
    StateChanged(PlaybackState),
    /// 播放进度更新
    Position(Duration),
    /// 总时长更新
    Duration(Duration),
    /// 当前曲目信息
    TrackInfo(TrackInfo),
    /// 曲目播放结束
    TrackEnded,
    /// 错误
    Error(String),
}

/// 播放状态
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PlaybackState {
    #[default]
    Idle,
    Loading,
    Playing,
    Paused,
    Stopped,
}

/// 曲目信息
#[derive(Debug, Clone, Default)]
pub struct TrackInfo {
    pub path: PathBuf,
    pub format: String,
    pub sample_rate: u32,
    pub channels: u16,
    pub duration: Duration,
}
