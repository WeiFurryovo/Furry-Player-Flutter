//! 转换器窗口（打包/解包）

use egui::{RichText, Ui};

use crate::state::{AppState, ConverterTab};
use crate::ui::theme::FurryTheme;

pub struct ConverterWindow;

impl ConverterWindow {
    pub fn show(ctx: &egui::Context, state: &mut AppState) {
        let mut open = state.show_converter;

        egui::Window::new("Converter")
            .open(&mut open)
            .default_width(520.0)
            .resizable(true)
            .collapsible(false)
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    ui.selectable_value(&mut state.converter_tab, ConverterTab::Pack, "Pack");
                    ui.selectable_value(&mut state.converter_tab, ConverterTab::Unpack, "Unpack");

                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if state.converter_running {
                            ui.add(egui::Spinner::new());
                        }
                    });
                });

                ui.add_space(8.0);
                ui.separator();
                ui.add_space(8.0);

                match state.converter_tab {
                    ConverterTab::Pack => Self::pack_ui(ui, state),
                    ConverterTab::Unpack => Self::unpack_ui(ui, state),
                }

                if let Some(msg) = state.converter_last_message.as_deref() {
                    ui.add_space(12.0);
                    ui.separator();
                    ui.add_space(8.0);
                    ui.label(
                        RichText::new(msg)
                            .color(if state.converter_last_ok {
                                FurryTheme::ACCENT_SECONDARY
                            } else {
                                FurryTheme::ACCENT_PRIMARY
                            })
                            .size(12.0),
                    );
                }
            });

        state.show_converter = open;
    }

    fn pack_ui(ui: &mut Ui, state: &mut AppState) {
        ui.label(RichText::new("Input audio").color(FurryTheme::TEXT_MUTED));
        let input_path = state.pack_input_path.clone();
        Self::path_row(
            ui,
            input_path.as_deref(),
            state.converter_running,
            "Choose...",
            || state.pick_pack_input(),
        );

        ui.add_space(8.0);

        ui.label(RichText::new("Output .furry").color(FurryTheme::TEXT_MUTED));
        let output_path = state.pack_output_path.clone();
        Self::path_row(
            ui,
            output_path.as_deref(),
            state.converter_running,
            "Save as...",
            || state.pick_pack_output(),
        );

        ui.add_space(12.0);

        ui.horizontal(|ui| {
            ui.label(RichText::new("Padding (KB)").color(FurryTheme::TEXT_MUTED));
            ui.add(egui::DragValue::new(&mut state.pack_padding_kb).range(0..=1024 * 1024));
            ui.add_space(8.0);
            ui.label(
                RichText::new("0 = no padding")
                    .color(FurryTheme::TEXT_MUTED)
                    .size(11.0),
            );
        });

        ui.add_space(12.0);

        let can_start = !state.converter_running
            && state.pack_input_path.is_some()
            && state.pack_output_path.is_some();
        ui.add_enabled_ui(can_start, |ui| {
            if ui
                .add_sized(
                    [ui.available_width(), 36.0],
                    egui::Button::new("Start pack"),
                )
                .clicked()
            {
                state.start_pack();
            }
        });
    }

    fn unpack_ui(ui: &mut Ui, state: &mut AppState) {
        ui.label(RichText::new("Input .furry").color(FurryTheme::TEXT_MUTED));
        let input_path = state.unpack_input_path.clone();
        Self::path_row(
            ui,
            input_path.as_deref(),
            state.converter_running,
            "Choose...",
            || state.pick_unpack_input(),
        );

        ui.add_space(8.0);

        ui.label(RichText::new("Output file").color(FurryTheme::TEXT_MUTED));
        let output_path = state.unpack_output_path.clone();
        Self::path_row(
            ui,
            output_path.as_deref(),
            state.converter_running,
            "Save as...",
            || state.pick_unpack_output(),
        );

        ui.add_space(12.0);

        let can_start = !state.converter_running
            && state.unpack_input_path.is_some()
            && state.unpack_output_path.is_some();
        ui.add_enabled_ui(can_start, |ui| {
            if ui
                .add_sized(
                    [ui.available_width(), 36.0],
                    egui::Button::new("Start unpack"),
                )
                .clicked()
            {
                state.start_unpack();
            }
        });
    }

    fn path_row(
        ui: &mut Ui,
        path: Option<&std::path::Path>,
        disabled: bool,
        button_text: &str,
        mut on_pick: impl FnMut(),
    ) {
        ui.horizontal(|ui| {
            let text = path.and_then(|p| p.to_str()).unwrap_or("Not selected");
            let mut display = text.to_string();
            ui.add(
                egui::TextEdit::singleline(&mut display)
                    .desired_width(ui.available_width() - 110.0)
                    .interactive(false),
            );

            ui.add_enabled_ui(!disabled, |ui| {
                if ui
                    .add_sized([100.0, 28.0], egui::Button::new(button_text))
                    .clicked()
                {
                    on_pick();
                }
            });
        });
    }
}
