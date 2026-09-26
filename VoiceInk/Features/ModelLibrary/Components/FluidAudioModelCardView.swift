import AppKit
import SwiftUI

struct FluidAudioModelCardView: View {
    let model: FluidAudioModel
    @EnvironmentObject private var fluidAudioModelManager: FluidAudioModelManager

    var isDownloaded: Bool {
        fluidAudioModelManager.isFluidAudioModelDownloaded(model)
    }

    var isDownloading: Bool {
        fluidAudioModelManager.isFluidAudioModelDownloading(model)
    }

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
            Text(model.displayName)
                .font(AppTheme.font(.body, .semibold))
                .foregroundColor(Color(.labelColor))

            Spacer()
        }
    }

    private var metadataSection: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            Label(model.language, systemImage: "globe")
            Label(model.size, systemImage: "internaldrive")
            HStack(spacing: AppTheme.Spacing.x1) {
                Text("Speed")
                progressDotsWithNumber(value: model.speed * 10)
            }
            .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: AppTheme.Spacing.x1) {
                Text("Accuracy")
                progressDotsWithNumber(value: model.accuracy * 10)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .font(AppTheme.font(.caption))
        .foregroundColor(Color(.secondaryLabelColor))
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
            if let status = fluidAudioModelManager.downloadStatus(for: model) {
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
                    .foregroundColor(Color(.secondaryLabelColor))

                    ProgressView(value: status.fractionCompleted)
                        .progressViewStyle(LinearProgressViewStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, AppTheme.Spacing.x2)
            }
        }
    }

    private var actionSection: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            if isDownloaded && !isDownloading {
                modelStatusPill("Downloaded", systemImage: "checkmark.circle")
            } else {
                Button(action: {
                    if isDownloading {
                        fluidAudioModelManager.cancelDownload(model)
                    } else {
                        fluidAudioModelManager.startDownload(model)
                    }
                }) {
                    HStack(spacing: AppTheme.Spacing.x1) {
                        Text(LocalizedStringKey(isDownloading ? "Cancel" : "Download"))
                        Image(systemName: isDownloading ? "xmark.circle" : "arrow.down.circle")
                    }
                    .font(AppTheme.font(.footnote, .medium))
                    .foregroundColor(AppTheme.Text.primary)
                    .padding(.horizontal, AppTheme.Spacing.x3)
                    .padding(.vertical, AppTheme.Spacing.x2)
                    .background(
                        Capsule().fill(AppTheme.Surface.control)
                        .overlay(Capsule().strokeBorder(AppTheme.Border.control))
                    )
                }
                .buttonStyle(.plain)
            }

            if isDownloaded && !isDownloading {
                Menu {
                    Button(action: {
                        fluidAudioModelManager.deleteFluidAudioModel(model)
                    }) {
                        Label("Delete Model", systemImage: "trash")
                    }

                    Button {
                        fluidAudioModelManager.showFluidAudioModelInFinder(model)
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
