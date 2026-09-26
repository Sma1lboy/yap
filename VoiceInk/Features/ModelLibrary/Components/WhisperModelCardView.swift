import AppKit
import SwiftUI

// MARK: - Local Model Card View
struct WhisperModelCardView: View {
    let model: WhisperModel
    let isDownloaded: Bool
    let downloadProgress: [String: Double]
    let modelURL: URL?
    let isWarming: Bool

    // Actions
    var deleteAction: () -> Void
    var downloadAction: () -> Void
    var cancelDownloadAction: () -> Void
    private var isDownloading: Bool {
        downloadProgress.keys.contains(model.name + "_main") || downloadProgress.keys.contains(model.name + "_coreml")
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.x4) {
            // Main Content
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                headerSection
                metadataSection
                descriptionSection
                progressSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Action Controls
            actionSection
        }
        .padding(AppTheme.Spacing.x4)
        .background(AppMaterialCardBackground())
    }

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.displayName)
                .font(AppTheme.font(.body, .semibold))
                .foregroundColor(Color(.labelColor))

            Spacer()
        }
    }

    private var metadataSection: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            // Language
            Label(model.language, systemImage: "globe")
                .font(AppTheme.font(.caption))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)

            // Size
            Label(model.size, systemImage: "internaldrive")
                .font(AppTheme.font(.caption))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)

            // Speed
            HStack(spacing: AppTheme.Spacing.x1) {
                Text("Speed")
                    .font(AppTheme.font(.caption, .medium))
                    .foregroundColor(Color(.secondaryLabelColor))
                progressDotsWithNumber(value: model.speed * 10)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)

            // Accuracy
            HStack(spacing: AppTheme.Spacing.x1) {
                Text("Accuracy")
                    .font(AppTheme.font(.caption, .medium))
                    .foregroundColor(Color(.secondaryLabelColor))
                progressDotsWithNumber(value: model.accuracy * 10)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .lineLimit(1)
    }

    private var descriptionSection: some View {
        Text(model.description)
            .font(AppTheme.font(.caption))
            .foregroundColor(Color(.secondaryLabelColor))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, AppTheme.Spacing.x1)
    }

    private var progressSection: some View {
        Group {
            if isDownloading || isWarming {
                DownloadProgressView(
                    modelName: model.name,
                    downloadProgress: downloadProgress,
                    isOptimizing: isWarming && !isDownloading
                )
                .padding(.top, AppTheme.Spacing.x2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var actionSection: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            if isDownloaded {
                modelStatusPill("Downloaded", systemImage: "checkmark.circle")
            } else {
                Button(action: isDownloading ? cancelDownloadAction : downloadAction) {
                    HStack(spacing: AppTheme.Spacing.x1) {
                        Text(LocalizedStringKey(isDownloading ? "Cancel" : "Download"))
                            .font(AppTheme.font(.footnote, .medium))
                        Image(systemName: isDownloading ? "xmark.circle" : "arrow.down.circle")
                            .font(AppTheme.font(.footnote, .medium))
                    }
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

            if isDownloaded {
                Menu {
                    Button(action: deleteAction) {
                        Label("Delete Model", systemImage: "trash")
                    }

                    Button {
                        if let modelURL = modelURL {
                            NSWorkspace.shared.selectFile(modelURL.path, inFileViewerRootedAtPath: "")
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
            }
        }
    }
}

// MARK: - Imported Local Model (minimal UI)
struct ImportedWhisperModelCardView: View {
    let model: ImportedWhisperModel
    let isDownloaded: Bool
    let modelURL: URL?

    var deleteAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.x4) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.displayName)
                        .font(AppTheme.font(.body, .semibold))
                        .foregroundColor(Color(.labelColor))
                    Spacer()
                }

                Text("Imported local model")
                    .font(AppTheme.font(.caption))
                    .foregroundColor(Color(.secondaryLabelColor))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, AppTheme.Spacing.x1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: AppTheme.Spacing.x2) {
                if isDownloaded {
                    modelStatusPill("Imported", systemImage: "checkmark.circle")
                }

                if isDownloaded {
                    Menu {
                        Button(action: deleteAction) {
                            Label("Delete Model", systemImage: "trash")
                        }
                        Button {
                            if let modelURL = modelURL {
                                NSWorkspace.shared.selectFile(modelURL.path, inFileViewerRootedAtPath: "")
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
                }
            }
        }
        .padding(AppTheme.Spacing.x4)
        .background(AppMaterialCardBackground())
    }
}

// MARK: - Helper Views and Functions

func progressDotsWithNumber(value: Double) -> some View {
    HStack(spacing: AppTheme.Spacing.x1) {
        progressDots(value: value)
        Text(String(format: "%.1f", value))
            .font(AppTheme.font(.micro, .medium, design: .monospaced))
            .foregroundColor(Color(.secondaryLabelColor))
    }
}

func progressDots(value: Double) -> some View {
    HStack(spacing: AppTheme.Spacing.half) {
        ForEach(0..<5) { index in
            Circle()
                .fill(index < Int(value / 2) ? performanceColor(value: value / 10) : Color(.quaternaryLabelColor))
                .frame(width: 6, height: 6)
        }
    }
}

func performanceColor(value: Double) -> Color {
    switch value {
    case 0.8...1.0: return AppTheme.Status.positive
    case 0.6..<0.8: return AppTheme.Data.yellow
    case 0.4..<0.6: return AppTheme.Status.warningStrong
    default: return AppTheme.Status.error
    }
}

func modelStatusPill(_ text: LocalizedStringKey, systemImage: String) -> some View {
    Label(text, systemImage: systemImage)
        .font(AppTheme.font(.caption, .medium))
        .foregroundColor(Color(.secondaryLabelColor))
        .padding(.horizontal, AppTheme.Spacing.x2)
        .padding(.vertical, AppTheme.Spacing.x1)
        .background(AppTheme.Surface.card)
        .clipShape(Capsule())
}
