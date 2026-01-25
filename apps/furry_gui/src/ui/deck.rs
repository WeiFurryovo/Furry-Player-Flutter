//! 底部播放控制栏

use egui::{Align, Layout, RichText, Ui};

use crate::state::AppState;
use crate::ui::theme::FurryTheme;

pub struct PlayerDeck;

impl PlayerDeck {
    pub fn show(ui: &mut Ui, state: &mut AppState) {
        let height = 80.0;

        egui::Frame::none()
            .fill(FurryTheme::BG_SURFACE)
            .inner_margin(egui::Margin::symmetric(16.0, 12.0))
            .show(ui, |ui| {
                ui.set_min_height(height);
                ui.set_width(ui.available_width());

                ui.horizontal(|ui| {
                    let total_width = ui.available_width();
                    let side_width = 180.0;
                    let center_width = (total_width - side_width * 2.0 - 32.0).max(200.0);

                    // 左侧：曲目信息
                    ui.allocate_ui_with_layout(
                        egui::vec2(side_width, height),
                        Layout::left_to_right(Align::Center),
                        |ui| {
                            Self::track_info(ui, state);
                        },
                    );

                    ui.add_space(16.0);

                    // 中间：播放控制（使用剩余空间）
                    ui.allocate_ui_with_layout(
                        egui::vec2(center_width, height),
                        Layout::top_down(Align::Center),
                        |ui| {
                            Self::transport_controls(ui, state);
                            ui.add_space(4.0);
                            Self::seek_bar(ui, state, center_width);
                        },
                    );

                    ui.add_space(16.0);

                    // 右侧：音量控制
                    ui.allocate_ui_with_layout(
                        egui::vec2(side_width, height),
                        Layout::right_to_left(Align::Center),
                        |ui| {
                            Self::volume_control(ui, state);
                        },
                    );
                });
            });
    }

    fn track_info(ui: &mut Ui, state: &AppState) {
        ui.vertical(|ui| {
            if let Some(track) = &state.current_track {
                ui.label(
                    RichText::new(&track.title)
                        .color(FurryTheme::TEXT_PRIMARY)
                        .size(14.0),
                );
                ui.label(
                    RichText::new(&track.artist)
                        .color(FurryTheme::TEXT_MUTED)
                        .size(12.0),
                );
            } else {
                ui.label(
                    RichText::new("No track loaded")
                        .color(FurryTheme::TEXT_MUTED)
                        .size(14.0),
                );
            }
        });
    }

    fn transport_controls(ui: &mut Ui, state: &mut AppState) {
        ui.horizontal(|ui| {
            // 上一首
            if ui.button("⏮").clicked() {
                state.previous_track();
            }

            ui.add_space(8.0);

            // 播放/暂停
            let play_btn = if state.is_playing { "⏸" } else { "▶" };
            if ui
                .add(egui::Button::new(RichText::new(play_btn).size(24.0)))
                .clicked()
            {
                state.toggle_play();
            }

            ui.add_space(8.0);

            // 下一首
            if ui.button("⏭").clicked() {
                state.next_track();
            }
        });
    }

    fn seek_bar(ui: &mut Ui, state: &mut AppState, available_width: f32) {
        ui.horizontal(|ui| {
            // 当前时间
            ui.label(
                RichText::new(format_duration(state.position))
                    .color(FurryTheme::TEXT_MUTED)
                    .size(11.0),
            );

            // 进度条
            let mut progress = if state.duration > 0.0 {
                state.position / state.duration
            } else {
                0.0
            };

            let slider_width = (available_width - 100.0).max(100.0);
            let slider = egui::Slider::new(&mut progress, 0.0..=1.0)
                .show_value(false)
                .trailing_fill(true);

            let response = ui.add_sized([slider_width, 16.0], slider);

            if response.changed() {
                state.seek(progress * state.duration);
            }

            // 总时长
            ui.label(
                RichText::new(format_duration(state.duration))
                    .color(FurryTheme::TEXT_MUTED)
                    .size(11.0),
            );
        });
    }

    fn volume_control(ui: &mut Ui, state: &mut AppState) {
        ui.horizontal(|ui| {
            let icon = if state.volume > 0.5 {
                "🔊"
            } else if state.volume > 0.0 {
                "🔉"
            } else {
                "🔇"
            };
            ui.label(icon);

            let slider = egui::Slider::new(&mut state.volume, 0.0..=1.0).show_value(false);
            ui.add_sized([80.0, 16.0], slider);
        });
    }
}

fn format_duration(secs: f64) -> String {
    let mins = (secs / 60.0) as u32;
    let secs = (secs % 60.0) as u32;
    format!("{:02}:{:02}", mins, secs)
}
