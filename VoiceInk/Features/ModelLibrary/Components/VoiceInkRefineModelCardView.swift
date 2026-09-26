import AppKit
import SwiftUI

struct VoiceInkRefineModelCardView: View {
    @ObservedObject var service: VoiceInkRefineService
    let deleteAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.x4) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                headerSection
                metadataSection
                descriptionSection
                progressSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionSection
        }
        .padding(AppTheme.Spacing.x4)
        .background(AppMaterialCardBackground())
    }

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: VoiceInkRefineService.displayModelName)
                .font(AppTheme.font(.callout, .semibold))
                .foregroundStyle(Color(.labelColor))

            Text("New")
                .font(AppTheme.font(.micro, .medium))
                .foregroundColor(AppTheme.Text.primary)
                .padding(.horizontal, AppTheme.Spacing.x2)
                .padding(.vertical, AppTheme.Spacing.half)
                .background(Capsule().fill(AppTheme.Accent.fillSubtle))

            Spacer()
        }
    }

    private var metadataSection: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            Label("Enhancement Model", systemImage: "sparkles")
            Label("On-Device", systemImage: "checkmark.shield")
            Label {
                Text(verbatim: VoiceInkRefineService.downloadSizeDescription)
            } icon: {
                Image(systemName: "internaldrive")
            }
        }
        .font(AppTheme.font(.caption))
        .foregroundColor(Color(.secondaryLabelColor))
        .lineLimit(1)
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
            Text("Cleans up raw transcripts. Processing stays on your Mac.")
                .font(AppTheme.font(.caption))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let unavailableDescription = service.unavailableDescription {
                Text(unavailableDescription)
                    .font(AppTheme.font(.caption, .medium))
                    .foregroundStyle(AppTheme.Status.warningStrong)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, AppTheme.Spacing.x1)
    }

    @ViewBuilder
    private var progressSection: some View {
        if service.isDownloading {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                HStack {
                    Text(downloadDetail)
                        .lineLimit(1)

                    Spacer()

                    Text(
                        service.downloadProgress,
                        format: .percent.precision(.fractionLength(0))
                    )
                    .fontDesign(.monospaced)
                }
                .font(AppTheme.font(.caption, .medium))
                .foregroundColor(Color(.secondaryLabelColor))

                ProgressView(value: service.downloadProgress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Model download progress")
                    .accessibilityValue(Text(verbatim: downloadAccessibilityValue))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, AppTheme.Spacing.x2)
        }

        if let downloadError = service.downloadError {
            Text(downloadError)
                .font(AppTheme.font(.caption, .medium))
                .foregroundStyle(AppTheme.Status.error)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, AppTheme.Spacing.x1)
        }
    }

    private var actionSection: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            switch service.availability {
            case .unsupportedIntel, .insufficientMemory:
                modelStatusPill("Unavailable", systemImage: "exclamationmark.triangle")
            case .available:
                if service.isDownloading {
                    Button {
                        service.cancelDownload()
                    } label: {
                        HStack(spacing: AppTheme.Spacing.x1) {
                            Text("Cancel")
                            Image(systemName: "xmark.circle")
                        }
                        .font(AppTheme.font(.footnote, .medium))
                        .foregroundColor(AppTheme.Text.primary)
                        .padding(.horizontal, AppTheme.Spacing.x3)
                        .padding(.vertical, AppTheme.Spacing.x2)
                        .background(Capsule().fill(AppTheme.Surface.control).overlay(Capsule().strokeBorder(AppTheme.Border.control)))
                    }
                    .buttonStyle(.plain)
                } else if service.isDownloaded {
                    modelStatusPill("Downloaded", systemImage: "checkmark.circle")

                    Menu {
                        Button(role: .destructive, action: deleteAction) {
                            Label("Delete Model", systemImage: "trash")
                        }

                        Button {
                            if let modelURL = service.downloadedModelURL {
                                NSWorkspace.shared.selectFile(
                                    modelURL.path,
                                    inFileViewerRootedAtPath: ""
                                )
                            }
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(AppTheme.font(.callout))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("More Actions")
                    .accessibilityLabel("More Actions")
                    .frame(width: 20, height: 20)
                } else {
                    Button {
                        service.startDownload()
                    } label: {
                        HStack(spacing: AppTheme.Spacing.x1) {
                            if service.downloadError == nil {
                                Text("Download")
                            } else {
                                Text("Retry")
                            }
                            Image(systemName: "arrow.down.circle")
                        }
                        .font(AppTheme.font(.footnote, .medium))
                        .foregroundColor(AppTheme.Text.primary)
                        .padding(.horizontal, AppTheme.Spacing.x3)
                        .padding(.vertical, AppTheme.Spacing.x2)
                        .background(
                            Capsule()
                                .fill(AppTheme.Surface.control)
                                .overlay(Capsule().strokeBorder(AppTheme.Border.control))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var downloadDetail: String {
        if service.isFinalizingDownload {
            return String(localized: "Finalizing model files…")
        }

        let downloaded = ByteCountFormatter.string(
            fromByteCount: service.downloadedBytes,
            countStyle: .file
        )
        let total = ByteCountFormatter.string(
            fromByteCount: service.totalDownloadBytes,
            countStyle: .file
        )

        return String(
            format: String(localized: "%@ of %@"),
            downloaded,
            total
        )
    }

    private var downloadAccessibilityValue: String {
        let percentage = service.downloadProgress.formatted(
            .percent.precision(.fractionLength(0))
        )
        return "\(percentage). \(downloadDetail)"
    }
}
