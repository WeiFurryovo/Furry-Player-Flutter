# Furry Player 开发计划

## 项目概述

开发自定义加密音频格式 `.furry` 及其专属播放器。

### 技术栈
- **语言**: Rust
- **GUI**: egui/eframe
- **平台**: Linux / Windows / Android
- **加密**: AES-256-GCM + HKDF + 混淆层

---

## 一、文件格式规格 (.furry v1)

### 1.1 文件结构

```
┌─────────────────────────────────────────┐
│ FURRY_HEADER (96 bytes)                 │
├─────────────────────────────────────────┤
│ FAKE_HEADER (fake_header_len bytes)     │
├─────────────────────────────────────────┤
│ AUDIO CHUNKS [0..N]                     │
├─────────────────────────────────────────┤
│ META CHUNKS (封面/歌词/标签)            │
├─────────────────────────────────────────┤
│ PADDING CHUNKS (负压缩率)               │
├─────────────────────────────────────────┤
│ INDEX CHUNK (必须最后)                  │
└─────────────────────────────────────────┘
```

### 1.2 主文件头 (FurryHeaderV1, 96 bytes)

| Offset | Size | 字段 | 说明 |
|--------|------|------|------|
| 0x00 | 8 | magic | `"FURRYFMT"` |
| 0x08 | 2 | version | `1` |
| 0x0A | 2 | header_size | `96` |
| 0x0C | 4 | flags | 标志位 |
| 0x10 | 4 | fake_header_len | 假头部长度 |
| 0x18 | 16 | file_id | 文件唯一 ID |
| 0x28 | 16 | salt | HKDF salt |
| 0x38 | 2 | kdf_id | `1` = HKDF-SHA256 |
| 0x3A | 2 | aead_id | `1` = AES-256-GCM |
| 0x3C | 2 | chunk_header_version | `1` |
| 0x40 | 8 | index_offset | INDEX chunk 偏移 |
| 0x48 | 4 | index_total_len | INDEX 总长度 |
| 0x4C | 4 | header_crc32 | 头部校验 |

### 1.3 Chunk 结构 (ChunkRecordHeaderV1, 40 bytes)

| Offset | Size | 字段 | 说明 |
|--------|------|------|------|
| 0x00 | 4 | magic | `"FRCK"` |
| 0x04 | 2 | header_len | `40` |
| 0x06 | 2 | header_version | `1` |
| 0x08 | 1 | chunk_type | AUDIO=1, INDEX=2, META=3, PADDING=4 |
| 0x09 | 1 | chunk_flags | 标志位 |
| 0x0C | 8 | chunk_seq | 序号 (nonce 派生) |
| 0x14 | 8 | virtual_offset | 虚拟音频流偏移 |
| 0x1C | 4 | plain_len | 明文长度 |

Chunk 数据: `[header 40B] [ciphertext plain_len B] [tag 16B]`

### 1.4 加密方案

```
主密钥 (MASTER_KEY, 32B, 硬编码)
    │
    ├─ HKDF(salt) ─→ aead_key (32B)
    ├─ HKDF(salt) ─→ nonce_prefix (4B)
    └─ HKDF(salt) ─→ meta_xor_key (32B)

Nonce = nonce_prefix (4B) || chunk_seq_le (8B)

AAD = "FURRYAAD" || header_version || header_flags || file_id || chunk_header_bytes
```

---

## 二、项目结构

```
furry-player/
├── Cargo.toml                 # workspace
├── docs/
│   └── format-spec.md         # 格式规格文档
├── crates/
│   ├── furry_crypto/          # 加密模块
│   │   └── src/lib.rs
│   ├── furry_format/          # 格式读写
│   │   └── src/lib.rs
│   ├── furry_player/          # 播放引擎
│   │   └── src/lib.rs
│   └── furry_converter/       # 格式转换
│       └── src/lib.rs
└── apps/
    └── furry_gui/             # GUI 应用
        └── src/
            ├── main.rs
            ├── app.rs         # AppState
            ├── ui/
            │   ├── mod.rs
            │   ├── sidebar.rs
            │   ├── stage.rs
            │   ├── deck.rs
            │   └── theme.rs
            └── views/
                ├── library.rs
                ├── now_playing.rs
                ├── converter.rs
                └── settings.rs
```

---

## 三、核心模块

