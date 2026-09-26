import SwiftUI

struct TranscriptionModelDownloadCard: View {
    let model: FluidAudioModel
    let isDownloaded: Bool
    let isDownloading: Bool
    let status: FluidAudioDownloadStatus?
    let errorMessage: String?
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x4) {
            header
            modelMetadata

            if let status {
                progressPanel(status)
            } else if let errorMessage, !isDownloaded {
                Text(String(format: String(localized: "Download failed: %@ Check your connection and try again."), errorMessage))
                    .font(AppTheme.font(.caption))
                    .foregroundColor(AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppTheme.Spacing.x5)
        .background(AppMaterialCardBackground(cornerRadius: AppTheme.Radius.card))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.x4) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.x3) {
                modelLogo

                VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                    Text(model.displayName)
                        .font(AppTheme.font(.headline, .semibold))
                        .foregroundColor(AppTheme.Text.primary)

                    Text("Fast multilingual transcription that runs locally on Mac.")
                        .font(AppTheme.font(.footnote))
                        .foregroundColor(AppTheme.Text.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.92)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            statusControl
        }
    }

    @ViewBuilder
    private var statusControl: some View {
        if isDownloading {
            downloadButton
                .fixedSize()
        } else if isDownloaded {
            statusBadge
                .fixedSize()
        } else {
            downloadButton
                .fixedSize()
        }
    }

    private var modelLogo: some View {
        Image("nvidia-logo")
            .resizable()
            .scaledToFit()
            .frame(width: 34, height: 28)
            .frame(width: 38, height: 38)
            .accessibilityLabel(Text(verbatim: "NVIDIA"))
    }

    private var modelMetadata: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            metadataPill(model.size)
            localizedMetadataPill("25+ languages")
            localizedMetadataPill("Local")
        }
    }

    private func metadataPill(_ text: String) -> some View {
        Text(text)
            .font(AppTheme.font(.caption, .medium))
            .foregroundColor(AppTheme.Text.secondary)
            .padding(.horizontal, AppTheme.Spacing.x2)
            .padding(.vertical, AppTheme.Spacing.x1)
            .background(Capsule().fill(AppTheme.Surface.subtle))
    }

    private func localizedMetadataPill(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(AppTheme.font(.caption, .medium))
            .foregroundColor(AppTheme.Text.secondary)
            .padding(.horizontal, AppTheme.Spacing.x2)
            .padding(.vertical, AppTheme.Spacing.x1)
            .background(Capsule().fill(AppTheme.Surface.subtle))
    }

    private func progressPanel(_ status: FluidAudioDownloadStatus) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            HStack {
                Text(status.message)
                    .lineLimit(1)

                if status.isIndeterminate {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                }

                Spacer()

                Text(status.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                    .fontDesign(.monospaced)
            }
            .font(AppTheme.font(.caption, .medium))
            .foregroundColor(AppTheme.Text.secondary)

            ProgressView(value: status.fractionCompleted)
                .progressViewStyle(.linear)
                .tint(AppTheme.Accent.primary)
        }
    }

    private var downloadButton: some View {
        Button(action: isDownloading ? onCancel : onDownload) {
            HStack(spacing: AppTheme.Spacing.x2) {
                Text(downloadButtonTitle)
                Image(systemName: isDownloading ? "xmark.circle" : "arrow.down.circle")
            }
            .font(AppTheme.font(.footnote, .semibold))
            .foregroundColor(
                isDownloading ? AppTheme.Action.destructiveForeground : AppTheme.Action.primaryForeground
            )
            .padding(.horizontal, AppTheme.Spacing.x4)
            .padding(.vertical, AppTheme.Spacing.x2)
            .background(
                Capsule()
                    .fill(isDownloading ? AppTheme.Action.destructiveFill : AppTheme.Action.primaryFill)
            )
        }
        .buttonStyle(.plain)
    }

    private var statusBadge: some View {
        Text("Downloaded")
            .font(AppTheme.font(.caption, .semibold))
            .foregroundColor(AppTheme.Text.secondary)
            .padding(.horizontal, AppTheme.Spacing.x2)
            .padding(.vertical, AppTheme.Spacing.x1)
            .background(Capsule().fill(AppTheme.Surface.controlActive))
    }

    private var downloadButtonTitle: LocalizedStringKey {
        if isDownloading {
            return "Cancel"
        }

        if status != nil {
            return "Resume Download"
        }

        if errorMessage != nil {
            return "Retry"
        }

        return "Download Model"
    }
}
