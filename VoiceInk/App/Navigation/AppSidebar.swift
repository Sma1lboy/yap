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
        // The window has no title bar: the sidebar runs to the top, the brand header starts under the traffic
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
            SidebarBrandHeader()
                // Left edge on the menu items' icons: section inset + item inset.
                .padding(.horizontal, AppTheme.Spacing.x6)
                .padding(.top, topInset)
                .padding(.bottom, AppTheme.Spacing.x4)

            sidebarSection(ViewType.primaryItems)

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
                // Selected: the icon in text color over its duotone tint in duck yellow; otherwise secondary gray.
                ZStack {
                    if isSelected, let tint = Image.yapIconTint(viewType.icon) {
                        tint.foregroundStyle(AppTheme.Accent.primary)
                    }
                    Image(yapIcon: viewType.icon)
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(isSelected ? AppTheme.Text.primary : AppTheme.Text.secondary)
                }
                .font(AppTheme.font(.callout, .regular))
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
                    .fill(isSelected ? AppTheme.Accent.fillSubtle : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(viewType.title)
        .accessibilityLabel(viewType.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Top of the sidebar, under the traffic lights: the app icon, "Yap" and the running version, on every page.
/// The version moves under "Yap" when the line doesn't fit. Not interactive: the whole block drags the window.
private struct SidebarBrandHeader: View {
    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.x2) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)  // design-exempt: app icon size, not spacing
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x2) { name; version }
                VStack(alignment: .leading, spacing: 0) { name; version }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(WindowDragStrip())
        .accessibilityElement(children: .combine)
    }

    private var name: some View {
        Text(verbatim: "Yap")
            .font(AppTheme.font(.headline, .semibold))
            .foregroundStyle(AppTheme.Text.primary)
            .fixedSize()
    }

    private var version: some View {
        Text(verbatim: Self.versionText)
            .font(AppTheme.font(.caption, .medium))
            .monospacedDigit()
            .foregroundStyle(AppTheme.Text.secondary)
            .fixedSize()
            .accessibilityLabel(String(format: String(localized: "Version %@"), Self.versionText))
    }

    /// "1.2.0"; Debug builds add the build number, "1.2.0 (220)", to tell dev builds apart.
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        #if DEBUG
            if let build = info?["CFBundleVersion"] as? String { return "\(version) (\(build))" }
        #endif
        return version
    }
}
