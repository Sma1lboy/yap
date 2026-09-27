import Foundation

/// Language and dictionary terms for OpenRouter's `/audio/transcriptions` JSON body, used by the OpenRouter
/// provider and Yap Cloud (paygate forwards the body unchanged). `language` is a top-level field OpenRouter
/// normalises for every provider. Terms only go through `provider.options.<provider slug>`, in that provider's
/// own field, so each model needs its own shape.
///
/// Probe, 2026-09-26: an invented-word clip ("Kwyntel / Zorvex / Brisquo"), terms correct without → with the hint:
/// mai-transcribe-2 `azure.phraseList` 0 → 3 (`azure.prompt` ignored), gpt-4o-transcribe `openai.prompt` 0 → 2,
/// gpt-4o-mini-transcribe 0 → 1, whisper-large-v3 `prompt` 0 → 1. qwen3-asr-flash ignored `context`, and
/// gemini-3.5-transcribe answered 400 to `prompt`, so those two get no terms. Other models: none.
enum TranscriptionHints {
    /// ponytail: the first 100 terms (the dictionary is sorted by word); Azure phrase lists and OpenAI prompts
    /// both have limits. Rank terms by use if bigger dictionaries lose the ones that matter.
    static let maxTerms = 100

    static func apply(to body: inout [String: Any], model: String, language: String?, vocabulary: [String]) {
        if let language = isoLanguage(language) { body["language"] = language }
        let terms = Array(vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(maxTerms))
        if !terms.isEmpty, let options = providerOptions(model: model, terms: terms) {
            body["provider"] = ["options": options]
        }
    }

    /// OpenRouter wants ISO-639-1 ("zh", "en"); "zh-Hans" → "zh", "auto" or a 3-letter code (yue) → nil.
    static func isoLanguage(_ language: String?) -> String? {
        guard let code = language?.split(separator: "-").first.map(String.init)?.lowercased(),
            code.count == 2, code.allSatisfy(\.isLetter)
        else { return nil }
        return code
    }

    static func providerOptions(model: String, terms: [String]) -> [String: Any]? {
        let prompt = terms.joined(separator: ", ")
        switch model {
        case "microsoft/mai-transcribe-2":
            return ["azure": ["phraseList": ["phrases": terms]]]
        case "openai/gpt-4o-transcribe", "openai/gpt-4o-mini-transcribe":
            return ["openai": ["prompt": prompt]]
        case "openai/whisper-large-v3":
            // Served by whichever of these is up; each takes OpenAI's `prompt`.
            return ["groq": ["prompt": prompt], "deepinfra/us": ["prompt": prompt], "together": ["prompt": prompt]]
        default:
            return nil
        }
    }
}

#if DEBUG
    extension TranscriptionHints {
        static func selfCheck() {
            var body: [String: Any] = [:]
            apply(to: &body, model: "microsoft/mai-transcribe-2", language: "zh-Hans", vocabulary: ["Kwyntel", " ", "Zorvex"])
            assert(body["language"] as? String == "zh")
            let azure = ((body["provider"] as? [String: Any])?["options"] as? [String: Any])?["azure"] as? [String: Any]
            assert((azure?["phraseList"] as? [String: [String]])?["phrases"] == ["Kwyntel", "Zorvex"])

            var openAI: [String: Any] = [:]
            apply(to: &openAI, model: "openai/gpt-4o-transcribe", language: "auto", vocabulary: ["A", "B"])
            assert(openAI["language"] == nil)
            let options = (openAI["provider"] as? [String: Any])?["options"] as? [String: [String: String]]
            assert(options == ["openai": ["prompt": "A, B"]])

            // No terms for models that ignore them or reject the field; nothing at all without input.
            var gemini: [String: Any] = [:]
            apply(to: &gemini, model: "google/gemini-3.5-transcribe", language: "en", vocabulary: ["A"])
            assert(gemini["provider"] == nil && gemini["language"] as? String == "en")
            var empty: [String: Any] = [:]
            apply(to: &empty, model: "microsoft/mai-transcribe-2", language: nil, vocabulary: [])
            assert(empty.isEmpty)
            assert(isoLanguage("yue") == nil && isoLanguage("EN") == "en" && isoLanguage(nil) == nil)
            var many: [String: Any] = [:]
            apply(to: &many, model: "microsoft/mai-transcribe-2", language: nil, vocabulary: (0..<150).map { "t\($0)" })
            let phrases = ((((many["provider"] as? [String: Any])?["options"] as? [String: Any])?["azure"]
                as? [String: Any])?["phraseList"] as? [String: [String]])?["phrases"]
            assert(phrases?.count == maxTerms)
        }
    }
#endif
