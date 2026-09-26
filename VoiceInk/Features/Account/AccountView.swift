import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Yap Cloud account: sign in, balance, add funds, recent charges.
struct AccountView: View {
    @ObservedObject private var cloud = YapCloud.shared
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @State private var isShowingAllModels = false
    @State private var modelQuery = ""

    /// YapCloudPicks in order, transcription first; models missing from the catalog are skipped.
    private var recommendedModels: [YapCloudModel] {
        (YapCloudPicks.transcription + YapCloudPicks.enhancement).compactMap { id in cloud.models.first { $0.id == id } }
    }

    private var allModels: [YapCloudModel] {
        let q = modelQuery.trimmingCharacters(in: .whitespaces)
        let models = cloud.transcriptionModels + cloud.chatModels
        guard !q.isEmpty else { return models }
        return models.filter { $0.id.localizedCaseInsensitiveContains(q) || $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(title: "Account")
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.x6) {
                    if cloud.isUnreachable {
                        AccountBanner(
                            "Yap Cloud is temporarily unavailable. Try again shortly.", systemImage: "wifi.exclamationmark")
                    }
                    if cloud.isSignedIn, cloud.trialNudge != nil {
                        YapCloudTrialNudgeBanner(isHomeCard: false)
                    }
                    if cloud.isSignedIn {
                        SignedInSections()
                    } else {
                        AccountSection("Yap Cloud") {
                            Text("Pay as you go: one balance covers transcription and enhancement, no API keys to manage.")
                                .foregroundStyle(AppTheme.Text.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            YapCloudSignupCreditText()
                                .font(AppTheme.font(.footnote, .semibold))
                            YapCloudSignInForm()
                        } footer: {
                            YapCloudLegalText()
                        }
                    }
                    modelsSection
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, AppTheme.Spacing.x6)
                .padding(.top, AppTheme.Spacing.x2)
                .padding(.bottom, AppTheme.Spacing.x12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .modifier(CloudSyncOffer())
        .task(id: cloud.isSignedIn) {
            await cloud.refreshAccount()
            await cloud.refreshDevices()
            await cloud.refreshModels()
            transcriptionModelManager.refreshAllAvailableModels()
        }
    }

    @ViewBuilder
    private var modelsSection: some View {
        if !cloud.models.isEmpty {
            AccountSection("Models & Pricing") {
                AccountRows(recommendedModels, id: \.id) { model in
                    ModelPriceRow(model: model)
                }
                DisclosureGroup("All Models", isExpanded: $isShowingAllModels) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
                        TextField("Search models", text: $modelQuery)
                            .textFieldStyle(.roundedBorder)
                        AccountRows(allModels, id: \.id) { model in
                            ModelPriceRow(model: model)
                        }
                    }
                    .padding(.top, AppTheme.Spacing.x2)
                }
            } footer: {
                // The paygate host is only useful when pointing a dev build at another server.
                #if DEBUG
                    Text(String(format: String(localized: "Server: %@"), cloud.baseURL.absoluteString))
                #endif
            }
        }
    }
}

// MARK: - Page layout

/// A titled card: Account's building block (DESIGN.md: 1px-bordered card, 16pt padding, explanation inside the
/// card as a left-aligned footnote).
private struct AccountSection<Content: View, Footer: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    init(
        _ title: LocalizedStringKey?, @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.title = title
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            if let title {
                Text(title)
                    .font(AppTheme.font(.body, .semibold))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
                content()
                footer()
                    .font(AppTheme.font(.footnote))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(AppTheme.Spacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppCardBackground(cornerRadius: AppTheme.Radius.card))
        }
    }
}

extension AccountSection where Footer == EmptyView {
    init(_ title: LocalizedStringKey?, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, content: content, footer: { EmptyView() })
    }
}

/// Label (with an optional second line) on the left, value or control on the right.
private struct AccountRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x3) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.half) {
                Text(title)
                    .foregroundStyle(AppTheme.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(AppTheme.font(.caption))
                        .foregroundStyle(AppTheme.Text.muted)
                }
            }
            Spacer(minLength: AppTheme.Spacing.x3)
            trailing()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Rows separated by hairlines.
