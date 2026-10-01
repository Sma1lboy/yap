import Foundation
import SwiftData

/// With a mode's language on auto, local Whisper spends a whole encoder pass detecting the language before every
/// dictation. When the mode's last `window` local Whisper dictations all came out in one language, with no whole
/// sentence in another script, Yap suggests fixing that language, once (docs/dictation-latency.md, "Fixing the
/// language"). No Thanks stops it for that mode; so does going back to auto from the confirmation.
@MainActor
enum LanguagePinSuggestion {
    /// Dictations in a row: enough that a user who code-switches whole sentences has done it at least once (see the
    /// doc), few enough that a one-language user gets the saving within their first days.
    nonisolated static let window = 20
    /// Mode ids (uuidString) that said No Thanks or went back to auto.
    private static let declinedKey = "LanguagePinSuggestionDeclinedModes"
    /// Mode id → when the suggestion was last shown; only dictations after that count for the next one.
    private static let shownKey = "LanguagePinSuggestionShownAt"
    /// The languages "English terms are still recognized" was measured for (Chinese clips with English terms).
    nonisolated private static let measuredWithEnglishTerms: Set<String> = ["zh"]

    struct Dictation {
        let date: Date
        /// SessionMetric.detectedLanguages, split.
        let languages: [String]
        let detectionSeconds: TimeInterval?
        /// The transcript; nil when it's no longer in History.
        let text: String?
    }

    struct Suggestion: Equatable {
        let language: String
        /// The median detection time of those dictations: what each one would save.
        let seconds: TimeInterval
    }

    /// The whole rule. `recent` is newest first. Nil unless the mode's language is auto on local Whisper, the mode
    /// hasn't declined, and the last `window` dictations since the suggestion was last shown are all one language
    /// the model can be set to, with their transcripts at hand and no whole sentence in another script.
    nonisolated static func suggestion(
        languageSetting: String, provider: ModelProvider, supportedLanguages: Set<String>, declined: Bool,
        lastShown: Date?, recent: [Dictation]
    ) -> Suggestion? {
        guard languageSetting == "auto", provider == .whisper, !declined, recent.count >= window else { return nil }
        let last = recent.prefix(window)
        guard let language = last.first?.languages.first, language != "auto", supportedLanguages.contains(language),
            last.allSatisfy({ dictation in
                dictation.languages == [language] && lastShown.map { dictation.date > $0 } != false
                    && dictation.text.map { !hasSentence(otherThan: language, in: $0) } == true
            })
        else { return nil }
        let times = last.compactMap(\.detectionSeconds).sorted()
        guard !times.isEmpty else { return nil }
        return Suggestion(language: language, seconds: times[times.count / 2])
    }

