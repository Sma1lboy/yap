import SwiftUI

/// The app's side of docs/DESIGN.md. Values come from DesignTokens.generated.swift (generated from DESIGN.md);
/// views use these names and never write colors, font sizes, radii or spacing themselves (`make design-check`).
enum AppTheme {

    enum Accent {
        /// Duck yellow. A fill only: text on it is `Text.onAccent`; yellow text is `Accent.text`.
        static let primary = DesignTokens.Palette.accent
        /// Ink in light mode (yellow text on white is unreadable), yellow in dark mode.
        static let text = DesignTokens.Palette.link
        static let pressed = DesignTokens.Palette.accentPress
        static let fillSubtle = DesignTokens.Palette.accentSubtle
        static let fill = primary.opacity(0.30)
        static let fillStrong = primary.opacity(0.55)
        static let border = DesignTokens.Palette.accentPress
        static let disabled = primary.opacity(0.50)
        static let shadow = primary.opacity(0.25)
        static let focus = DesignTokens.Palette.focus
    }

    enum Surface {
        static let window = DesignTokens.Palette.bg
        static let card = DesignTokens.Palette.surface
        static let materialCard = DesignTokens.Palette.surface.opacity(0.70)
        static let subtle = DesignTokens.Palette.sunken
        static let controlActive = DesignTokens.Palette.sunken
        static let control = DesignTokens.Palette.surface
        static let sidePanelOverlay = DesignTokens.Palette.bg.opacity(0.50)
        static let clear = Color.clear
    }

    enum Border {
        static let subtle = DesignTokens.Palette.border.opacity(0.70)
        static let card = DesignTokens.Palette.border
        static let control = DesignTokens.Palette.border
        static let tint = Color.primary.opacity(0.12)
        static let sidePanelOuter = Color.primary.opacity(0.12)
    }

    enum Selection {
        static let fill = Color.primary.opacity(0.10)
        static let border = Color.primary.opacity(0.14)
        static let foreground = DesignTokens.Palette.text
    }

    /// Semantic colors carry information only: something succeeded, needs attention, or failed.
    /// Money coming in (top-ups, credit) is normal and uses `Text.primary`, not `positive`.
    enum Status {
        static let positive = DesignTokens.Palette.success
        static let success = DesignTokens.Palette.success
        static let successFill = DesignTokens.Palette.successBg
        /// No color of its own: information doesn't need acting on.
        static let info = DesignTokens.Palette.text2
        static let infoStrong = DesignTokens.Palette.text
        static let infoFill = DesignTokens.Palette.sunken
        static let warning = DesignTokens.Palette.warning
        static let warningStrong = DesignTokens.Palette.warning
        static let warningFill = DesignTokens.Palette.warningBg
        static let error = DesignTokens.Palette.danger
        static let errorFill = DesignTokens.Palette.dangerBg
    }

    /// Chart series only (Home stats). Not for UI chrome.
    enum Data {
        static let transcript = Color.indigo  // design-exempt: chart series
        static let audio = Color.teal  // design-exempt: chart series
        static let enhancement = Color.mint  // design-exempt: chart series
        static let purple = Color(nsColor: .systemPurple)  // design-exempt: chart series
        static let yellow = DesignTokens.Palette.accent
        static let orange = DesignTokens.Palette.warning
    }

    enum Waveform {
        static let hoverBubble = Color.primary.opacity(0.74)
        static let hoverMarker = Color.primary.opacity(0.68)
        static let playedLower = Color.primary
        static let playedUpper = Color.primary.opacity(0.80)
        static let unplayedLower = Color.primary.opacity(0.30)
        static let unplayedUpper = Color.primary.opacity(0.20)
    }

    enum Text {
        static let primary = DesignTokens.Palette.text
        static let secondary = DesignTokens.Palette.text2
        static let muted = DesignTokens.Palette.text3
        static let disabled = DesignTokens.Palette.text3.opacity(0.60)
        static let onAccent = DesignTokens.Palette.onAccent
    }

    enum NativeText {
        static let primary = NSColor.labelColor
    }

    enum Action {
        static let primaryFill = Accent.primary
        static let primaryForeground = Text.onAccent
        static let destructiveFill = DesignTokens.Palette.dangerFill
        static let destructiveForeground = DesignTokens.Palette.onDanger
        static let secondaryForeground = Text.primary
        static let disabledFill = Surface.controlActive
        static let disabledForeground = Text.disabled
    }

    enum Radius {
        static let small = DesignTokens.Radius.sm
        static let control = DesignTokens.Radius.control
        static let card = DesignTokens.Radius.card
        static let panel = DesignTokens.Radius.panel
        static let pill = DesignTokens.Radius.pill
    }

    enum Spacing {
        static let half = DesignTokens.Spacing.half
        static let x1 = DesignTokens.Spacing.x1
        static let x2 = DesignTokens.Spacing.x2
        static let x3 = DesignTokens.Spacing.x3
        static let x4 = DesignTokens.Spacing.x4
        static let x5 = DesignTokens.Spacing.x5
        static let x6 = DesignTokens.Spacing.x6
        static let x8 = DesignTokens.Spacing.x8
        static let x12 = DesignTokens.Spacing.x12
        static let x16 = DesignTokens.Spacing.x16
    }

    enum TextStyle {
        case micro, caption, footnote, body, callout, headline, title3, title, display

        var size: CGFloat {
            switch self {
            case .micro: DesignTokens.FontSize.micro
            case .caption: DesignTokens.FontSize.caption
            case .footnote: DesignTokens.FontSize.footnote
            case .body: DesignTokens.FontSize.body
            case .callout: DesignTokens.FontSize.callout
            case .headline: DesignTokens.FontSize.headline
            case .title3: DesignTokens.FontSize.title3
            case .title: DesignTokens.FontSize.title
            case .display: DesignTokens.FontSize.display
            }
        }
    }

    /// A step of the type scale. Weights are regular, medium or semibold (DESIGN.md).
    static func font(_ style: TextStyle, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: style.size, weight: weight, design: design)
    }
}
