import SwiftUI

struct DashboardInsightCardBackground: View {
    var cornerRadius: CGFloat = DashboardLayout.cardCornerRadius

    var body: some View {
        AppCardBackground(cornerRadius: cornerRadius)
    }
}
