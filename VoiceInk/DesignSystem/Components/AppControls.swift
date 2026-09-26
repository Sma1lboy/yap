import Foundation
import SwiftUI

struct AppIconButton: View {
    let systemName: String
    let help: LocalizedStringResource
    var size: CGFloat = 40
    var iconSize: CGFloat = 18
    var cornerRadius: CGFloat = AppTheme.Radius.pill
    var isDisabled = false
    let action: () -> Void

    init(
        systemName: String,
        help: LocalizedStringResource,
        size: CGFloat = 40,
        iconSize: CGFloat = 18,
        cornerRadius: CGFloat = AppTheme.Radius.pill,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.help = help
        self.size = size
        self.iconSize = iconSize
        self.cornerRadius = cornerRadius
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))  // design-exempt: icon glyph sized to its container
                .foregroundColor(isDisabled ? .secondary.opacity(0.45) : .primary.opacity(0.7))
                .frame(width: size, height: size)
                .background(
                    AppCardBackground(isSelected: false, cornerRadius: cornerRadius)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

extension ButtonStyle where Self == AppActionButtonStyle {
    /// For a plain `Button` that must stay one (menus, `.keyboardShortcut(.defaultAction)`): the system's default
    /// button would draw white text on the yellow accent.
    static func appAction(_ kind: AppActionButtonKind) -> AppActionButtonStyle {
        AppActionButtonStyle(kind: kind, isPill: false)
    }
}

enum AppActionButtonKind: Equatable {
    case secondary
    case primary
    case destructive
}

struct AppActionButton: View {
    let title: LocalizedStringKey
    var kind: AppActionButtonKind = .secondary
    var minWidth: CGFloat?
    /// Capsule at 30pt with card fill, to match a row of capsule controls (search field, AppIconButton).
    var isPill = false
    let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        kind: AppActionButtonKind = .secondary,
        minWidth: CGFloat? = nil,
        isPill: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.minWidth = minWidth
        self.isPill = isPill
        self.action = action
    }

    var body: some View {
        Button(role: kind == .destructive ? .destructive : nil, action: action) {
            Text(title)
                .frame(minWidth: minWidth)
        }
        .buttonStyle(AppActionButtonStyle(kind: kind, isPill: isPill))
    }
}

struct AppActionButtonStyle: ButtonStyle {
    let kind: AppActionButtonKind
    let isPill: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.font(.footnote, .semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, AppTheme.Spacing.x4)
            .frame(height: isPill ? 30 : 32)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
    }

    private var cornerRadius: CGFloat { isPill ? AppTheme.Radius.pill : AppTheme.Radius.control }

    private var foregroundColor: Color {
        switch kind {
        case .secondary: AppTheme.Action.secondaryForeground
        case .primary: AppTheme.Action.primaryForeground
        case .destructive: AppTheme.Action.destructiveForeground
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .secondary: isPill ? AppTheme.Surface.card : AppTheme.Surface.control
        case .primary: AppTheme.Action.primaryFill
        case .destructive: AppTheme.Action.destructiveFill
        }
    }

    private var borderColor: Color {
        switch kind {
        case .secondary: isPill ? AppTheme.Border.subtle : AppTheme.Border.control
        case .primary: AppTheme.Accent.border
        case .destructive: Color.white.opacity(0.14)
        }
    }
}

struct AppPanelHeader: View {
    let title: LocalizedStringKey
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            Text(title)
                .font(AppTheme.font(.body, .semibold))
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Spacer()

            AppIconButton(
                systemName: "xmark",
                help: "Close",
                size: 28,
                iconSize: 14,
                cornerRadius: AppTheme.Radius.control,
                action: onClose
            )
        }
        .padding(.horizontal, AppTheme.Spacing.x5)
        .padding(.vertical, AppTheme.Spacing.x3)
        .overlay(Divider().opacity(0.5), alignment: .bottom)
        .zIndex(1)
    }
}

struct AppScreenHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var infoMessage: LocalizedStringKey?
    var infoURL: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            HStack(spacing: AppTheme.Spacing.x2) {
                Text(title)
                    .font(AppTheme.font(.display, .semibold))
                    .foregroundColor(.primary)

                if let infoMessage {
                    if let infoURL {
                        InfoTip(infoMessage, learnMoreURL: infoURL)
                    } else {
                        InfoTip(infoMessage)
                    }
                }
            }

            Spacer()

            trailing()
        }
        .frame(height: 40)
        .padding(.horizontal, AppTheme.Spacing.x6)
        .padding(.top, AppTheme.Spacing.x5)
        .padding(.bottom, AppTheme.Spacing.x3)
        .frame(maxWidth: .infinity)
    }
}

extension AppScreenHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, infoMessage: LocalizedStringKey? = nil, infoURL: String? = nil) {
        self.title = title
        self.infoMessage = infoMessage
        self.infoURL = infoURL
        self.trailing = { EmptyView() }
    }
}

extension View {
    /// Links per DESIGN.md: ink with an underline in light mode (yellow text is unreadable on white), yellow in dark.
    /// `Link` takes its color from the tint on some macOS versions and from the foreground style on others: set both.
    func appLinkStyle() -> some View {
        tint(AppTheme.Accent.text).foregroundStyle(AppTheme.Accent.text).underline()
    }
}
