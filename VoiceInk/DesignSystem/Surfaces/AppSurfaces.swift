import SwiftUI

struct AppCardBackground: View {
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(AppTheme.Surface.card)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        isSelected ? AppTheme.Selection.border : AppTheme.Border.subtle,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
    }
}

struct AppMaterialCardBackground: View {
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 12

    static let fill = AppTheme.Surface.materialCard

    static func border(for isSelected: Bool) -> Color {
        isSelected ? AppTheme.Selection.border : AppTheme.Border.card
    }

    static func lineWidth(for isSelected: Bool) -> CGFloat {
        isSelected ? 1.5 : 1
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Self.fill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        Self.border(for: isSelected),
                        lineWidth: Self.lineWidth(for: isSelected)
                    )
            )
    }
}

struct MetricTintBackground: View {
    let color: Color
    var cornerRadius: CGFloat = AppTheme.Radius.card

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppTheme.Border.subtle, lineWidth: 1)
            )
    }
}
