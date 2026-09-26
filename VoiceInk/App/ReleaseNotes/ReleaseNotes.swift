import Foundation
import SwiftUI

/// In-app "What's New": the bundled docs/releases/<version>.md (folder resource `releases`).
/// The whole folder is copied into the app, so it holds only <version>.md files; checklists and reports live in docs/.
/// The file holds an English half then a Chinese half, each starting with a `# ` heading; the half matching
/// the app's language is shown. No file for the running version means no sheet and no About button.
struct ReleaseNotes: Equatable {
    let version: String
    let title: String
    let body: String

    private static let lastLaunchedVersionKey = "lastLaunchedVersion"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Notes for the running version in the app's language, or nil when none are bundled.
    static var current: ReleaseNotes? {
        guard !currentVersion.isEmpty,
            let url = Bundle.main.url(forResource: currentVersion, withExtension: "md", subdirectory: "releases"),
            let markdown = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let prefersChinese = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        return notes(from: markdown, version: currentVersion, chinese: prefersChinese)
    }

    /// Splits at `# ` headings: the first section is English, the second Chinese.
    static func notes(from markdown: String, version: String, chinese: Bool) -> ReleaseNotes? {
        var sections: [(title: String, lines: [String])] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("# ") {
                sections.append((String(line.dropFirst(2)), []))
            } else if !sections.isEmpty {
                sections[sections.count - 1].lines.append(line)
            }
        }
        guard let section = (chinese && sections.count > 1) ? sections[1] : sections.first else { return nil }
        let body = section.lines
            // The English half points readers to the Chinese half; not needed once split.
            .filter { !$0.contains("中文在下面") && $0.trimmingCharacters(in: .whitespaces) != "---" }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : ReleaseNotes(version: version, title: section.title, body: body)
    }

    /// Call once at launch, before onboarding can finish. True on the first launch after an update:
    /// the version changed and this isn't a fresh install. Installs from before this feature have no recorded
    /// version, so an already-completed onboarding is what marks them as updates rather than new users.
    static func recordLaunch(defaults: UserDefaults = .standard) -> Bool {
        let last = defaults.string(forKey: lastLaunchedVersionKey)
        let wasOnboarded = defaults.bool(forKey: OnboardingSettings.completedV2Key)
        defaults.set(currentVersion, forKey: lastLaunchedVersionKey)
        return last != currentVersion && (last != nil || wasOnboarded)
    }

    #if DEBUG
        static func selfCheck() {
            let sample = "# Yap 9.9.9\n\nChanges since 9.9.8. 中文在下面。\n\n## A\n- one\n\n---\n\n# Yap 9.9.9（中文）\n\n## 甲\n- 一\n"
            let en = notes(from: sample, version: "9.9.9", chinese: false)
            let zh = notes(from: sample, version: "9.9.9", chinese: true)
            assert(en?.title == "Yap 9.9.9" && en?.body == "## A\n- one")
            assert(zh?.title == "Yap 9.9.9（中文）" && zh?.body == "## 甲\n- 一")
            assert(notes(from: "no heading", version: "1", chinese: false) == nil)
        }
    #endif
}

/// Shared between ContentView (hosts the sheet, shows it after an update) and Settings > About.
final class ReleaseNotesPresenter: ObservableObject {
    static let shared = ReleaseNotesPresenter()

    @Published var notes: ReleaseNotes?
    /// Set at launch by `recordLaunch`; consumed the first time the main window appears.
    var showsOnNextMainWindow = false

    func showCurrent() {
        notes = ReleaseNotes.current
    }
}

struct ReleaseNotesSheet: View {
    let notes: ReleaseNotes
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(format: String(localized: "What's New in %@"), notes.version))
                .font(AppTheme.font(.headline, .semibold))
                .padding([.horizontal, .top], 24)
                .padding(.bottom, AppTheme.Spacing.x3)

            ScrollView {
                MarkdownContentView(notes.body, fontSize: 13, foregroundColor: AppTheme.Text.primary)
                    .padding(.horizontal, AppTheme.Spacing.x6)
                    .padding(.bottom, AppTheme.Spacing.x4)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.appAction(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(AppTheme.Spacing.x4)
        }
        .frame(width: 560, height: 620)
        .onExitCommand { dismiss() }
    }
}
