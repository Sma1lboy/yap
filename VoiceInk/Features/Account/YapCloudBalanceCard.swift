import SwiftUI

/// Home card for Yap Cloud users: the balance, and a prominent "add funds" entry when it drops below $1.
struct YapCloudBalanceCard: View {
    @ObservedObject private var cloud = YapCloud.shared

    var body: some View {
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
