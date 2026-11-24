import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Harbor's two looks. Daylight in macOS light mode, night in dark mode.
struct HarborTheme {
    let night: Bool
    init(_ scheme: ColorScheme) { night = scheme == .dark }

    private func pick(_ day: UInt32, _ dark: UInt32) -> Color { Color(hex: night ? dark : day) }

    var window: Color { pick(0xFFF6EA, 0x08141E) }
    var panel: Color { pick(0xFFFBF4, 0x0F2231) }
    var panelStroke: Color { night ? Color.white.opacity(0.09) : Color(hex: 0x2F3E57, opacity: 0.14) }
    var divider: Color { night ? Color.white.opacity(0.09) : Color(hex: 0x2F3E57, opacity: 0.12) }
    var text: Color { pick(0x2F3E57, 0xF3F7F8) }
    var secondary: Color { pick(0x5C6B7A, 0x9FB8C4) }
    var field: Color { pick(0xFFFFFF, 0x0A1A26) }
    var fieldStroke: Color { night ? Color.white.opacity(0.14) : Color(hex: 0x2F3E57, opacity: 0.2) }

    var primary: Color { pick(0x2F3E57, 0xF2C879) }
    var primaryText: Color { pick(0xFFF6EA, 0x1B1203) }
    var accent: Color { pick(0xB85F3E, 0xF2C879) }
    var accentText: Color { pick(0xFFF8F0, 0x1B1203) }
    var tint: Color { pick(0x3E8E86, 0xF2C879) }

    var running: Color { pick(0x1F7A62, 0x7FE0BC) }
    var lampOn: Color { pick(0x1BA37E, 0x4FD1A1) }
    var lampOff: Color { pick(0xB8C2CC, 0x4A5A66) }

    // The harbor
    var waterTop: Color { pick(0x7CC3D6, 0x0B2236) }
    var waterBottom: Color { pick(0x4FA3BF, 0x103349) }
    var shore: Color { pick(0xE8D5AE, 0x2B2A2D) }
    var boardwalk: Color { pick(0xC9B48A, 0x3B3024) }
    var pier: Color { pick(0x8A6440, 0x5A4230) }
    var pierLine: Color { pick(0x6E4D31, 0x43301F) }
    var post: Color { pick(0x5E3F26, 0x33241A) }
    var selection: Color { pick(0x2F3E57, 0xF2C879) }
    var plate: Color { panel }

    // Usage gauge
    var gaugeFillTop: Color { pick(0x5FA8BF, 0x46B0C2) }
    var gaugeFillBottom: Color { pick(0x2F6F8F, 0x2A7C97) }
    var gaugeBody: Color { pick(0xEAF2F5, 0x0A1A26) }
    var gaugeStroke: Color { pick(0x2F3E57, 0xE8F0F3) }
    var bar: Color { pick(0x8CBFD0, 0x2A7C97) }
    var barToday: Color { pick(0x2F6F8F, 0x46B0C2) }
}

/// Buttons in Harbor's style: filled for the main action, outlined for the rest.
struct HarborButtonStyle: ButtonStyle {
    enum Kind { case primary, accent, ghost }
    let kind: Kind
    let theme: HarborTheme

    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, kind: kind, theme: theme)
    }

    private struct Inner: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        let theme: HarborTheme
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let fg: Color = kind == .primary ? theme.primaryText : kind == .accent ? theme.accentText : theme.text
            let bg: Color = kind == .primary ? theme.primary : kind == .accent ? theme.accent : .clear
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(fg)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(bg, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(theme.fieldStroke, lineWidth: kind == .ghost ? 1 : 0))
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
