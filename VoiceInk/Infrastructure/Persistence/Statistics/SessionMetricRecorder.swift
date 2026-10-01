import Foundation
import OSLog
import SwiftData

enum SessionMetricRecorder {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SessionMetricRecorder")
    private static let source = "recorder"

    /// Inserts the dictation's metric, nil when there's nothing to record (not completed, already recorded).
    @discardableResult
    static func recordRecorderSession(
        transcription: Transcription,
        model: (any TranscriptionModel)?,
        modeID: UUID? = nil,
        timeline: DictationTimeline? = nil,
        in modelContext: ModelContext,
        timestamp: Date = Date()
    ) throws -> SessionMetric? {
        guard transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            return nil
        }

        let transcriptionId = transcription.id
        let descriptor = FetchDescriptor<SessionMetric>(
            predicate: #Predicate<SessionMetric> { metric in
                metric.transcriptionId == transcriptionId
            }
        )

        if try modelContext.fetchCount(descriptor) > 0 {
            return nil
        }

        let textForCounting = finalTextForCounting(from: transcription)
        let wordCount = WordCounter.count(in: textForCounting)
        let audioDuration = max(transcription.duration, 0)
        let transcriptionDuration = transcription.transcriptionDuration.flatMap { $0 > 0 ? $0 : nil }
        let speedFactor = transcriptionDuration.flatMap { duration in
            audioDuration > 0 ? audioDuration / duration : nil
        }

        let enhancementDuration = transcription.enhancementDuration.flatMap { $0 > 0 ? $0 : nil }
        let enhancementTokenEstimate = EnhancementTokenEstimate.estimate(from: transcription)

        let metric = SessionMetric(
            transcriptionId: transcription.id,
            timestamp: timestamp,
            source: source,
            wordCount: wordCount,
            audioDuration: audioDuration,
            transcriptionModelName: transcription.transcriptionModelName ?? model?.displayName,
            transcriptionDuration: transcriptionDuration,
            speedFactor: speedFactor,
            modeName: transcription.modeName,
            aiEnhancementModelName: transcription.aiEnhancementModelName,
            enhancementDuration: enhancementDuration,
            enhancementEstimatedTokenCount: enhancementTokenEstimate?.tokenCount
        )
        metric.modeID = modeID
        if let timeline {
            apply(timeline, to: metric)
        }

        modelContext.insert(metric)
        logger.notice("Recorded session metric for transcription \(transcriptionId.uuidString, privacy: .public)")
        return metric
    }

    /// The timeline's stop, steps and paste. Recorded once the paste is done (TranscriptionPipeline).
    private static func apply(_ timeline: DictationTimeline, to metric: SessionMetric) {
        let offsets = timeline.offsets
        metric.stopSource = timeline.stop.source.rawValue
        metric.stopToRecorderStopped = offsets[.recorderStopped]
        metric.stopToModelReady = offsets[.modelReady]
        metric.stopToTranscribed = offsets[.transcribed]
        metric.stopToProcessed = offsets[.processed]
        metric.stopToEnhanced = offsets[.enhanced]
        metric.stopToPasteCommand = offsets[.pasteCommand]
        metric.pasteOutcome = timeline.pasteOutcome?.rawValue
        if let detection = timeline.languageDetection {
            metric.detectedLanguages = detection.languages.joined(separator: ",")
            metric.languageDetectionDuration = detection.seconds
        }
    }

    private static func finalTextForCounting(from transcription: Transcription) -> String {
        if let enhancedText = transcription.enhancedText,
            transcription.enhancementDuration != nil,
            !enhancedText.isEmpty
        {
            return enhancedText
        }

        return transcription.text
    }
}

#if DEBUG
    /// stats.store as SessionMetric was before the DictationTimeline fields, for SessionMetricRecorder.selfCheck.
    private enum StatsStoreBeforeTimeline {
        @Model
        final class SessionMetric {
            var id: UUID = UUID()
            var transcriptionId: UUID = UUID()
            var timestamp: Date = Date()
            var source: String?
            var wordCount: Int = 0
            var audioDuration: TimeInterval = 0
            var transcriptionModelName: String?
            var transcriptionDuration: TimeInterval?
            var speedFactor: Double?
            @Attribute(originalName: "powerModeName")
            var modeName: String?
            var aiEnhancementModelName: String?
            var enhancementDuration: TimeInterval?
            var enhancementEstimatedTokenCount: Int?

            init(wordCount: Int) { self.wordCount = wordCount }
        }
    }

    extension SessionMetricRecorder {
        static func selfCheck() throws {
            // A store written before the timeline fields opens with them, and its rows read nil.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yap-stats-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("stats.store")
            do {
                let old = try ModelContainer(
                    for: StatsStoreBeforeTimeline.SessionMetric.self, configurations: ModelConfiguration(url: url))
                let context = ModelContext(old)
                context.insert(StatsStoreBeforeTimeline.SessionMetric(wordCount: 42))
                try context.save()
            }
            let migrated = try ModelContainer(for: SessionMetric.self, configurations: ModelConfiguration(url: url))
            let rows = try ModelContext(migrated).fetch(FetchDescriptor<SessionMetric>())
            assert(rows.count == 1 && rows[0].wordCount == 42, "old rows survive")
            assert(rows[0].stopSource == nil && rows[0].stopToPasteCommand == nil && rows[0].pasteOutcome == nil)
            assert(rows[0].modeID == nil && rows[0].detectedLanguages == nil && rows[0].languageDetectionDuration == nil)

            // A dictation's metric is recorded after the paste, with every step and the paste outcome.
            let memory = try ModelContainer(
                for: Transcription.self, SessionMetric.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(memory)
            let transcription = Transcription(text: "hello there", duration: 2, transcriptionStatus: .completed)
            context.insert(transcription)
            let timeline = DictationTimeline(stop: DictationTimeline.Stop(time: 10, source: .shortcutRelease))
            timeline.mark(.recorderStopped, at: 10.05)
            DictationTimeline.$current.withValue(timeline) {
                DictationTimeline.languagesDetected(["en", "zh"], seconds: 0.47)
            }
            timeline.mark(.transcribed, at: 10.8)
            timeline.mark(.processed, at: 10.81)
            timeline.pasteFinished(.pasted, commandAt: 11)
            let mode = UUID()
            guard let metric = try recordRecorderSession(
                transcription: transcription, model: nil, modeID: mode, timeline: timeline, in: context)
            else { return assertionFailure("a completed dictation gets a metric") }
            assert(metric.stopSource == "shortcutRelease" && metric.stopToTranscribed.map { abs($0 - 0.8) < 1e-9 } == true)
            assert(metric.stopToPasteCommand == 1 && metric.pasteOutcome == "pasted" && metric.stopToModelReady == nil)
            assert(metric.modeID == mode && metric.detectedLanguages == "en,zh" && metric.languageDetectionDuration == 0.47)
            let again = try recordRecorderSession(transcription: transcription, model: nil, in: context)
            assert(again == nil, "one metric per dictation")

            // A set language (or another model): nothing detected, nothing recorded.
            let fixed = Transcription(text: "你好", duration: 1, transcriptionStatus: .completed)
            context.insert(fixed)
            let plain = DictationTimeline(stop: DictationTimeline.Stop(time: 0, source: .shortcutRelease))
            DictationTimeline.$current.withValue(plain) { DictationTimeline.languagesDetected([], seconds: 0) }
            let fixedMetric = try recordRecorderSession(transcription: fixed, model: nil, timeline: plain, in: context)
            assert(fixedMetric?.detectedLanguages == nil && fixedMetric?.languageDetectionDuration == nil)
        }
    }
#endif
