//! 侧边栏 - 播放列表

use egui::{RichText, ScrollArea, Ui};

use crate::state::AppState;
use crate::ui::theme::FurryTheme;

pub struct LibrarySidebar;

impl LibrarySidebar {
    pub fn show(ui: &mut Ui, state: &mut AppState) {
        egui::Frame::none()
            .fill(FurryTheme::BG_SURFACE)
            .inner_margin(egui::Margin::same(12.0))
            .show(ui, |ui| {
                ui.vertical(|ui| {
                    // 标题
                    ui.horizontal(|ui| {
                        ui.label(
                            RichText::new("Library")
                                .color(FurryTheme::TEXT_PRIMARY)
                                .size(18.0)
                                .strong(),
                        );

                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            if ui.button("🔄").on_hover_text("Converter").clicked() {
                                state.show_converter = true;
                            }
                            if ui.button("➕").on_hover_text("Add files").clicked() {
                                state.open_file_dialog();
                            }
                        });
                    });

                    ui.add_space(12.0);

                    // 搜索框
                    ui.horizontal(|ui| {
                        ui.label("🔍");
                        ui.add(
                            egui::TextEdit::singleline(&mut state.search_query)
                                .hint_text("Search...")
                                .desired_width(ui.available_width()),
                        );
                    });

                    ui.add_space(12.0);
                    ui.separator();
                    ui.add_space(8.0);

                    // 播放列表
                    ScrollArea::vertical()
                        .auto_shrink([false, false])
                        .show(ui, |ui| {
                            Self::playlist(ui, state);
                        });
                });
            });
    }

    fn playlist(ui: &mut Ui, state: &mut AppState) {
        // 先收集过滤后的索引和数据
        let filtered: Vec<(usize, String, String, String)> = state
            .playlist
            .iter()
            .enumerate()
            .filter(|(_, track)| {
                state.search_query.is_empty()
                    || track
                        .title
                        .to_lowercase()
                        .contains(&state.search_query.to_lowercase())
                    || track
                        .artist
                        .to_lowercase()
                        .contains(&state.search_query.to_lowercase())
            })
            .map(|(idx, track)| {
                (
                    idx,
                    track.title.clone(),
                    track.artist.clone(),
                    track.duration_str.clone(),
                )
            })
            .collect();

        if filtered.is_empty() {
            ui.vertical_centered(|ui| {
                ui.add_space(40.0);
                ui.label(
                    RichText::new("No tracks")
                        .color(FurryTheme::TEXT_MUTED)
                        .size(14.0),
                );
                ui.add_space(8.0);
                ui.label(
                    RichText::new("Click + to add .furry files")
                        .color(FurryTheme::TEXT_MUTED)
                        .size(12.0),
                );
            });
            return;
        }

        let current_index = state.current_index;
        let mut clicked_idx: Option<usize> = None;

        for (idx, title, artist, duration_str) in &filtered {
            let is_current = current_index == Some(*idx);

            let bg_color = if is_current {
                FurryTheme::ACCENT_PRIMARY.gamma_multiply(0.2)
            } else {
                FurryTheme::BG_SURFACE
            };

            egui::Frame::none()
                .fill(bg_color)
                .rounding(egui::Rounding::same(6.0))
                .inner_margin(egui::Margin::symmetric(8.0, 6.0))
                .show(ui, |ui| {
                    let response = ui
                        .horizontal(|ui| {
                            ui.vertical(|ui| {
                                ui.label(
                                    RichText::new(title)
                                        .color(if is_current {
                                            FurryTheme::ACCENT_PRIMARY
                                        } else {
                                            FurryTheme::TEXT_PRIMARY
                                        })
                                        .size(13.0),
                                );
                                ui.label(
                                    RichText::new(artist)
                                        .color(FurryTheme::TEXT_MUTED)
                                        .size(11.0),
                                );
                            });

                            ui.with_layout(
                                egui::Layout::right_to_left(egui::Align::Center),
                                |ui| {
                                    ui.label(
                                        RichText::new(duration_str)
                                            .color(FurryTheme::TEXT_MUTED)
                                            .size(11.0),
                                    );
                                },
                            );
                        })
                        .response;

                    if response.interact(egui::Sense::click()).clicked() {
                        clicked_idx = Some(*idx);
                    }
                });

            ui.add_space(2.0);
        }

        // 处理点击
        if let Some(idx) = clicked_idx {
            state.play_track(idx);
        }
    }
}