private struct AccountRows<Item, ID: Hashable, Row: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    @ViewBuilder let row: (Item) -> Row

    init(_ items: [Item], id: KeyPath<Item, ID>, @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.id = id
        self.row = row
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider().padding(.vertical, AppTheme.Spacing.x2) }
                row(item)
            }
        }
    }
}

/// Warning banner: needs attention, so it carries the warning color (DESIGN.md).
private struct AccountBanner: View {
    let text: LocalizedStringKey
    let systemImage: String

    init(_ text: LocalizedStringKey, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(AppTheme.font(.footnote, .medium))
            .foregroundStyle(AppTheme.Status.warning)
            .padding(.horizontal, AppTheme.Spacing.x4)
            .padding(.vertical, AppTheme.Spacing.x3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.card).fill(AppTheme.Status.warningFill))
    }
}

private struct SignedInSections: View {
    @ObservedObject private var cloud = YapCloud.shared
    /// A preset in dollars, or nil for Custom (same shape as the Monthly Cap picker).
    @State private var amount: Int? = YapCloud.checkoutPresets[1]
    @State private var customAmount = ""
    @State private var isOpeningCheckout = false
    @State private var errorMessage: String?
    @State private var isConfirmingSignOut = false
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        balanceHeader

        AccountSection("Add Funds") {
            Picker("Amount (USD)", selection: $amount) {
                ForEach(cloud.topUpPresets, id: \.self) { preset in
                    Text(verbatim: "$\(preset)").tag(Int?.some(preset))
                }
                Text("Custom").tag(Int?.none)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Amount (USD)")
            .onChange(of: amount) { _, _ in errorMessage = nil }
            if amount == nil {
                AccountRow(title: String(localized: "Custom Amount (USD)")) {
                    TextField("", text: $customAmount, prompt: Text(verbatim: "50"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
            }
            HStack(spacing: AppTheme.Spacing.x2) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(AppTheme.font(.caption))
                        .foregroundStyle(AppTheme.Status.error)
                }
                Spacer()
                if isOpeningCheckout { ProgressView().controlSize(.small) }
                // The page's one primary action (DESIGN.md).
                AppActionButton("Add Funds…", kind: .primary, action: openCheckout)
                    .disabled(isOpeningCheckout)
            }
            if cloud.pendingTopUp != nil {
                YapCloudTopUpWaitingRow()
            }
        } footer: {
            Text("Checkout opens in your browser. Your balance updates when you come back to Yap.")
        }

        if let spend = cloud.monthlySpend {
            AccountSection("This Month") {
                AccountRow(title: String(localized: "Total")) {
                    if let cap = cloud.me?.monthlyCapMicros {
                        let spent = cloud.me?.monthSpentMicros ?? spend.totalMicros
                        Text(
                            String(
                                format: String(localized: "%@ used of %@ cap"),
                                YapCloud.formatSpend(micros: spent), YapCloud.formatExactUSD(micros: cap))
                        )
                        .monospacedDigit()
                        .foregroundStyle(spent >= cap ? AppTheme.Status.error : AppTheme.Text.primary)
                    } else {
                        Text(YapCloud.formatSpend(micros: spend.totalMicros))
                            .monospacedDigit()
                    }
                }
                if spend.creditMicros > 0 {
                    Divider()
                    AccountRow(title: String(localized: "Covered by sign-up credit")) {
                        Text(YapCloud.formatSpend(micros: spend.creditMicros))
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.Text.secondary)
                    }
                }
                ForEach(spend.topModels, id: \.model) { item in
                    Divider()
                    AccountRow(
                        title: item.model.map { id in cloud.models.first { $0.id == id }?.displayName ?? id }
                            ?? String(localized: "Other"),
                        detail: YapCloudMonthlySpend.averageMicros(item.micros, calls: item.calls).map { average in
                            String(
                                format: String(localized: "%lld calls · %@ / call"), Int64(item.calls),
                                YapCloud.formatAverage(micros: average))
                        }
                    ) {
                        Text(YapCloud.formatSpend(micros: item.micros))
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.Text.secondary)
                    }
                }
            }
        }

