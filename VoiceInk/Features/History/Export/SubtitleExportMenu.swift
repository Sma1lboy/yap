import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Export Subtitles" for a transcription that has timed segments (a file transcribed with local Whisper):
/// SRT, WebVTT or Markdown with timestamps. Shows nothing for transcriptions without segments.
struct SubtitleExportMenu: View {
    let transcription: Transcription
    let suggestedBaseName: String
    @State private var errorMessage: String?

    var body: some View {
        let segments = transcription.timedSegments
        if !segments.isEmpty {
            Menu {
                ForEach(SubtitleFormat.allCases) { format in
                    Button(Self.title(for: format)) { save(segments, as: format) }
                }
            } label: {
                Label("Export Subtitles", yapIcon: "captions.bubble")
                    .font(AppTheme.font(.caption, .medium))
                    .foregroundStyle(AppTheme.Text.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Export the transcript with timestamps")
            .alert(
                "Couldn't export subtitles",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    static func title(for format: SubtitleFormat) -> String {
        switch format {
        case .srt: return String(localized: "SubRip Subtitles (.srt)")
        case .vtt: return String(localized: "WebVTT Subtitles (.vtt)")
        case .markdown: return String(localized: "Markdown with Timestamps (.md)")
        }
    }

    private func save(_ segments: [TimedSegment], as format: SubtitleFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = "\(suggestedBaseName).\(format.fileExtension)"
        panel.title = String(localized: "Export Subtitles")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try format.render(segments).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
