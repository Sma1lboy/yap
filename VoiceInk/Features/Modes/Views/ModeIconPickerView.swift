import SwiftUI

struct ModeIconView: View {
    let icon: ModeIcon
    var size: CGFloat = 18
    var color: Color = .primary

    var body: some View {
        Group {
            switch icon.kind {
            case .symbol:
                Image(systemName: icon.value)
                    .font(.system(size: size, weight: .medium))  // design-exempt: icon glyph sized to its container
                    .foregroundStyle(color)
            case .emoji:
                Text(icon.value)
                    .font(.system(size: size))  // design-exempt: icon glyph sized to its container
            }
        }
    }
}

struct ModeIconPickerView: View {
    @Binding var selectedIcon: ModeIcon
    @Binding var isPresented: Bool

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: AppTheme.Spacing.x3)]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: AppTheme.Spacing.x3) {
                ForEach(ModeIcon.defaultSymbols, id: \.self) { symbol in
                    ModeIconButton(
                        symbol: symbol,
                        isSelected: selectedIcon == .symbol(symbol)
                    ) {
                        selectedIcon = .symbol(symbol)
                        isPresented = false
                    }
                }
            }
        }
        .frame(maxHeight: 220)
        .padding()
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 340, minHeight: 120, idealHeight: 240, maxHeight: 300)
    }
}

private struct ModeIconButton: View {
    let symbol: String
    let isSelected: Bool
    let selectAction: () -> Void

    var body: some View {
        Button(action: selectAction) {
            ModeIconView(icon: .symbol(symbol), size: 18, color: .primary)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(isSelected ? AppTheme.Accent.fill : AppTheme.Surface.control)
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            isSelected ? AppTheme.Accent.primary : AppTheme.Border.control,
                            lineWidth: isSelected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
    struct ModeIconPickerView_Previews: PreviewProvider {
        static var previews: some View {
            ModeIconPickerView(
                selectedIcon: .constant(.defaultIcon),
                isPresented: .constant(true)
            )
        }
    }
#endif
