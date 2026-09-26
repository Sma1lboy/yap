import Foundation

@MainActor
class WhisperPrompt: ObservableObject {
    @Published var transcriptionPrompt: String = UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? ""

    nonisolated private static let customPromptsKey = "CustomLanguagePrompts"

    // Store user-customized prompts
    private var customPrompts: [String: String] = [:]

    // Language-specific base prompts
    nonisolated private static let languagePrompts: [String: String] = [
        // English
        "en": "Hello, how are you doing? Nice to meet you.",

        // Asian Languages
        "hi": "नमस्ते, कैसे हैं आप? आपसे मिलकर अच्छा लगा।",
        "bn": "নমস্কার, কেমন আছেন? আপনার সাথে দেখা হয়ে ভালো লাগলো।",
        "ja": "こんにちは、お元気ですか？お会いできて嬉しいです。",
        "ko": "안녕하세요, 잘 지내시나요? 만나서 반갑습니다.",
        "zh": "你好，最近好吗？见到你很高兴。",
        "th": "สวัสดีครับ/ค่ะ, สบายดีไหม? ยินดีที่ได้พบคุณ",
        "vi": "Xin chào, bạn khỏe không? Rất vui được gặp bạn.",
        "yue": "你好，最近點呀？見到你好開心。",

        // European Languages
        "es": "¡Hola, ¿cómo estás? Encantado de conocerte.",
        "fr": "Bonjour, comment allez-vous? Ravi de vous rencontrer.",
        "de": "Hallo, wie geht es dir? Schön dich kennenzulernen.",
        "it": "Ciao, come stai? Piacere di conoscerti.",
        "pt": "Olá, como você está? Prazer em conhecê-lo.",
        "ru": "Здравствуйте, как ваши дела? Приятно познакомиться.",
        "pl": "Cześć, jak się masz? Miło cię poznać.",
        "nl": "Hallo, hoe gaat het? Aangenaam kennis te maken.",
        "tr": "Merhaba, nasılsın? Tanıştığımıza memnun oldum.",

        // Middle Eastern Languages
        "ar": "مرحباً، كيف حالك؟ سعيد بلقائك.",
        "fa": "سلام، حال شما چطور است؟ از آشنایی با شما خوشوقتم.",
        "he": ",שלום, מה שלומך? נעים להכיר",

        // South Asian Languages
        "ta": "வணக்கம், எப்படி இருக்கிறீர்கள்? உங்களை சந்தித்ததில் மகிழ்ச்சி.",
        "te": "నమస్కారం, ఎలా ఉన్నారు? కలవడం చాలా సంతోషం.",
        "ml": "നമസ്കാരം, സുഖമാണോ? കണ്ടതിൽ സന്തോഷം.",
        "kn": "ನಮಸ್ಕಾರ, ಹೇಗಿದ್ದೀರಾ? ನಿಮ್ಮನ್ನು ಭೇಟಿಯಾಗಿ ಸಂತೋಷವಾಗಿದೆ.",
        "ur": "السلام علیکم، کیسے ہیں آپ؟ آپ سے مل کر خوشی ہوئی۔",

        // Default prompt for unsupported languages
        "default": "",
    ]

    init() {
        loadCustomPrompts()
        updateTranscriptionPrompt()

        // Setup notification observer
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLanguageChange),
            name: .languageDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleLanguageChange() {
        updateTranscriptionPrompt()
    }

    private func loadCustomPrompts() {
        if let savedPrompts = UserDefaults.standard.dictionary(forKey: Self.customPromptsKey) as? [String: String] {
            customPrompts = savedPrompts
        }
    }

    private func saveCustomPrompts() {
        UserDefaults.standard.set(customPrompts, forKey: Self.customPromptsKey)
        UserDefaults.standard.synchronize()  // Force immediate synchronization
    }

