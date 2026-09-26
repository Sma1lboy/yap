import SwiftUI

struct ModelUsagePanel: View {
    let summary: ModelUsageSummary
    let onClose: () -> Void

    var body: some View {
        QuickPanelScaffold {
            ModelUsagePanelContent(summary: summary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } header: {
            header
        } footer: {
            RecommendedModelsFooter()
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            Text("AI Model Usage")
                .font(AppTheme.font(.body, .semibold))

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

struct RecommendedModelsFooter: View {
    var body: some View {
        HStack {
            Spacer()

            Button(action: ModelLinks.openRecommendedModels) {
                ModelActionLabel(
                    title: "Recommended Models",
                    icon: "sparkles",
                    isPrimary: true
                )
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: true)
            .help(String(localized: "Open recommended AI models"))
        }
        .padding(.horizontal, AppTheme.Spacing.x5)
        .frame(height: QuickPanelMetrics.footerHeight)
    }
}

private struct ModelUsagePanelContent: View {
    let summary: ModelUsageSummary

    var body: some View {
        if summary.hasData {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.x6) {
                    ModelUsageSection(
                        title: "Transcription Models",
                        valueTitle: "Est. duration",
                        emptyTitle: "No audio duration",
                        emptyIcon: "waveform",
                        tint: AppTheme.Status.infoStrong,
                        rows: summary.transcriptionModels.map { summary in
                            ModelUsageDistributionRowData(
                                name: summary.name,
                                kind: .transcription,
                                value: ModelUsageFormatting.duration(summary.totalAudioDuration),
                                amount: summary.totalAudioDuration
                            )
                        }
                    )

                    ModelUsageSection(
                        title: "Enhancement Models",
                        valueTitle: "Est. tokens",
                        emptyTitle: "No token estimates",
                        emptyIcon: "number",
                        tint: AppTheme.Status.positive,
                        rows: summary.enhancementModels.map { summary in
                            ModelUsageDistributionRowData(
                                name: summary.name,
                                kind: .enhancement,
                                value: ModelUsageFormatting.tokenCount(summary.estimatedTokens),
                                amount: Double(summary.estimatedTokens)
                            )
                        }
                    )
                }
                .padding(.horizontal, AppTheme.Spacing.x5)
                .padding(.top, 76)  // design-exempt: layout offset, not spacing
                .padding(.bottom, 72)  // design-exempt: layout offset, not spacing
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.x2) {
            Image(systemName: "chart.bar.xaxis")
                .font(AppTheme.font(.display, .regular))
                .foregroundColor(.secondary)

            Text("No model usage for this period")
                .font(AppTheme.font(.caption))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ModelUsageSection: View {
    let title: LocalizedStringKey
    let valueTitle: LocalizedStringKey
    let emptyTitle: LocalizedStringKey
    let emptyIcon: String
    let tint: Color
    let rows: [ModelUsageDistributionRowData]

    private var totalAmount: Double {
        rows.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x3) {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(valueTitle)
                    .font(AppTheme.font(.caption, .semibold))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(width: 74, alignment: .trailing)
                    .padding(.trailing, AppTheme.Spacing.x1)
            }
            .font(AppTheme.font(.body, .semibold))
            .foregroundStyle(AppTheme.Text.primary)
            .lineLimit(1)

            if rows.isEmpty {
                InsightEmptyState(title: emptyTitle, icon: emptyIcon)
            } else {
                VStack(spacing: AppTheme.Spacing.x3) {
                    ForEach(rows) { row in
                        ModelUsageDistributionRow(
                            row: row,
                            share: share(for: row),
                            tint: tint
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func share(for row: ModelUsageDistributionRowData) -> Double {
        guard totalAmount > 0 else {
            return 0
        }

        return row.amount / totalAmount
    }
}

private struct ModelUsageDistributionRow: View {
    let row: ModelUsageDistributionRowData
    let share: Double
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.x3) {
            ModelProviderIcon(modelName: row.name, kind: row.kind, size: 24)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x2) {
                    Text(row.name)
                        .font(AppTheme.font(.footnote, .semibold))
                        .foregroundStyle(AppTheme.Text.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(share, format: .percent.precision(.fractionLength(0)))
                        .font(AppTheme.font(.micro, .medium, design: .rounded))
                        .foregroundStyle(AppTheme.Text.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(width: 34, alignment: .trailing)
                        .layoutPriority(1)
                }

                ModelUsageShareBar(share: share, tint: tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.value)
                .font(AppTheme.font(.footnote, .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, AppTheme.Spacing.x3)
        .padding(.vertical, AppTheme.Spacing.x3)
        .background(AppCardBackground(cornerRadius: AppTheme.Radius.control))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.name)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        String(localized: "\(row.kindTitle), \(row.value), \(share.formatted(.percent.precision(.fractionLength(0))))")
    }
}

private struct ModelUsageDistributionRowData: Identifiable {
    var id: String { name }
    let name: String
    let kind: ModelInsightKind
    let value: String
    let amount: Double

    var kindTitle: String {
        kind == .transcription ? String(localized: "Transcription") : String(localized: "Enhancement")
    }
}

private struct ModelUsageShareBar: View {
    let share: Double
    let tint: Color

    private var normalizedShare: Double {
        min(max(share, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let filledWidth = geometry.size.width * CGFloat(normalizedShare)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.Surface.subtle)

                if normalizedShare > 0 {
                    Capsule()
                        .fill(tint.opacity(0.82))
                        .frame(width: max(6, filledWidth))
                }
            }
        }
        .frame(height: 5)
    }
}