        MonthlyCapSection()

        AccountSection("Recent Activity") {
            if let ledger = cloud.ledger {
                if ledger.isEmpty {
                    Text("No charges or top-ups yet.")
                        .foregroundStyle(AppTheme.Text.secondary)
                } else {
                    AccountRows(ledger, id: \.id.string) { entry in
                        LedgerRow(entry: entry)
                    }
                    HStack(spacing: AppTheme.Spacing.x2) {
                        if let exportError {
                            Text(exportError)
                                .font(AppTheme.font(.caption))
                                .foregroundStyle(AppTheme.Status.error)
                        }
                        Spacer()
                        if isExporting { ProgressView().controlSize(.small) }
                        AppActionButton("Export CSV…", action: exportCSV)
                            .disabled(isExporting)
                    }
                }
            } else if cloud.isRefreshingAccount {
                ProgressView().controlSize(.small)
            } else {
                HStack {
                    Text("Couldn't load recent activity.")
                        .foregroundStyle(AppTheme.Status.error)
                    Spacer()
                    AppActionButton("Retry") { Task { await cloud.refreshAccount() } }
                }
            }
        }

        if let devices = cloud.devices {
            DevicesSection(devices: devices)
        } else if let error = cloud.devicesError {
            AccountSection("Signed-in Devices") {
                HStack {
                    Text(String(format: String(localized: "Couldn't load devices: %@"), error))
                        .foregroundStyle(AppTheme.Status.error)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    AppActionButton("Retry") { Task { await cloud.refreshDevices() } }
                }
            }
        }

