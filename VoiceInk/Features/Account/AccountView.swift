import AppKit
import SwiftUI

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
        Form {
            if cloud.isUnreachable {
                Section {
                    Label("Yap Cloud is temporarily unavailable. Try again shortly.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(AppTheme.Status.warningStrong)
                }
            }
            if cloud.isSignedIn, cloud.trialNudge != nil {
                Section { YapCloudTrialNudgeBanner(isHomeCard: false) }
            }
            if cloud.isSignedIn {
                SignedInSections()
            } else {
                Section {
                    YapCloudSignInForm()
                } header: {
                    Text("Yap Cloud")
                } footer: {
                    Text("Pay as you go: one balance covers transcription and enhancement, no API keys to manage. New accounts get $1 of free credit.")
                }
            }
            modelsSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
            Section {
                ForEach(recommendedModels, id: \.id) { model in
                    ModelPriceRow(model: model)
                }
                DisclosureGroup("All Models", isExpanded: $isShowingAllModels) {
                    TextField("Search models", text: $modelQuery)
                        .textFieldStyle(.roundedBorder)
                    ForEach(allModels, id: \.id) { model in
                        ModelPriceRow(model: model)
                    }
                }
            } header: {
                Text("Models & Pricing")
            } footer: {
                // The paygate host is only useful when pointing a dev build at another server.
                #if DEBUG
                    Text(String(format: String(localized: "Server: %@"), cloud.baseURL.absoluteString))
                #endif
            }
        }
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

    var body: some View {
        Section {
            LabeledContent("Email address", value: cloud.me?.email ?? cloud.email ?? "")
            LabeledContent {
                if let balance = cloud.balanceMicros {
                    Text(YapCloud.formatUSD(micros: balance))
                        .monospacedDigit()
                        .foregroundStyle(balance > 0 ? AppTheme.Text.primary : AppTheme.Status.error)
                } else if cloud.isRefreshingAccount {
                    ProgressView().controlSize(.small)
                } else {
                    Text(verbatim: "—").foregroundStyle(.secondary)
                }
            } label: {
                Text("Balance")
                if let updatedAt = cloud.balanceUpdatedAt {
                    Text(
                        String(
                            format: String(localized: "Last updated %@"),
                            updatedAt.formatted(date: .abbreviated, time: .shortened)))
                }
            }
            if let runway = balanceRunway {
                let pace = YapCloud.formatAverage(micros: runway.monthlyMicros)
                Text(
                    runway.days > 365
                        ? String(format: String(localized: "At this month's pace (%@ a month), your balance lasts more than a year."), pace)
                        : runway.days == 0
                            ? String(format: String(localized: "At this month's pace (%@ a month), your balance lasts less than a day."), pace)
                            : String(
                                format: String(localized: "At this month's pace (%@ a month), your balance lasts about %lld days."),
                                pace, runway.days))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = cloud.accountRefreshError {
                Text(String(format: String(localized: "Couldn't refresh your account: %@"), error))
                    .font(.caption)
                    .foregroundStyle(AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Refresh") { Task { await cloud.refreshAccount() } }
                    .disabled(cloud.isRefreshingAccount)
                if cloud.isRefreshingAccount { ProgressView().controlSize(.small) }
                Spacer()
                Button("Sign Out") { isConfirmingSignOut = true }
                    .confirmationDialog(
                        "Sign out of Yap Cloud?", isPresented: $isConfirmingSignOut
                    ) {
                        Button("Sign Out", role: .destructive, action: signOut)
                    } message: {
                        Text("Modes that use Yap Cloud stop working until you sign in again or switch them to another provider.")
                    }
            }
        } header: {
            Text("Yap Cloud")
        } footer: {
            Text("With Sync via Yap Cloud on (Settings > Config & Sync), your modes, prompts, dictionary, shortcuts and custom models are stored on Yap's server. API keys stay on each Mac.")
        }

        Section {
            Picker("Amount (USD)", selection: $amount) {
                ForEach(YapCloud.checkoutPresets, id: \.self) { preset in
                    Text(verbatim: "$\(preset)").tag(Int?.some(preset))
                }
                Text("Custom").tag(Int?.none)
            }
            .pickerStyle(.segmented)
            .onChange(of: amount) { _, _ in errorMessage = nil }
            if amount == nil {
                LabeledContent("Custom Amount (USD)") {
                    TextField("", text: $customAmount, prompt: Text(verbatim: "50"))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
            }
            HStack {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Status.error)
                }
                Spacer()
                if isOpeningCheckout { ProgressView().controlSize(.small) }
                Button("Add Funds…", action: openCheckout)
                    .disabled(isOpeningCheckout)
            }
            if cloud.pendingTopUp != nil {
                YapCloudTopUpWaitingRow()
            }
        } header: {
            Text("Add Funds")
        } footer: {
            Text("Checkout opens in your browser. Your balance updates when you come back to Yap.")
        }

        if let spend = cloud.monthlySpend {
            Section {
                LabeledContent("Total") {
                    if let cap = cloud.me?.monthlyCapMicros {
                        let spent = cloud.me?.monthSpentMicros ?? spend.totalMicros
                        Text(
                            String(
                                format: String(localized: "%@ used of %@ cap"),
                                YapCloud.formatLedgerAmount(micros: spent, kind: "usage"), YapCloud.formatExactUSD(micros: cap))
                        )
                        .monospacedDigit()
                        .foregroundStyle(spent >= cap ? AppTheme.Status.error : AppTheme.Text.primary)
                    } else {
                        Text(YapCloud.formatLedgerAmount(micros: spend.totalMicros, kind: "usage"))
                            .monospacedDigit()
                    }
                }
                if spend.creditMicros > 0 {
                    LabeledContent("Covered by sign-up credit") {
                        Text(YapCloud.formatLedgerAmount(micros: spend.creditMicros, kind: "usage"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(spend.topModels, id: \.model) { item in
                    LabeledContent {
                        Text(YapCloud.formatLedgerAmount(micros: item.micros, kind: "usage"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(item.model ?? String(localized: "Other"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let average = YapCloudMonthlySpend.averageMicros(item.micros, calls: item.calls) {
                            Text(
                                String(
                                    format: String(localized: "%lld calls · %@ / call"), Int64(item.calls),
                                    YapCloud.formatAverage(micros: average)))
                        }
                    }
                }
            } header: {
                Text("This Month")
            }
        }

        MonthlyCapSection()

        Section("Recent Activity") {
            if let ledger = cloud.ledger {
                if ledger.isEmpty {
                    Text("No charges or top-ups yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ledger, id: \.id.string) { entry in
                        LedgerRow(entry: entry)
                    }
                }
            } else if cloud.isRefreshingAccount {
                ProgressView().controlSize(.small)
            } else {
                HStack {
                    Text("Couldn't load recent activity.")
                        .foregroundStyle(AppTheme.Status.error)
                    Spacer()
                    Button("Retry") { Task { await cloud.refreshAccount() } }
                }
            }
        }

        if let devices = cloud.devices {
            DevicesSection(devices: devices)
        } else if let error = cloud.devicesError {
            Section("Signed-in Devices") {
                HStack {
                    Text(String(format: String(localized: "Couldn't load devices: %@"), error))
                        .foregroundStyle(AppTheme.Status.error)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Retry") { Task { await cloud.refreshDevices() } }
                }
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

    private func signOut() {
        cloud.signOut()
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
        guard let value, YapCloud.isValidTopUp(value) else {
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
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let date = entry.createdDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if entry.kind == "topup", let receipt = entry.receiptURL {
                Link("Receipt", destination: receipt)
                    .font(.caption)
            }
            Text((entry.amountMicros > 0 ? "+" : "") + YapCloud.formatLedgerAmount(micros: entry.amountMicros, kind: entry.kind))
                .monospacedDigit()
                .foregroundStyle(entry.amountMicros > 0 ? AppTheme.Status.positive : AppTheme.Text.primary)
        }
    }

    private var title: String {
        switch entry.kind {
        case "topup": return String(localized: "Top-up")
        case "credit": return String(localized: "Sign-up bonus")
        case "usage":
            guard let model = entry.model else { return String(localized: "Usage") }
            return YapCloud.shared.models.first { $0.id == model }?.displayName ?? model
        default: return String(localized: "Adjustment")
        }
    }
}

private struct ModelPriceRow: View {
    let model: YapCloudModel

    var body: some View {
        LabeledContent {
            Text(price)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } label: {
            Text(model.displayName)
            Text(model.id)
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
        VStack(alignment: .leading, spacing: 10) {
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
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || codeDigits.count != 6)
                }
                HStack(spacing: 16) {
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
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || !email.contains("@"))
                }
            }
            HStack(spacing: 6) {
                if isWorking { ProgressView().controlSize(.small) }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(YapCloud.checkoutPresets, id: \.self) { amount in
                    Button(String(format: String(localized: "Add $%lld"), Int64(amount))) { open(amount) }
                        .disabled(isOpening)
                }
                if isOpening { ProgressView().controlSize(.small) }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
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
        Section {
            Picker("Monthly Cap", selection: $choice) {
                Text("No Cap").tag(Choice.none)
                ForEach(YapCloud.monthlyCapPresets, id: \.self) { dollars in
                    Text(verbatim: "$\(dollars)").tag(Choice.preset(dollars))
                }
                Text("Custom").tag(Choice.custom)
            }
            if choice == .custom {
                LabeledContent("Cap (USD)") {
                    TextField("", text: $customDollars, prompt: Text(verbatim: "50"))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
            }
            HStack {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Status.error)
                }
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Save", action: save)
                    .disabled(isSaving || pendingCapMicros == .invalid || pendingCapMicros == .value(savedCapMicros))
            }
        } header: {
            Text("Monthly Cap")
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
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Waiting for payment to complete…")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Stop Waiting") { cloud.stopWaitingForTopUp() }
                .buttonStyle(.link)
        }
        .font(.callout)
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
        Section {
            ForEach(devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(name(device))
                            if device.current {
                                Text("This Mac")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(AppTheme.Surface.subtle))
                            }
                        }
                        if let date = device.lastUsedDate {
                            Text(String(format: String(localized: "Last used %@"), date.formatted(.relative(presentation: .named))))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !device.current {
                        if removingID == device.id.string {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Sign Out") { pendingRemoval = device }
                                .disabled(removingID != nil)
                                .accessibilityLabel(String(format: String(localized: "Sign out %@"), name(device)))
                        }
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Status.error)
            }
        } header: {
            Text("Signed-in Devices")
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
