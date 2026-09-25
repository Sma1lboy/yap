import AppKit
import SwiftUI

/// Yap Cloud account: sign in, balance, add funds, recent charges.
struct AccountView: View {
    @ObservedObject private var cloud = YapCloud.shared
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager

    var body: some View {
        Form {
            if cloud.isSignedIn {
                SignedInSections()
            } else {
                Section {
                    YapCloudSignInForm()
                } header: {
                    Text("Yap Cloud")
                } footer: {
                    Text("Pay as you go: one balance covers transcription and enhancement, no API keys to manage.")
                }
            }
            modelsSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .modifier(CloudSyncOffer())
        .task(id: cloud.isSignedIn) {
            await cloud.refreshAccount()
            await cloud.refreshModels()
            transcriptionModelManager.refreshAllAvailableModels()
        }
    }

    @ViewBuilder
    private var modelsSection: some View {
        if !cloud.models.isEmpty {
            Section {
                DisclosureGroup("Transcription") {
                    ForEach(cloud.transcriptionModels, id: \.id) { model in
                        ModelPriceRow(model: model)
                    }
                }
                DisclosureGroup("Enhancement") {
                    ForEach(cloud.chatModels, id: \.id) { model in
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
    @State private var amount = YapCloud.checkoutPresets[1]
    @State private var isCustomAmount = false
    @State private var customAmount = ""
    @State private var isOpeningCheckout = false
    @State private var errorMessage: String?
    @State private var isConfirmingSignOut = false

    var body: some View {
        Section("Yap Cloud") {
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
        }

        Section {
            Picker("Amount", selection: $isCustomAmount) {
                Text("Preset").tag(false)
                Text("Custom").tag(true)
            }
            .pickerStyle(.segmented)
            if isCustomAmount {
                LabeledContent("Amount (USD)") {
                    TextField("", text: $customAmount, prompt: Text(verbatim: "50"))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
            } else {
                Picker("Amount (USD)", selection: $amount) {
                    ForEach(YapCloud.checkoutPresets, id: \.self) { preset in
                        Text(verbatim: "$\(preset)").tag(preset)
                    }
                }
                .pickerStyle(.segmented)
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
        } header: {
            Text("Add Funds")
        } footer: {
            Text("Checkout opens in your browser. Your balance updates when you come back to Yap.")
        }

        if let spend = cloud.monthlySpend {
            Section {
                LabeledContent("Total") {
                    Text(YapCloud.formatLedgerAmount(micros: spend.totalMicros, kind: "usage"))
                        .monospacedDigit()
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
                    }
                }
            } header: {
                Text("This Month")
            }
        }

        Section("Recent Activity") {
            if !cloud.isLedgerLoaded {
                if cloud.isRefreshingAccount {
                    ProgressView().controlSize(.small)
                } else {
                    HStack {
                        Text("Couldn't load recent activity.")
                            .foregroundStyle(AppTheme.Status.error)
                        Spacer()
                        Button("Retry") { Task { await cloud.refreshAccount() } }
                    }
                }
            } else if cloud.ledger.isEmpty {
                Text("No charges or top-ups yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(cloud.ledger, id: \.id.string) { entry in
                    LedgerRow(entry: entry)
                }
            }
        }
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
        let value = isCustomAmount
            ? Int(customAmount.trimmingCharacters(in: CharacterSet(charactersIn: "$ ").union(.whitespaces)))
            : amount
        guard let value, YapCloud.isValidTopUp(value) else {
            errorMessage = YapCloudError.invalidAmount.errorDescription
            return
        }
        errorMessage = nil
        isOpeningCheckout = true
        Task {
            defer { isOpeningCheckout = false }
            do {
                NSWorkspace.shared.open(try await cloud.checkoutURL(amountUSD: value))
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
            Text((entry.amountMicros > 0 ? "+" : "") + YapCloud.formatLedgerAmount(micros: entry.amountMicros, kind: entry.kind))
                .monospacedDigit()
                .foregroundStyle(entry.amountMicros > 0 ? AppTheme.Status.positive : AppTheme.Text.primary)
        }
    }

    private var title: String {
        switch entry.kind {
        case "topup": return String(localized: "Top-up")
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
        let perMillion = { (key: String) in
            ((model.price(key) ?? 0) * 1_000_000).formatted(.currency(code: "USD").precision(.fractionLength(2)))
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if codeSent {
                Text(String(format: String(localized: "Enter the 6-digit code sent to %@."), email))
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Code", text: $code)
                        .textFieldStyle(.roundedBorder)
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
        }
    }

    private func open(_ amount: Int) {
        isOpening = true
        errorMessage = nil
        Task { @MainActor in
            defer { isOpening = false }
            do {
                NSWorkspace.shared.open(try await YapCloud.shared.checkoutURL(amountUSD: amount))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
