//! Furry Player GUI

mod state;
mod ui;

use eframe::egui;
use furry_crypto::MasterKey;
use furry_player::spawn_player;

use state::AppState;
use ui::{ConverterWindow, FurryTheme, LibrarySidebar, PlayerDeck};

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1000.0, 700.0])
            .with_min_inner_size([600.0, 400.0])
            .with_title("Furry Player"),
        ..Default::default()
    };

    eframe::run_native(
        "Furry Player",
        options,
        Box::new(|cc| {
            // 应用主题
            FurryTheme::apply(&cc.egui_ctx);

            // 启动播放引擎
            let master_key = MasterKey::default_key();
            let handle = spawn_player(master_key);

            Ok(Box::new(FurryApp::new(handle.cmd_tx, handle.evt_rx)))
        }),
    )
}

struct FurryApp {
    state: AppState,
}

impl FurryApp {
    fn new(
        cmd_tx: crossbeam_channel::Sender<furry_player::PlayerCommand>,
        evt_rx: crossbeam_channel::Receiver<furry_player::PlayerEvent>,
    ) -> Self {
        Self {
            state: AppState::new(cmd_tx, evt_rx),
        }
    }
}

impl eframe::App for FurryApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // 处理播放引擎事件
        self.state.poll_events();
        self.state.poll_converter_events();

        // 获取窗口宽度判断布局
        let available_width = ctx.screen_rect().width();
        let is_mobile = available_width < 600.0;

        // 底部播放控制栏
        egui::TopBottomPanel::bottom("player_deck")
            .resizable(false)
            .show(ctx, |ui| {
                PlayerDeck::show(ui, &mut self.state);
            });

        // 侧边栏（桌面模式）
        if !is_mobile {
            egui::SidePanel::left("library_sidebar")
                .resizable(true)
                .default_width(280.0)
                .min_width(200.0)
                .max_width(400.0)
                .show(ctx, |ui| {
                    LibrarySidebar::show(ui, &mut self.state);
                });
        }

        // 主内容区
        egui::CentralPanel::default().show(ctx, |ui| {
            if is_mobile {
                // 移动端：显示播放列表
                LibrarySidebar::show(ui, &mut self.state);
            } else {
                // 桌面端：显示正在播放
                Self::now_playing(ui, &self.state);
            }
        });

        // 转换器窗口
        if self.state.show_converter {
            ConverterWindow::show(ctx, &mut self.state);
        }

        // 如果正在播放，请求重绘以更新进度
        if self.state.is_playing {
            ctx.request_repaint_after(std::time::Duration::from_millis(100));
        }
    }
}

impl FurryApp {
    fn now_playing(ui: &mut egui::Ui, state: &AppState) {
        ui.vertical_centered(|ui| {
            ui.add_space(40.0);

            // 封面占位
            let cover_size = 300.0;
            egui::Frame::none()
                .fill(FurryTheme::BG_SURFACE)
                .rounding(egui::Rounding::same(12.0))
                .show(ui, |ui| {
                    ui.allocate_space(egui::vec2(cover_size, cover_size));
                    ui.centered_and_justified(|ui| {
                        ui.label(
                            egui::RichText::new("🎵")
                                .size(80.0)
                                .color(FurryTheme::TEXT_MUTED),
                        );
                    });
                });

            ui.add_space(24.0);

            // 曲目信息
            if let Some(track) = &state.current_track {
                ui.label(
                    egui::RichText::new(&track.title)
                        .size(24.0)
                        .color(FurryTheme::TEXT_PRIMARY)
                        .strong(),
                );
                ui.add_space(4.0);
                ui.label(
                    egui::RichText::new(&track.artist)
                        .size(16.0)
                        .color(FurryTheme::TEXT_MUTED),
                );
            } else {
                ui.label(
                    egui::RichText::new("No track playing")
                        .size(20.0)
                        .color(FurryTheme::TEXT_MUTED),
                );
                ui.add_space(8.0);
                ui.label(
                    egui::RichText::new("Select a track from the library")
                        .size(14.0)
                        .color(FurryTheme::TEXT_MUTED),
                );
            }
        });
    }
}