    /// A whole sentence the detected language can't have produced: for Chinese, Japanese and Korean, one of four or
    /// more words with no CJK character in it; for the others, one with four or more CJK characters. A term or a
    /// short phrase ("OK", "Sounds good") isn't a sentence.
    nonisolated static func hasSentence(otherThan language: String, in text: String) -> Bool {
        let cjkLanguage = ["zh", "yue", "ja", "ko"].contains(language)
        let sentences = text.replacingOccurrences(of: #"\.(\s|$)"#, with: "\n", options: .regularExpression)
            .split { "。！？!?\n".contains($0) }
        return sentences.contains { sentence in
            let cjk = sentence.unicodeScalars.filter(isCJK).count
            if !cjkLanguage { return cjk >= 4 }
            let words = sentence.split { !$0.isLetter && $0 != "'" }
            return cjk == 0 && words.count >= 4
        }
    }

    nonisolated private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x1100...0x11FF, 0xAC00...0xD7AF: return true  // kana, Hangul
        default: return scalar.properties.isIdeographic
        }
    }

    /// The median language detection time of this Mac's last `window` dictations with `model` on auto; nil before
    /// there are any.
    static func detectionCost(model: any TranscriptionModel, in context: ModelContext) -> TimeInterval? {
        let name = model.displayName
        var descriptor = FetchDescriptor<SessionMetric>(
            predicate: #Predicate { $0.transcriptionModelName == name && $0.languageDetectionDuration != nil },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = window
        let times = ((try? context.fetch(descriptor)) ?? []).compactMap(\.languageDetectionDuration).sorted()
        return times.isEmpty ? nil : times[times.count / 2]
    }

    /// "0.5", in the app's language.
    static func formatted(_ seconds: TimeInterval) -> String {
        seconds.formatted(.number.precision(.fractionLength(1)).locale(appLocale))
    }

    /// The language's name in the app's language ("Chinese", "中文", "Chinesisch").
    static func languageName(_ code: String) -> String {
        appLocale.localizedString(forLanguageCode: code) ?? LanguageDictionary.all[code] ?? code
    }

    private static var appLocale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }

    /// After a dictation was pasted and saved. Shows the suggestion when the rule says so and no other notification
    /// is on screen (that dictation's turn is skipped; the next one asks again).
    static func considerAfterDictation(modeID: UUID, model: any TranscriptionModel, in context: ModelContext) {
        guard model.provider == .whisper, let mode = ModeManager.shared.getConfiguration(with: modeID),
            !NotificationManager.shared.isShowingNotification
        else { return }
        let languageSetting = TranscriptionLanguageSupport.validLanguageOrFallback(
            mode.selectedLanguage, for: model, realtimeEnabled: mode.isRealtimeTranscriptionEnabled)
        let key = modeID.uuidString
        let declined = (UserDefaults.standard.stringArray(forKey: declinedKey) ?? []).contains(key)
        guard languageSetting == "auto", !declined else { return }

        let id: UUID? = modeID
        var metrics = FetchDescriptor<SessionMetric>(
            predicate: #Predicate { $0.modeID == id && $0.detectedLanguages != nil },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        metrics.fetchLimit = window
        let rows = (try? context.fetch(metrics)) ?? []
        guard rows.count >= window else { return }
        let ids = rows.map(\.transcriptionId)
        let transcripts = (try? context.fetch(FetchDescriptor<Transcription>(predicate: #Predicate { ids.contains($0.id) })))
            ?? []
        let texts = Dictionary(transcripts.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        let lastShown = (UserDefaults.standard.dictionary(forKey: shownKey) as? [String: Date])?[key]
        let recent = rows.map {
            Dictation(
                date: $0.timestamp, languages: ($0.detectedLanguages ?? "").split(separator: ",").map(String.init),
                detectionSeconds: $0.languageDetectionDuration, text: texts[$0.transcriptionId])
        }
        guard
            let suggestion = suggestion(
                languageSetting: languageSetting, provider: model.provider,
                supportedLanguages: Set(TranscriptionLanguageSupport.languages(for: model).keys), declined: declined,
                lastShown: lastShown, recent: recent)
        else { return }

        var shown = UserDefaults.standard.dictionary(forKey: shownKey) ?? [:]
        shown[key] = Date()
        UserDefaults.standard.set(shown, forKey: shownKey)
        show(suggestion, modeID: modeID)
    }

    static func message(for suggestion: Suggestion) -> String {
        let name = languageName(suggestion.language)
        let seconds = formatted(suggestion.seconds)
        let format =
            measuredWithEnglishTerms.contains(suggestion.language)
            ? String(
                localized: "You've spoken %1$@ in your last %2$lld dictations. Set this mode to %1$@ and each one is about %3$@ s faster; English terms are still recognized."
            )
            : String(
                localized: "You've spoken %1$@ in your last %2$lld dictations. Set this mode to %1$@ and each one is about %3$@ s faster."
            )
        return String(format: format, name, window, seconds)
    }

    static func setButtonTitle(_ language: String) -> String {
        String(format: String(localized: "Set to %@"), languageName(language))
    }

    private static func show(_ suggestion: Suggestion, modeID: UUID) {
        NotificationManager.shared.showNotification(
            title: message(for: suggestion), type: .info, duration: 15,
            actionButton: (setButtonTitle(suggestion.language), { setLanguage(suggestion.language, modeID: modeID) }),
            secondaryButton: (String(localized: "No Thanks"), { decline(modeID) }))
    }

    private static func decline(_ modeID: UUID) {
        var declined = UserDefaults.standard.stringArray(forKey: declinedKey) ?? []
        guard !declined.contains(modeID.uuidString) else { return }
        declined.append(modeID.uuidString)
        UserDefaults.standard.set(declined, forKey: declinedKey)
    }

    /// Sets the mode's language as the menu bar does, then confirms with Back to Auto-detect, which also stops the
    /// suggestion for this mode.
    private static func setLanguage(_ language: String, modeID: UUID) {
        guard let mode = update(modeID, language: language) else { return }
        NotificationManager.shared.showNotification(
            title: confirmation(modeName: mode.name, language: language), type: .success, duration: 8,
            actionButton: (
                String(localized: "Back to Auto-detect"),
                {
                    decline(modeID)
                    _ = update(modeID, language: "auto")
                }
            ))
    }

    @discardableResult
    private static func update(_ modeID: UUID, language: String) -> ModeConfig? {
        guard var mode = ModeManager.shared.getConfiguration(with: modeID) else { return nil }
        mode.selectedLanguage = language
        ModeManager.shared.updateConfiguration(mode)
        if ModeManager.shared.currentActiveConfiguration?.id == modeID { ModeManager.shared.setActiveConfiguration(mode) }
        NotificationCenter.default.post(name: .languageDidChange, object: nil)
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        return mode
    }

    static func confirmation(modeName: String, language: String) -> String {
        String(
            format: String(localized: "“%1$@” now transcribes %2$@ without detecting the language first."),
            modeName, languageName(language))
    }

    #if DEBUG
        static func selfCheck() {
            let start = Date(timeIntervalSince1970: 1_000_000)
            func dictations(_ languages: [String], count: Int = window, text: String? = "你好，今天开会讨论 roadmap。")
                -> [Dictation]
            {
                (0..<count).map {
                    Dictation(
                        date: start.addingTimeInterval(Double(count - $0)), languages: languages,
                        detectionSeconds: 0.4 + Double($0 % 3) * 0.05, text: text)
                }
            }
            func replacing(_ list: [Dictation], at index: Int, languages: [String]? = nil, text: String?) -> [Dictation] {
                var list = list
                let old = list[index]
                list[index] = Dictation(
                    date: old.date, languages: languages ?? old.languages, detectionSeconds: old.detectionSeconds,
                    text: text)
                return list
            }
            let whisper: Set<String> = ["auto", "zh", "en", "ja"]
            func check(
                _ recent: [Dictation], setting: String = "auto", provider: ModelProvider = .whisper,
                declined: Bool = false, lastShown: Date? = nil
            ) -> Suggestion? {
                suggestion(
                    languageSetting: setting, provider: provider, supportedLanguages: whisper, declined: declined,
                    lastShown: lastShown, recent: recent)
            }

            // N in a row, all Chinese: suggest Chinese, saving the median detection time.
            assert(check(dictations(["zh"])) == Suggestion(language: "zh", seconds: 0.45))
            // One fewer than N, one of the N in English, or one split by language: nothing.
            assert(check(dictations(["zh"], count: window - 1)) == nil)
            assert(check(replacing(dictations(["zh"]), at: 7, languages: ["en"], text: "Hi there")) == nil)
            assert(check(replacing(dictations(["zh"]), at: 0, languages: ["en", "zh"], text: "Hi. 你好")) == nil)
            // Older dictations past the window don't matter.
            assert(check(dictations(["zh"]) + dictations(["en"], count: 5)) != nil)
            // Detected as Chinese, but a whole English sentence in one of them.
            assert(
                check(replacing(dictations(["zh"]), at: 3, text: "先看一下这个。Can you review the pull request before lunch?"))
                    == nil)
            // A transcript deleted from History: not enough evidence.
            assert(check(replacing(dictations(["zh"]), at: 5, text: nil)) == nil)
            // Cloud and Parakeet don't detect; already fixed; declined; a language the model can't be set to.
            assert(check(dictations(["zh"]), provider: .yapCloud) == nil)
            assert(check(dictations(["zh"]), provider: .fluidAudio) == nil)
            assert(check(dictations(["zh"]), setting: "zh") == nil)
            assert(check(dictations(["zh"]), declined: true) == nil)
            assert(check(dictations(["yue"])) == nil)
            // Shown before: only dictations after that count, so it waits for N new ones.
            assert(check(dictations(["zh"]), lastShown: start.addingTimeInterval(5)) == nil)
            assert(check(dictations(["zh"]), lastShown: start) != nil)
            // Without detection times there's no number to promise.
            let untimed = dictations(["zh"]).map {
                Dictation(date: $0.date, languages: $0.languages, detectionSeconds: nil, text: $0.text)
            }
            assert(check(untimed) == nil)

            // Whole sentences in another script, not terms.
            assert(!hasSentence(otherThan: "zh", in: "OAuth的Refresh Token现在存在Local Storage里,有XSS风险。"))
            assert(!hasSentence(otherThan: "zh", in: "好的。Sounds good. 我们下周再说。"))
            assert(hasSentence(otherThan: "zh", in: "效应。 Can you review the pull request before launch? The migration"))
            assert(!hasSentence(otherThan: "en", in: "The P99 latency dropped to 1.8 s."))
            assert(hasSentence(otherThan: "en", in: "Retry logic. 昨天我跟Sara对了一下"))
            assert(!hasSentence(otherThan: "en", in: "Ship it. 好的"))
            assert(hasSentence(otherThan: "ja", in: "Let's ship this before Friday."))
        }
    #endif
}
