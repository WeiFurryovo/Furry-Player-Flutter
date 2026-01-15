//! 主题定义

use egui::{Color32, Rounding, Stroke, Style, Visuals};

/// Cyber-Furry 深色主题
pub struct FurryTheme;

impl FurryTheme {
    // 颜色定义
    pub const BG_DEEP: Color32 = Color32::from_rgb(18, 18, 24);
    pub const BG_SURFACE: Color32 = Color32::from_rgb(30, 30, 38);
    pub const BG_ELEVATED: Color32 = Color32::from_rgb(40, 40, 50);
    pub const ACCENT_PRIMARY: Color32 = Color32::from_rgb(255, 100, 50);
    pub const ACCENT_SECONDARY: Color32 = Color32::from_rgb(50, 200, 180);
    pub const TEXT_PRIMARY: Color32 = Color32::from_rgb(240, 240, 240);
    pub const TEXT_MUTED: Color32 = Color32::from_rgb(150, 150, 160);
    pub const BORDER: Color32 = Color32::from_rgb(60, 60, 70);

    /// 应用主题到 egui context
    pub fn apply(ctx: &egui::Context) {
        let mut style = Style::default();

        // 视觉样式
        let mut visuals = Visuals::dark();

        visuals.panel_fill = Self::BG_DEEP;
        visuals.window_fill = Self::BG_SURFACE;
        visuals.extreme_bg_color = Self::BG_DEEP;
        visuals.faint_bg_color = Self::BG_SURFACE;

        // 控件样式
        visuals.widgets.noninteractive.bg_fill = Self::BG_SURFACE;
        visuals.widgets.noninteractive.fg_stroke = Stroke::new(1.0, Self::TEXT_MUTED);
        visuals.widgets.noninteractive.rounding = Rounding::same(8.0);

        visuals.widgets.inactive.bg_fill = Self::BG_ELEVATED;
        visuals.widgets.inactive.fg_stroke = Stroke::new(1.0, Self::TEXT_PRIMARY);
        visuals.widgets.inactive.rounding = Rounding::same(8.0);

        visuals.widgets.hovered.bg_fill = Self::ACCENT_PRIMARY.gamma_multiply(0.3);
        visuals.widgets.hovered.fg_stroke = Stroke::new(1.0, Self::TEXT_PRIMARY);
        visuals.widgets.hovered.rounding = Rounding::same(8.0);

        visuals.widgets.active.bg_fill = Self::ACCENT_PRIMARY;
        visuals.widgets.active.fg_stroke = Stroke::new(1.0, Self::BG_DEEP);
        visuals.widgets.active.rounding = Rounding::same(8.0);

        visuals.selection.bg_fill = Self::ACCENT_PRIMARY.gamma_multiply(0.4);
        visuals.selection.stroke = Stroke::new(1.0, Self::ACCENT_PRIMARY);

        visuals.window_rounding = Rounding::same(12.0);
        visuals.window_stroke = Stroke::new(1.0, Self::BORDER);

        style.visuals = visuals;

        // 间距
        style.spacing.item_spacing = egui::vec2(8.0, 8.0);
        style.spacing.window_margin = egui::Margin::same(12.0);
        style.spacing.button_padding = egui::vec2(12.0, 6.0);

        ctx.set_style(style);
    }
}
