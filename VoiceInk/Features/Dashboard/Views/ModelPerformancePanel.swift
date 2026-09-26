import SwiftUI

struct ModelPerformancePanel: View {
    let summaries: [ModelPerformanceSummary]
    let onClose: () -> Void

    var body: some View {
        QuickPanelScaffold {
            ModelPerformancePanelContent(summaries: summaries)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } header: {
            header
        } footer: {
            RecommendedModelsFooter()
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            Text("AI Model Performance")
                .font(.headline.weight(.semibold))

            Spacer()

            AppIconButton(
                systemName: "xmark",
                help: "Close",
                size: 28,
                iconSize: 14,
                cornerRadius: AppTheme.Radius.control,
                action: onClose
            )
        }
        .padding(.horizontal, AppTheme.Spacing.x5)
        .frame(height: QuickPanelMetrics.headerHeight)
    }

}

private struct ModelPerformancePanelContent: View {
    let summaries: [ModelPerformanceSummary]

    private func makeTranscriptionRows() -> [ModelPerformanceDetailRowData] {
        summaries
            .filter { $0.kind == .transcription }
            .map { summary in
                return ModelPerformanceDetailRowData(
                    name: summary.name,
                    kind: .transcription,
                    averageProcessingTime: summary.averageProcessingDuration ?? 0,
                    averageLatencyText: Formatters.formattedPreciseDuration(
                        summary.averageProcessingDuration ?? 0, fallback: "-"),
                    detail: summary.averageSpeedFactor.flatMap { speedFactor in
                        speedFactor > 0 ? String(format: String(localized: "%.1fx realtime"), speedFactor) : nil
                    }
                )
            }
            .sortedForPerformanceDetails()
    }

    private func makeEnhancementRows() -> [ModelPerformanceDetailRowData] {
        summaries
            .filter { $0.kind == .enhancement }
            .map { summary in
                return ModelPerformanceDetailRowData(
                    name: summary.name,
                    kind: .enhancement,
                    averageProcessingTime: summary.averageProcessingDuration ?? 0,
                    averageLatencyText: Formatters.formattedPreciseDuration(
                        summary.averageProcessingDuration ?? 0, fallback: "-"),
                    detail: nil
                )
            }
            .sortedForPerformanceDetails()
    }

    var body: some View {
        let transcriptionRows = makeTranscriptionRows()
        let enhancementRows = makeEnhancementRows()

        if transcriptionRows.isEmpty && enhancementRows.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.x6) {
                    ModelPerformanceDetailSection(
                        title: "Transcription Models",
                        valueTitle: "Avg. latency",
                        emptyTitle: "No transcription timings",
                        emptyIcon: "timer",
                        rows: transcriptionRows
                    )

                    ModelPerformanceDetailSection(
                        title: "Enhancement Models",
                        valueTitle: "Avg. latency",
                        emptyTitle: "No enhancement timings",
                        emptyIcon: "sparkles",
                        rows: enhancementRows
                    )
                }
                .padding(.horizontal, AppTheme.Spacing.x5)
                .padding(.top, 76)  // design-exempt: layout offset, not spacing
                .padding(.bottom, 72)  // design-exempt: layout offset, not spacing
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.x2) {
            Image(systemName: "chart.bar.xaxis")
                .font(AppTheme.font(.display, .regular))
                .foregroundColor(.secondary)

            Text("No model performance for this period")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ModelPerformanceDetailSection: View {
    let title: LocalizedStringKey
    let valueTitle: LocalizedStringKey
    let emptyTitle: LocalizedStringKey
    let emptyIcon: String
    let rows: [ModelPerformanceDetailRowData]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x4) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x3) {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(valueTitle)
                    .font(AppTheme.font(.caption, .semibold))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(width: 96, alignment: .trailing)
                    .padding(.trailing, AppTheme.Spacing.x1)
            }
            .font(AppTheme.font(.body, .semibold))
            .foregroundStyle(AppTheme.Text.primary)
            .lineLimit(1)

            if rows.isEmpty {
                InsightEmptyState(title: emptyTitle, icon: emptyIcon)
            } else {
                VStack(spacing: AppTheme.Spacing.x2) {
                    ForEach(rows) { row in
                        ModelPerformanceDetailRow(row: row)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ModelPerformanceDetailRow: View {
    let row: ModelPerformanceDetailRowData

    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.x3) {
            ModelProviderIcon(modelName: row.name, kind: row.kind, size: 24)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                Text(row.name)
                    .font(AppTheme.font(.footnote, .semibold))
                    .foregroundStyle(AppTheme.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .truncationMode(.tail)

                if let detail = row.detail {
                    HStack(spacing: AppTheme.Spacing.x2) {
                        Text(detail)
                            .font(AppTheme.font(.micro, .medium))
                            .foregroundStyle(AppTheme.Text.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.averageLatencyText)
                .font(AppTheme.font(.body, .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, AppTheme.Spacing.x3)
        .padding(.vertical, AppTheme.Spacing.x3)
        .background(AppCardBackground(cornerRadius: AppTheme.Radius.control))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.name)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if let detail = row.detail {
            return String(localized: "\(row.kindTitle), \(row.averageLatencyText), \(detail)")
        }

        return String(localized: "\(row.kindTitle), \(row.averageLatencyText)")
    }
}

private struct ModelPerformanceDetailRowData: Identifiable {
    var id: String { "\(kind.rawValue)-\(name)" }
    let name: String
    let kind: ModelInsightKind
    let averageProcessingTime: TimeInterval
    let averageLatencyText: String
    let detail: String?

    var kindTitle: String {
        kind == .transcription ? String(localized: "Transcription") : String(localized: "Enhancement")
    }
}

private extension Array where Element == ModelPerformanceDetailRowData {
    func sortedForPerformanceDetails() -> [ModelPerformanceDetailRowData] {
        sorted { lhs, rhs in
            if lhs.averageProcessingTime != rhs.averageProcessingTime {
                return lhs.averageProcessingTime < rhs.averageProcessingTime
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