    func updateTranscriptionPrompt() {
        // Get the currently selected language from UserDefaults
        let selectedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "en"

        // Get the prompt for the selected language (custom if available, otherwise default)
        let basePrompt = getLanguagePrompt(for: selectedLanguage)
        let prompt = basePrompt.isEmpty ? "" : basePrompt

        transcriptionPrompt = prompt
        UserDefaults.standard.set(prompt, forKey: "TranscriptionPrompt")
        UserDefaults.standard.synchronize()  // Force immediate synchronization

        // Notify that the prompt has changed
        NotificationCenter.default.post(name: .promptDidChange, object: nil)
    }

    func getLanguagePrompt(for language: String) -> String {
        // First check if there's a custom prompt for this language
        if let customPrompt = customPrompts[language], !customPrompt.isEmpty {
            return customPrompt
        }

        // Otherwise return the default prompt, with safe fallback
        return Self.languagePrompts[language] ?? Self.languagePrompts["default"] ?? ""
    }

    /// Returns the saved prompt for a language.
    nonisolated static func resolvedPrompt(for language: String?) -> String {
        guard let language, !language.isEmpty else { return "" }

        if let savedPrompts = UserDefaults.standard.dictionary(forKey: customPromptsKey) as? [String: String],
            let customPrompt = savedPrompts[language],
            !customPrompt.isEmpty
        {
            return customPrompt
        }

        return languagePrompts[language] ?? languagePrompts["default"] ?? ""
    }

    /// whisper.cpp keeps at most 224 prompt tokens (the tail); stay under that with a rough estimate.
    nonisolated static let vocabularyTokenBudget = 200

    /// Appends dictionary words to the base prompt. Whisper spells what the prompt shows it, so words it
    /// otherwise mishears (useEffect, Kubernetes, names) come out right: on the code-switched bench,
    /// every term in the prompt took base from 26 to 56 of 82 terms, small 53 → 72, turbo 65 → 73.
    /// Newest words go last and the oldest are dropped first when the list is too long.
    nonisolated static func withVocabulary(_ base: String, words: [(word: String, dateAdded: Date)]) -> String {
        var seen = Set<String>()
        let newestFirst = words.sorted { $0.dateAdded > $1.dateAdded }
            .map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }

        var budget = vocabularyTokenBudget - estimatedTokens(base)
        var kept: [String] = []
        for word in newestFirst {
            let cost = estimatedTokens(word) + 1
            guard cost <= budget else { break }
            budget -= cost
            kept.append(word)
        }
        let vocabulary = kept.reversed().joined(separator: ", ")
        return [base, vocabulary].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Whisper's tokenizer spends about one token per 3 Latin characters and up to two per CJK character.
    nonisolated static func estimatedTokens(_ text: String) -> Int {
        let cjk = text.unicodeScalars.filter { (0x3000...0x9FFF).contains($0.value) }.count
        return cjk * 2 + (text.unicodeScalars.count - cjk + 2) / 3
    }

    #if DEBUG
        nonisolated static func selfCheck() {
            let now = Date()
            let words: [(word: String, dateAdded: Date)] = [
                ("Kubernetes", now.addingTimeInterval(-10)), ("useEffect", now), ("kubernetes", now.addingTimeInterval(-5)),
                ("  ", now),
            ]
            // Deduped case-insensitively (newest spelling wins), newest last, blanks dropped.
            assert(withVocabulary("", words: words) == "kubernetes, useEffect")
            assert(withVocabulary("你好。", words: words) == "你好。 kubernetes, useEffect")
            assert(withVocabulary("", words: []) == "")
            // Over budget: the oldest words are the ones dropped.
            let many = (0..<500).map { (word: "term\($0)", dateAdded: now.addingTimeInterval(Double($0))) }
            let prompt = withVocabulary("", words: many)
            assert(prompt.hasSuffix("term499") && !prompt.contains("term0,"))
            assert(estimatedTokens(prompt) <= vocabularyTokenBudget)
        }
    #endif

    func setCustomPrompt(_ prompt: String, for language: String) {
        customPrompts[language] = prompt
        saveCustomPrompts()
        updateTranscriptionPrompt()

        // Force update the UI
        objectWillChange.send()
    }
}
