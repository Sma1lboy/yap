import SwiftData
import SwiftUI

/// History detail line for a Yap Cloud dictation: "Cost $0.0003 (transcription + enhancement)".
/// Looked up once by generation id, then cached on the record; not cached while a charge is still settling.
struct YapCloudCostRow: View {
    let transcription: Transcription
    @Environment(\.modelContext) private var modelContext
    @State private var isLoading = false
    @State private var isPending = false

    private var generationIDs: [String] {
        [transcription.yapCloudTranscriptionGenerationID, transcription.yapCloudEnhancementGenerationID]
            .compactMap { $0 }
    }

    private var parts: String {
        switch (transcription.yapCloudTranscriptionGenerationID != nil, transcription.yapCloudEnhancementGenerationID != nil) {
        case (true, true): return String(localized: "transcription + enhancement")
        case (true, false): return String(localized: "transcription")
        default: return String(localized: "enhancement")
        }
    }

    var body: some View {
        if transcription.usedYapCloud == true, !generationIDs.isEmpty {
            HStack(spacing: 6) {
                if let cost = transcription.yapCloudCostMicros {
                    Text(String(format: String(localized: "Cost %@ (%@)"),
                                YapCloud.formatLedgerAmount(micros: cost, kind: "usage"), parts))
                        .monospacedDigit()
                } else if isLoading {
                    ProgressView().controlSize(.mini)
                } else if isPending {
                    Text("Cost not available yet")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(AppTheme.Text.secondary)
            .task(id: transcription.id) { await loadIfNeeded() }
        }
    }

    private func loadIfNeeded() async {
        guard transcription.yapCloudCostMicros == nil, YapCloud.shared.isSignedIn else { return }
        isLoading = true
        defer { isLoading = false }
        let ids = generationIDs
        guard let charges = try? await YapCloud.shared.fetchCharges(generationIDs: ids) else { return }
        guard ids.allSatisfy({ charges[$0] != nil }) else {
            isPending = true
            return
        }
        transcription.yapCloudCostMicros = ids.reduce(0) { $0 + (charges[$1] ?? 0) }
        try? modelContext.save()
    }
}
