import SwiftUI

struct AppSidebar: View {
    @Binding var selectedView: ViewType

    var body: some View {
        ZStack(alignment: .trailing) {
            sidebarBackground
            sidebarDivider
            sidebarContent
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .onAppear {
            ViewType.assertSidebarItemsCoverAllCases()
        }
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            sidebarSection(ViewType.primaryItems)
                .padding(.top, 10)

            Spacer(minLength: 16)

            sidebarSection(ViewType.secondaryItems)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebarBackground: some View {
        VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
            .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebarDivider: some View {
        Rectangle()
            .fill(AppTheme.Border.control.opacity(0.55))
            .frame(width: 1)
            .ignoresSafeArea(.container, edges: .top)
    }

    private func sidebarSection(_ items: [ViewType]) -> some View {
        VStack(spacing: 3) {
            ForEach(items) { viewType in
                SidebarItemButton(
                    viewType: viewType,
                    isSelected: selectedView == viewType
                ) {
                    selectedView = viewType
                }
            }
        }
        .padding(.horizontal, 10)
    }
}

private extension ViewType {
    var title: LocalizedStringKey {
        switch self {
        case .dashboard:
            return "Home"
        case .models:
            return "Models"
        default:
            return LocalizedStringKey(rawValue)
        }
    }

    static let primaryItems: [ViewType] = [
        .dashboard,
        .modes,
        .history,
        .dictionary,
        .models,
        .audio,
    ]

    static let secondaryItems: [ViewType] = [
        .settings,
    ]

    /// Reachable only from other screens (History toolbar, Finder "Open With"), not the sidebar.
    static let hiddenItems: [ViewType] = [
        .transcribeAudio,
    ]

    static func assertSidebarItemsCoverAllCases() {
        #if DEBUG
            let sidebarItems = primaryItems + secondaryItems + hiddenItems
            assert(Set(sidebarItems) == Set(allCases) && sidebarItems.count == allCases.count)
        #endif
    }

    var icon: String {
        switch self {
        case .dashboard: return "house"
        case .transcribeAudio: return "waveform"
        case .history: return "clock"
        case .models: return "cpu"
        case .modes: return "square.stack"
        case .audio: return "mic"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        }
    }
}

private struct SidebarItemButton: View {
    let viewType: ViewType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: viewType.icon)
                    .font(.system(size: 14, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(AppTheme.Text.secondary)
                    .frame(width: 20)

                Text(viewType.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(AppTheme.Text.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AppTheme.Selection.fill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(viewType.title)
        .accessibilityLabel(viewType.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
