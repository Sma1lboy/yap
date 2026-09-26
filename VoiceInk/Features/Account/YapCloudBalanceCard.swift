import SwiftUI

/// Home card for Yap Cloud users: the balance, and a prominent "add funds" entry when it drops below $1.
struct YapCloudBalanceCard: View {
    @ObservedObject private var cloud = YapCloud.shared

    var body: some View {
        card
            // Opening Home refreshes the balance (debounced), so grants made elsewhere show up here too.
            .task { cloud.scheduleBalanceRefresh() }
    }

    @ViewBuilder
    private var card: some View {
        if cloud.isSignedIn, let balance = cloud.balanceMicros {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: cloud.isLowBalance ? "exclamationmark.triangle.fill" : "creditcard")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(cloud.isLowBalance ? AppTheme.Status.warningStrong : AppTheme.Text.secondary)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(cloud.isLowBalance ? "Low Yap Cloud balance" : "Yap Cloud balance")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(verbatim: YapCloud.formatUSD(micros: balance))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(balance > 0 ? AppTheme.Text.secondary : AppTheme.Status.error)
                }

                Spacer(minLength: 12)

                if cloud.isLowBalance {
                    Button("Add Funds", action: YapCloud.showAddFunds)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Account", action: YapCloud.showAddFunds)
                        .controlSize(.small)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppCardBackground(cornerRadius: 16))
        }
    }
}

/// Once per account: the sign-up credit is nearly gone and nothing was ever paid. Shown on Home and Account.
struct YapCloudTrialNudgeBanner: View {
    @ObservedObject private var cloud = YapCloud.shared
    /// Home: a card with an Add Funds button. Account: a plain row (Add Funds is the next section).
    var isHomeCard = true

    var body: some View {
        if let nudge = cloud.trialNudge {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "gift")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.Status.warningStrong)
                    .frame(width: 34, height: 34)
                Text(message(nudge))
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if isHomeCard {
                    Button("Add Funds", action: YapCloud.showAddFunds)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
                Button {
                    cloud.dismissTrialNudge()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Don't show this again")
                .accessibilityLabel("Don't show this again")
            }
            .padding(isHomeCard ? 16 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { if isHomeCard { AppCardBackground(cornerRadius: 16) } }
        }
    }

    private func message(_ nudge: YapCloud.TrialNudge) -> String {
        guard let topUp = nudge.topUpMicros, let days = nudge.days else {
            return String(localized: "Your trial credit is almost used up. Add funds to keep dictating.")
        }
        let amount = YapCloud.formatPlainUSD(micros: topUp)
        if days > 365 {
            return String(format: String(localized: "Your trial credit is almost used up. At your pace, %@ lasts more than a year."), amount)
        }
        return String(format: String(localized: "Your trial credit is almost used up. At your pace, %@ lasts about %lld days."), amount, days)
    }
}
