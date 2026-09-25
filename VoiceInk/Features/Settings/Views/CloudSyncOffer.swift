import SwiftUI

/// Asks once per Mac, after signing in to Yap Cloud, whether to turn on "Sync via Yap Cloud".
/// Either answer is remembered; it never asks again, and not at all if sync is already on.
struct CloudSyncOffer: ViewModifier {
    static let answeredKey = "configCloudSyncOfferAnswered"

    @ObservedObject private var cloud = YapCloud.shared
    @AppStorage(CloudConfigSync.enabledKey) private var syncEnabled = false
    @AppStorage(Self.answeredKey) private var answered = false
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onAppear(perform: update)
            .onChange(of: cloud.isSignedIn) { update() }
            .alert("Sync Settings Across Your Macs?", isPresented: $isPresented) {
                Button("Turn On") {
                    syncEnabled = true
                    answered = true
                }
                Button("No Thanks", role: .cancel) {
                    answered = true
                }
            } message: {
                Text(
                    "Modes, prompts, dictionary and shortcuts stay the same on every Mac signed in to this account. API keys stay on each Mac."
                )
            }
    }

    private func update() {
        isPresented = cloud.isSignedIn && !syncEnabled && !answered
    }
}