### 3.1 furry_crypto
- `MasterKey`: 主密钥封装
- `FileKeys`: 派生密钥组
- `derive_file_keys()`: HKDF 派生
- `encrypt_in_place_detached()`: AES-GCM 加密
- `decrypt_in_place_detached()`: AES-GCM 解密
- `xor_meta_in_place()`: META 混淆

### 3.2 furry_format
- `FurryHeaderV1`: 文件头读写
- `ChunkRecordHeaderV1`: Chunk 头读写
- `FurryIndexV1`: 索引解析
- `FurryReader`: 读取器
- `FurryWriter`: 写入器

### 3.3 furry_player
- `PlayerCommand`: 播放命令枚举
- `PlayerEvent`: 播放事件枚举
- `PlayerHandle`: 线程通信句柄
- `spawn_player()`: 启动播放引擎

### 3.4 furry_converter
- `pack_passthrough_to_furry()`: 封装为 .furry
- `unpack_furry_to_passthrough()`: 导出原始流

---

## 四、GUI 架构

### 4.1 状态结构

```rust
pub struct AppState {
    pub player: PlayerState,
    pub playlist: PlaylistState,
    pub ui: UiState,
    pub converter: ConverterState,
    pub audio_command_tx: Sender<AudioCommand>,
    pub audio_event_rx: Receiver<AudioEvent>,
}
```

### 4.2 组件层次

```
AppRoot
├── TopBar (导航)
├── CentralPanel
│   ├── LibrarySidebar (桌面)
│   └── MainStage
│       └── Router
│           ├── Library
│           ├── NowPlaying
│           ├── Converter
│           └── Settings
└── PlayerDeck (底部控制栏)
```

### 4.3 主题配色

| 用途 | 颜色 |
|------|------|
| 背景 | `#121218` |
| 表面 | `#1E1E26` |
| 主色 | `#FF6432` |
| 辅色 | `#32C8B4` |
| 文字 | `#F0F0F0` |
| 次要文字 | `#9696A0` |

### 4.4 响应式断点

- **桌面** (>800px): 三栏布局
- **平板** (500-800px): 可折叠侧边栏
- **移动** (<500px): 单栏 + 迷你播放器

---

## 五、实施阶段

### Phase 1: 核心格式库
1. [ ] 初始化 Cargo workspace
2. [ ] 实现 furry_crypto 模块
3. [ ] 实现 furry_format 读写
4. [ ] 单元测试：加密/解密往返

### Phase 2: 转换器
5. [ ] 实现 pack_passthrough_to_furry
6. [ ] 实现 unpack_furry_to_passthrough
7. [ ] CLI 测试工具

### Phase 3: 播放引擎
8. [ ] 实现虚拟音频流 (VirtualAudioStream)
9. [ ] 集成 symphonia 解码
10. [ ] 集成 cpal 输出
11. [ ] 线程模型与通道通信

### Phase 4: GUI 应用
12. [ ] 搭建 egui/eframe 框架
13. [ ] 实现主题系统
14. [ ] 实现响应式布局
15. [ ] 实现各视图组件
16. [ ] 集成播放引擎

### Phase 5: 平台适配
17. [ ] Linux 构建测试
18. [ ] Windows 交叉编译
19. [ ] Android NDK 集成

---

## 六、依赖清单

```toml
[workspace.dependencies]
# 加密
aes-gcm = "0.10"
hkdf = "0.12"
sha2 = "0.10"
blake3 = "1.5"
zeroize = "1.7"

# 格式
byteorder = "1.5"

# 音频
symphonia = { version = "0.5", features = ["mp3", "ogg", "flac", "wav"] }
cpal = "0.15"

# GUI
eframe = "0.29"
egui = "0.29"

# 工具
thiserror = "2.0"
crossbeam-channel = "0.5"
```

---

## 七、风险与缓解

| 风险 | 缓解措施 |
|------|----------|
| Android cpal 兼容性 | 先完成桌面版，Android 单独验证 |
| 大文件 seek 性能 | 索引表设计支持快速定位 |
| 密钥泄露 | 仅防普通用户，不防逆向 |

---

**计划生成时间**: 2026-01-14
**SESSION_ID**:
- Codex: `019bba65-4679-7511-b965-c8f9f5c34a4a`
- Gemini: `0e09a2b4-3ea6-4711-8bc5-b84300572d5b`