        accountSection
    }

    /// The balance leads the page (DESIGN.md: display size, tabular digits), with refresh right next to it.
    private var balanceHeader: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.x4) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                Text("Yap Cloud balance")
                    .font(AppTheme.font(.footnote, .medium))
                    .foregroundStyle(AppTheme.Text.secondary)
                HStack(alignment: .center, spacing: AppTheme.Spacing.x2) {
                    if let balance = cloud.balanceMicros {
                        Text(YapCloud.formatUSD(micros: balance))
                            .font(AppTheme.font(.display, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(balance > 0 ? AppTheme.Text.primary : AppTheme.Status.error)
                            .accessibilityLabel(
                                String(format: String(localized: "Balance %@"), YapCloud.formatUSD(micros: balance)))
                    } else {
                        Text(verbatim: "—")
                            .font(AppTheme.font(.display, .semibold))
                            .foregroundStyle(AppTheme.Text.muted)
                    }
                    if cloud.isRefreshingAccount {
                        ProgressView().controlSize(.small)
                    } else {
                        AppIconButton(
                            systemName: "arrow.clockwise", help: "Refresh", size: 28, iconSize: 12,
                            action: { Task { await cloud.refreshAccount() } })
                    }
                }
                if let line = balanceNote {
                    Text(line)
                        .font(AppTheme.font(.footnote))
                        .foregroundStyle(AppTheme.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = cloud.accountRefreshError {
                    Text(String(format: String(localized: "Couldn't refresh your account: %@"), error))
                        .font(AppTheme.font(.footnote))
                        .foregroundStyle(AppTheme.Status.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: AppTheme.Spacing.x4)
            Text(verbatim: cloud.me?.email ?? cloud.email ?? "")
                .font(AppTheme.font(.footnote))
                .foregroundStyle(AppTheme.Text.secondary)
                .textSelection(.enabled)
                .padding(.top, AppTheme.Spacing.half)
        }
    }

    /// "At this month's pace …" and when the balance was last updated.
    private var balanceNote: String? {
        var parts: [String] = []
        if let runway = balanceRunway {
            let pace = runway.monthlyMicros >= 10_000
                ? "~" + YapCloud.formatSpend(micros: runway.monthlyMicros)
                : YapCloud.formatAverage(micros: runway.monthlyMicros)
            parts.append(
                runway.days > 365
                    ? String(format: String(localized: "At this month's pace (%@ a month), your balance lasts more than a year."), pace)
                    : runway.days == 0
                        ? String(format: String(localized: "At this month's pace (%@ a month), your balance lasts less than a day."), pace)
                        : String(
                            format: String(localized: "At this month's pace (%@ a month), your balance lasts about %lld days."),
                            pace, runway.days))
        }
        if let updatedAt = cloud.balanceUpdatedAt {
            parts.append(
                String(format: String(localized: "Last updated %@"), updatedAt.formatted(date: .omitted, time: .shortened)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Sign-out (not destructive: nothing is lost) and account deletion, at the bottom.
    private var accountSection: some View {
        AccountSection("Account") {
            YapCloudSupportRow()
            AccountRow(
                title: String(localized: "Sign out of Yap Cloud on this Mac"),
                detail: String(localized: "Your settings and transcripts stay on this Mac.")
            ) {
                AppActionButton("Sign Out") { isConfirmingSignOut = true }
                    .confirmationDialog("Sign out of Yap Cloud?", isPresented: $isConfirmingSignOut) {
                        Button("Sign Out", role: .destructive, action: signOut)
                    } message: {
                        Text("Modes that use Yap Cloud stop working until you sign in again or switch them to another provider.")
                    }
            }
            Divider()
            DeleteAccountRow()
        } footer: {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                Text("With Sync via Yap Cloud on (Settings > Config & Sync), your modes, prompts, dictionary, shortcuts and custom models are stored on Yap's server. API keys stay on each Mac.")
                YapCloudLegalLinks()
            }
        }
    }

    /// nil until this month has 3+ days of usage (see YapCloudMonthlySpend.runway).
    private var balanceRunway: YapCloudMonthlySpend.Runway? {
        guard let balance = cloud.balanceMicros, let spend = cloud.monthlySpend, let since = spend.sinceDate else { return nil }
        return YapCloudMonthlySpend.runway(
            balanceMicros: balance, spentMicros: spend.totalMicros,
            elapsedSeconds: Int64(Date().timeIntervalSince(since)))
    }

    /// Every ledger row (all pages, not just the 20 shown) as CSV, saved where the user picks.
    private func exportCSV() {
        isExporting = true
        exportError = nil
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let rows = try await cloud.fetchAllLedger()
                let header = [
                    String(localized: "Date"), String(localized: "Type"), String(localized: "Amount (USD)"),
                    String(localized: "Model"), String(localized: "Receipt"),
                ]
                // BOM so spreadsheet apps read the (possibly non-ASCII) header as UTF-8.
                let csv = "\u{FEFF}" + YapCloud.ledgerCSV(rows, header: header)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.commaSeparatedText]
                panel.nameFieldStringValue = "yap-cloud-ledger-\(Date().formatted(.iso8601.year().month().day())).csv"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try Data(csv.utf8).write(to: url, options: .atomic)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func signOut() {
        cloud.signOut()
        Self.warnAboutModesUsingYapCloud()
    }

    /// After signing out or deleting the account: modes that still transcribe or enhance through Yap Cloud
    /// would fail, so name them and offer Modes.
    @MainActor
    static func warnAboutModesUsingYapCloud() {
        let modesUsingCloud = ModeManager.shared.configurations.filter { mode in
            mode.selectedTranscriptionModelName?.hasPrefix("YapCloud:") == true
                || (mode.isAIEnhancementEnabled && mode.selectedAIProvider == AIProvider.yapCloud.rawValue)
        }
        guard !modesUsingCloud.isEmpty else { return }
        NotificationManager.shared.showNotification(
            title: String(
                format: String(localized: "Still using Yap Cloud: %@. Switch them to another provider in Modes."),
                modesUsingCloud.map(\.name).joined(separator: ", ")),
            type: .warning,
            duration: 10,
            actionButton: (String(localized: "Manage Modes"), ModeSetupNavigator.openModesSettings)
        )
    }

    private func openCheckout() {
        let value = amount
            ?? Int(customAmount.trimmingCharacters(in: CharacterSet(charactersIn: "$ ").union(.whitespaces)))
        guard let value, cloud.isValidTopUp(value) else {
            errorMessage = YapCloudError.invalidAmount.errorDescription
            return
        }
        errorMessage = nil
        isOpeningCheckout = true
        Task {
            defer { isOpeningCheckout = false }
            do {
                try await cloud.openCheckout(amountUSD: value)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

}

private struct LedgerRow: View {
    let entry: YapCloudLedgerEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.half) {
                Text(title)
                if let date = entry.createdDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(AppTheme.font(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if entry.kind == "topup", let receipt = entry.receiptURL {
                Link("Receipt", destination: receipt).appLinkStyle()
                    .font(AppTheme.font(.caption))
            }
            Text((entry.amountMicros > 0 ? "+" : "") + YapCloud.formatLedgerAmount(micros: entry.amountMicros, kind: entry.kind))
                .monospacedDigit()
                .foregroundStyle(AppTheme.Text.primary)  // money coming in isn't a status (DESIGN.md)
        }
    }

    private var title: String {
        switch entry.kind {
        case "topup": return String(localized: "Top-up")
        case "usage":
            guard let model = entry.model else { return String(localized: "Usage") }
            return YapCloud.shared.models.first { $0.id == model }?.displayName ?? model
        case "credit": return String(localized: "Sign-up bonus")
        default: return withReason(String(localized: "Balance adjustment"))
        }
    }

    private func withReason(_ label: String) -> String {
        entry.reason.map { label + ": " + $0 } ?? label
    }
}

private struct ModelPriceRow: View {
    let model: YapCloudModel

    var body: some View {
        AccountRow(title: model.displayName, detail: model.id) {
            Text(price)
                .monospacedDigit()
                .foregroundStyle(AppTheme.Text.secondary)
        }
    }

    /// Chat: USD per 1M input/output tokens. Transcription prices come in per-model units (per second, per hour,
    /// per token) that OpenRouter doesn't label, so no number is shown for them.
    private var price: String {
        if model.isTranscription {
            return String(localized: "Pay as you go")
        }
        let perMillion = { (key: String) in YapCloud.formatUSD(micros: model.pricePerMillionMicros(key) ?? 0) }
        return String(format: String(localized: "%@ in / %@ out per 1M tokens"), perMillion("prompt"), perMillion("completion"))
    }
}

/// Email → 6-digit code. Shared by Account and onboarding.
struct YapCloudSignInForm: View {
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field { case email, code }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            if codeSent {
                Text(String(format: String(localized: "Enter the 6-digit code sent to %@."), email))
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Code", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.oneTimeCode)
                        .focused($focusedField, equals: .code)
                        .onSubmit(verify)
                    Button("Sign In", action: verify)
                        .buttonStyle(.appAction(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || codeDigits.count != 6)
                }
                HStack(spacing: AppTheme.Spacing.x4) {
                    Button("Resend Code", action: sendCode)
                        .disabled(isWorking)
                    Button("Use a different email") {
                        codeSent = false
                        code = ""
                        errorMessage = nil
                    }
                }
                .buttonStyle(.link)
            } else {
                HStack {
                    TextField("Email address", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                        .focused($focusedField, equals: .email)
                        .onSubmit(sendCode)
                    Button("Send Code", action: sendCode)
                        .buttonStyle(.appAction(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || !email.contains("@"))
                }
            }
            HStack(spacing: AppTheme.Spacing.x2) {
                if isWorking { ProgressView().controlSize(.small) }
                if let errorMessage {
                    Text(errorMessage)
                        .font(AppTheme.font(.caption))
                        .foregroundStyle(AppTheme.Status.error)
                }
            }
        }
        .onAppear { focusedField = codeSent ? .code : .email }
        .onChange(of: codeSent) { _, sent in focusedField = sent ? .code : .email }
    }

    private func sendCode() {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@") else { return }
        run {
            try await YapCloud.shared.startSignIn(email: trimmed)
            email = trimmed
            codeSent = true
        }
    }

    /// Codes pasted from email often carry spaces or dashes ("123 456").
    private var codeDigits: String {
        code.filter(\.isNumber)
    }

    private func verify() {
        let digits = codeDigits
        guard digits.count == 6 else { return }
        run { try await YapCloud.shared.verify(email: email, code: digits) }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        // Return in a text field submits even while the button is disabled.
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await work()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Preset top-up buttons that open Stripe Checkout directly (onboarding can't navigate to Account).
struct YapCloudQuickTopUp: View {
    @ObservedObject private var cloud = YapCloud.shared
    @State private var isOpening = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            HStack(spacing: AppTheme.Spacing.x2) {
                ForEach(cloud.topUpPresets, id: \.self) { amount in
                    Button(String(format: String(localized: "Add $%lld"), Int64(amount))) { open(amount) }
                        .disabled(isOpening)
                }
                if isOpening { ProgressView().controlSize(.small) }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.Status.error)
            }
            if cloud.pendingTopUp != nil {
                YapCloudTopUpWaitingRow()
            }
        }
    }

    private func open(_ amount: Int) {
        isOpening = true
        errorMessage = nil
        Task { @MainActor in
            defer { isOpening = false }
            do {
                try await cloud.openCheckout(amountUSD: amount)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Monthly spending cap: None / $5 / $10 / $20 / custom whole dollars. Shown once /v1/me reports caps.
private struct MonthlyCapSection: View {
    private enum Choice: Hashable {
        case none, preset(Int), custom
    }

    @ObservedObject private var cloud = YapCloud.shared
    @State private var choice: Choice = .none
    @State private var customDollars = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var savedCapMicros: Int64? { cloud.me?.monthlyCapMicros }

    var body: some View {
        AccountSection("Monthly Cap") {
            AccountRow(title: String(localized: "Monthly Cap")) {
                Picker("Monthly Cap", selection: $choice) {
                    Text("No Cap").tag(Choice.none)
                    ForEach(YapCloud.monthlyCapPresets, id: \.self) { dollars in
                        Text(verbatim: "$\(dollars)").tag(Choice.preset(dollars))
                    }
                    Text("Custom").tag(Choice.custom)
                }
                .labelsHidden()
                .fixedSize()
            }
            if choice == .custom {
                AccountRow(title: String(localized: "Cap (USD)")) {
                    TextField("", text: $customDollars, prompt: Text(verbatim: "50"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
            }
            HStack {
                if let errorMessage {
                    Text(errorMessage)
                        .font(AppTheme.font(.caption))
                        .foregroundStyle(AppTheme.Status.error)
                }
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                AppActionButton("Save", action: save)
                    .disabled(isSaving || pendingCapMicros == .invalid || pendingCapMicros == .value(savedCapMicros))
            }
        } footer: {
            Text("When this month's spending reaches the cap, Yap Cloud stops charging until next month or until you raise it.")
        }
        .onAppear(perform: loadSaved)
        .onChange(of: savedCapMicros) { _, _ in loadSaved() }
    }

    private enum Pending: Equatable {
        case value(Int64?)
        case invalid
    }

    private var pendingCapMicros: Pending {
        switch choice {
        case .none: return .value(nil)
        case .preset(let dollars): return .value(Int64(dollars) * 1_000_000)
        case .custom:
            return YapCloud.monthlyCapMicros(fromDollars: customDollars).map { .value($0) } ?? .invalid
        }
    }

    private func loadSaved() {
        guard let cap = savedCapMicros else {
            choice = .none
            return
        }
        let dollars = Int(cap / 1_000_000)
        if cap % 1_000_000 == 0, YapCloud.monthlyCapPresets.contains(dollars) {
            choice = .preset(dollars)
        } else {
            choice = .custom
            customDollars = String(YapCloud.formatExactUSD(micros: cap).dropFirst())
        }
    }

    private func save() {
        guard case .value(let micros) = pendingCapMicros else {
            errorMessage = String(localized: "Enter a cap between $0 and $10,000. $0 blocks all Yap Cloud calls.")
            return
        }
        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await cloud.setMonthlyCap(micros: micros)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// "Waiting for payment to complete…" while a Checkout is open; the balance check runs when Yap is active again.
struct YapCloudTopUpWaitingRow: View {
    @ObservedObject private var cloud = YapCloud.shared

    var body: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            ProgressView().controlSize(.small)
            Text("Waiting for payment to complete…")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Stop Waiting") { cloud.stopWaitingForTopUp() }
                .buttonStyle(.link)
        }
        .font(AppTheme.font(.footnote))
    }
}

/// Signed-in devices (one token each). This Mac is marked; others can be signed out remotely after a confirmation.
private struct DevicesSection: View {
    let devices: [YapCloudDevice]
    @ObservedObject private var cloud = YapCloud.shared
    @State private var pendingRemoval: YapCloudDevice?
    @State private var removingID: String?
    @State private var errorMessage: String?

    var body: some View {
        AccountSection("Signed-in Devices") {
            AccountRows(devices, id: \.id.string) { device in
                HStack {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.half) {
                        HStack(spacing: AppTheme.Spacing.x2) {
                            Text(name(device))
                            if device.current {
                                Text("This Mac")
                                    .font(AppTheme.font(.caption))
                                    .foregroundStyle(AppTheme.Text.primary)
                                    .padding(.horizontal, AppTheme.Spacing.x2)
                                    .padding(.vertical, AppTheme.Spacing.half)
                                    .background(Capsule().fill(AppTheme.Accent.fillSubtle))
                            }
                        }
                        if let date = device.lastUsedDate {
                            Text(String(format: String(localized: "Last used %@"), date.formatted(.relative(presentation: .named))))
                                .font(AppTheme.font(.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !device.current {
                        if removingID == device.id.string {
                            ProgressView().controlSize(.small)
                        } else {
                            AppActionButton("Sign Out") { pendingRemoval = device }
                                .disabled(removingID != nil)
                                .accessibilityLabel(String(format: String(localized: "Sign out %@"), name(device)))
                        }
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.Status.error)
            }
        }
        .confirmationDialog(
            String(format: String(localized: "Sign out %@?"), pendingRemoval.map(name) ?? ""),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                if let device = pendingRemoval { remove(device) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("That device is signed out of Yap Cloud and stops charging your balance. It can sign in again with your email.")
        }
    }

    private func name(_ device: YapCloudDevice) -> String {
        device.deviceName.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Unnamed device")
    }

    private func remove(_ device: YapCloudDevice) {
        removingID = device.id.string
        errorMessage = nil
        Task { @MainActor in
            defer { removingID = nil }
            do {
                try await cloud.removeDevice(device)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Terms of Service and Privacy Policy links, from /v1/info (hidden until it has loaded).
struct YapCloudLegalLinks: View {
    @ObservedObject private var cloud = YapCloud.shared

    var body: some View {
        if let terms = cloud.info?.termsURL, let privacy = cloud.info?.privacyURL {
            HStack(spacing: AppTheme.Spacing.x4) {
                Link("Terms of Service", destination: terms).appLinkStyle()
                Link("Privacy Policy", destination: privacy).appLinkStyle()
            }
        }
    }
}

/// "New accounts get $1 of free credit." from /v1/info; nothing when there is no sign-up credit or no info.
struct YapCloudSignupCreditText: View {
    @ObservedObject private var cloud = YapCloud.shared

    var body: some View {
        if let credit = cloud.info?.signupCreditMicros, credit > 0 {
            Text(String(format: String(localized: "New accounts get %@ of free credit."), YapCloud.formatPlainUSD(micros: credit)))
        }
    }
}

/// "Contact support: <email>" with the address selectable (and a mailto link), when /v1/info has one.
struct YapCloudSupportRow: View {
    @ObservedObject private var cloud = YapCloud.shared

    var body: some View {
        if let email = cloud.info?.supportEmail, !email.isEmpty {
            AccountRow(title: String(localized: "Contact Support")) {
                HStack(spacing: AppTheme.Spacing.x2) {
                    Text(verbatim: email)
                        .foregroundStyle(AppTheme.Text.secondary)
                        .textSelection(.enabled)
                    if let mailto = URL(string: "mailto:" + email) {
                        Link(destination: mailto) { Image(systemName: "envelope") }
                            .appLinkStyle()
                            .help("Email support")
                            .accessibilityLabel("Email support")
                    }
                }
            }
        }
    }
}

/// "By continuing, you agree to the Terms of Service and Privacy Policy.", with both names as links.
/// Built from one localized format so each language places the links where its grammar needs them.
/// Hidden until /v1/info supplies the URLs.
struct YapCloudLegalText: View {
    @ObservedObject private var cloud = YapCloud.shared

    var body: some View {
        if let terms = cloud.info?.termsURL, let privacy = cloud.info?.privacyURL {
            // Link runs take the tint, not the foreground style: ink in light mode, yellow in dark (DESIGN.md).
            Text(attributed(terms: terms, privacy: privacy))
                .tint(AppTheme.Accent.text)
        }
    }

    private func attributed(terms termsURL: URL, privacy privacyURL: URL) -> AttributedString {
        let terms = String(localized: "Terms of Service")
        let privacy = String(localized: "Privacy Policy")
        var text = AttributedString(
            String(format: String(localized: "By continuing, you agree to the %1$@ and %2$@."), terms, privacy))
        for (name, url) in [(terms, termsURL), (privacy, privacyURL)] {
            if let range = text.range(of: name) {
                text[range].link = url
                text[range].underlineStyle = .single
            }
        }
        return text
    }
}

/// Last row of Account: delete the Yap Cloud account after typing its email. The only destructive action
/// on the page, so the only red button.
private struct DeleteAccountRow: View {
    @State private var isConfirming = false

    var body: some View {
        AccountRow(
            title: String(localized: "Delete Yap Cloud Account"),
            detail: String(localized: "Deletes this account for every device. Your remaining balance is not refunded.")
        ) {
            AppActionButton("Delete…", kind: .destructive) { isConfirming = true }
        }
        .sheet(isPresented: $isConfirming) { DeleteAccountSheet() }
    }
}

private struct DeleteAccountSheet: View {
    @ObservedObject private var cloud = YapCloud.shared
    @Environment(\.dismiss) private var dismiss
    @State private var typedEmail = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private var email: String? { cloud.me?.email ?? cloud.email }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            Text("Delete Yap Cloud Account")
                .font(AppTheme.font(.headline))
            // Mirrors paygate's /privacy and docs/api.md (DELETE /v1/me).
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                bullet("Deleted: the sign-in on every device (all of them are signed out), your synced settings and their history, and the email address on the account.")
                bullet("Kept: the ledger of top-ups and charges, no longer linked to your email. It is a financial record needed to reconcile payments with Stripe and model costs with OpenRouter.")
                if let balance = cloud.balanceMicros, balance > 0 {
                    bullet(String(format: String(localized: "Your remaining balance of %@ is not refunded and can't be recovered."), YapCloud.formatUSD(micros: balance)))
                } else {
                    bullet(String(localized: "Any remaining balance is not refunded and can't be recovered."))
                }
                bullet("Database backups keep your email until they expire, at most about 89 days.")
                bullet("Signing in again with the same email creates a new, empty account without sign-up credit.")
            }
            .font(AppTheme.font(.callout))
            if let email {
                Text(String(format: String(localized: "Type %@ to confirm."), email))
                    .font(AppTheme.font(.callout, .semibold))
                TextField("Email address", text: $typedEmail)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isDeleting)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if isDeleting { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isDeleting)
                Button("Delete Account", role: .destructive, action: delete)
                    .disabled(isDeleting || !YapCloud.deletionConfirmed(typed: typedEmail, email: email))
            }
        }
        .padding(AppTheme.Spacing.x5)
        .frame(width: 460)
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x2) {
            Text(verbatim: "•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x2) {
            Text(verbatim: "•")
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func delete() {
        isDeleting = true
        errorMessage = nil
        Task { @MainActor in
            defer { isDeleting = false }
            do {
                try await cloud.deleteAccount(confirmEmail: typedEmail)
                // The synced config is gone with the account; stop syncing against it.
                UserDefaults.standard.set(false, forKey: CloudConfigSync.enabledKey)
                dismiss()
                NotificationManager.shared.showNotification(
                    title: String(localized: "Your Yap Cloud account was deleted."), type: .info, duration: 5)
                SignedInSections.warnAboutModesUsingYapCloud()
            } catch {
                // A 401 already signed this Mac out (account gone elsewhere): nothing left to delete here.
                if !cloud.isSignedIn { dismiss() }
                errorMessage = error.localizedDescription
            }
        }
    }
}
