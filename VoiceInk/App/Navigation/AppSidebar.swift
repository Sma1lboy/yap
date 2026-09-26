import SwiftUI

struct AppSidebar: View {
    @Binding var selectedView: ViewType
    /// The traffic lights are hidden in full screen, so the space kept for them goes too.
    @State private var isFullScreen = false

    var body: some View {
        ZStack(alignment: .trailing) {
            sidebarBackground
            sidebarDivider
            sidebarContent
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        // The window has no title bar: the sidebar runs to the top, its first item starts under the traffic
        // lights, and the space around them drags the window.
        .ignoresSafeArea(.container, edges: .top)
        .windowDragArea(height: topInset)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        .onAppear {
            ViewType.assertSidebarItemsCoverAllCases()
        }
    }

    private var topInset: CGFloat {
        isFullScreen ? AppTheme.Spacing.x3 : AppWindowLayout.titlebarHeight + AppTheme.Spacing.x2
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            sidebarSection(ViewType.primaryItems)
                .padding(.top, topInset)

            Spacer(minLength: 16)

            sidebarSection(ViewType.secondaryItems)
                .padding(.bottom, AppTheme.Spacing.x4)
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
        VStack(spacing: AppTheme.Spacing.x1) {
            ForEach(items) { viewType in
                SidebarItemButton(
                    viewType: viewType,
                    isSelected: selectedView.sidebarOwner == viewType
                ) {
                    selectedView = viewType
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.x3)
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
        .dictionary,
        .models,
        .audio,
    ]

    static let secondaryItems: [ViewType] = [
        .settings,
    ]

    /// Not in the sidebar: Transcribe Audio opens from the Home list toolbar and Finder "Open With";
    /// History is part of Home (navigating to it lands on Home). Account is the Yap Cloud provider page, opened
    /// from Models > Cloud like every other provider, and from balance prompts.
    static let hiddenItems: [ViewType] = [
        .transcribeAudio,
        .history,
        .account,
    ]

    /// The sidebar entry a hidden page belongs to, highlighted while it's open.
    var sidebarOwner: ViewType {
        self == .account ? .models : self
    }

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
        case .account: return "person.crop.circle"
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
            HStack(spacing: AppTheme.Spacing.x2) {
                Image(systemName: viewType.icon)
                    .font(AppTheme.font(.callout, .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(AppTheme.Text.secondary)
                    .frame(width: 20)

                Text(viewType.title)
                    .font(AppTheme.font(.body, isSelected ? .semibold : .regular))
                    .foregroundStyle(AppTheme.Text.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppTheme.Spacing.x3)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .fill(isSelected ? AppTheme.Selection.fill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(viewType.title)
        .accessibilityLabel(viewType.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
