import SwiftUI

struct TriggerGroupEditorView: View {
    @Binding var group: ModeTriggerGroup
    let installedApps: [InstalledAppInfo]
    let reservedAppBundleIds: Set<String>
    let reservedWebsites: Set<String>
    let cleanURL: (String) -> String

    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            addTriggerField
        }
        .frame(width: 340, height: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.half) {
            Text(group.name)
                .font(AppTheme.font(.callout, .semibold))
                .foregroundStyle(.primary)
            Text("Edit the apps and websites in this group.")
                .font(AppTheme.font(.caption))
                .foregroundStyle(.secondary)
        }
        .padding(AppTheme.Spacing.x3)
    }

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: AppTheme.Spacing.x1) {
                if group.isEmpty {
                    Text("No triggers in this group")
                        .font(AppTheme.font(.footnote, .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.x8)
                } else {
                    ForEach(group.appConfigs) { appConfig in
                        groupAppRow(appConfig)
                    }

                    ForEach(group.urlConfigs) { urlConfig in
                        groupWebsiteRow(urlConfig)
                    }
                }
            }
            .padding(AppTheme.Spacing.x2)
        }
    }

    private var addTriggerField: some View {
        VStack(spacing: AppTheme.Spacing.x2) {
            HStack(spacing: AppTheme.Spacing.x2) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(AppTheme.font(.footnote))

                TextField("Add app or website...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(AppTheme.font(.body))
                    .onSubmit(addWebsiteIfPossible)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(AppTheme.font(.footnote))
                    }
                    .buttonStyle(.plain)
                    .help("Clear Search")
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, AppTheme.Spacing.x3)
            .padding(.vertical, AppTheme.Spacing.x2)

            if canOfferWebsite {
                websiteSuggestionRow
                    .padding(.horizontal, AppTheme.Spacing.x2)
            }

            appSuggestions
        }
        .padding(.bottom, AppTheme.Spacing.x2)
    }

    @ViewBuilder
    private var appSuggestions: some View {
        let apps = filteredApps.prefix(4)
        if !apps.isEmpty {
            VStack(spacing: AppTheme.Spacing.half) {
                ForEach(Array(apps), id: \.bundleId) { app in
                    Button {
                        addApp(app)
                    } label: {
                        HStack(spacing: AppTheme.Spacing.x2) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 22, height: 22)
                                .cornerRadius(AppTheme.Radius.small)
                            Text(app.name)
                                .font(AppTheme.font(.footnote, .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, AppTheme.Spacing.x3)
                        .padding(.vertical, AppTheme.Spacing.x1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var websiteSuggestionRow: some View {
        Button(action: addWebsiteIfPossible) {
            HStack(spacing: AppTheme.Spacing.x2) {
                TriggerSymbol(systemName: "globe")
                Text(String(format: String(localized: "Add %@"), websiteCandidate))
                    .font(AppTheme.font(.footnote, .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, AppTheme.Spacing.x2)
            .padding(.vertical, AppTheme.Spacing.x2)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.control).fill(AppTheme.Surface.card))
        }
        .buttonStyle(.plain)
    }

    private func groupAppRow(_ appConfig: AppConfig) -> some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            TriggerAppIcon(bundleId: appConfig.bundleIdentifier, size: 24)
            Text(appConfig.appName)
                .font(AppTheme.font(.body, .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            TriggerRemoveButton {
                group.appConfigs.removeAll { $0.id == appConfig.id }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.x2)
        .padding(.vertical, AppTheme.Spacing.x2)
    }

    private func groupWebsiteRow(_ urlConfig: URLConfig) -> some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            TriggerSymbol(systemName: "globe")
            Text(urlConfig.url)
                .font(AppTheme.font(.body, .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            TriggerRemoveButton {
                group.urlConfigs.removeAll { $0.id == urlConfig.id }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.x2)
        .padding(.vertical, AppTheme.Spacing.x1)
    }

    private var filteredApps: [InstalledAppInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return installedApps.filter { app in
            !group.appConfigs.contains(where: { $0.bundleIdentifier == app.bundleId })
                && !reservedAppBundleIds.contains(app.bundleId)
                && (app.name.localizedCaseInsensitiveContains(query)
                    || app.bundleId.localizedCaseInsensitiveContains(query))
        }
    }

    private var websiteCandidate: String {
        cleanURL(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var canOfferWebsite: Bool {
        isWebsiteLike(websiteCandidate) && !reservedWebsites.contains(websiteCandidate)
            && !group.urlConfigs.contains(where: { cleanURL($0.url) == websiteCandidate })
    }

    private func addApp(_ app: InstalledAppInfo) {
        guard !reservedAppBundleIds.contains(app.bundleId),
            !group.appConfigs.contains(where: { $0.bundleIdentifier == app.bundleId })
        else { return }
        group.appConfigs.append(AppConfig(bundleIdentifier: app.bundleId, appName: app.name))
        searchText = ""
    }

    private func addWebsiteIfPossible() {
        guard canOfferWebsite else { return }
        group.urlConfigs.append(URLConfig(url: websiteCandidate))
        searchText = ""
    }

    private func isWebsiteLike(_ value: String) -> Bool {
        guard !value.isEmpty,
            value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            value.rangeOfCharacter(from: .alphanumerics) != nil
        else {
            return false
        }

        return value.contains(".") || value.contains(":") || value == "localhost"
    }
}
