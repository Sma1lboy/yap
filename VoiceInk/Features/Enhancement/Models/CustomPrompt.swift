import Foundation

struct CustomPrompt: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    /// The stored text. For a prompt that follows the recommended one it's the version it was set up or migrated
    /// with, kept so Yap versions that don't know `followsRecommended` still read a complete prompt; use `text`.
    let promptText: String
    let useSystemInstructions: Bool
    /// Uses the recommended prompt bundled with this Yap (RecommendedPrompt.md), so it changes when Yap updates.
    /// Written only when true; editing the text in Yap turns it off.
    let followsRecommended: Bool

    init(
        id: UUID = UUID(),
        title: String,
        promptText: String,
        useSystemInstructions: Bool = true,
        followsRecommended: Bool = false
    ) {
        self.id = id
        self.title = title
        self.promptText = promptText
        self.useSystemInstructions = useSystemInstructions
        self.followsRecommended = followsRecommended
    }

    /// The text Yap sends: this Yap's recommended prompt when the prompt follows it, otherwise the stored text.
    var text: String {
        followsRecommended ? RecommendedSetup.prompt ?? promptText : promptText
    }

    enum CodingKeys: String, CodingKey {
        case id, title, promptText, useSystemInstructions, followsRecommended
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        promptText = try container.decode(String.self, forKey: .promptText)
        useSystemInstructions = try container.decodeIfPresent(Bool.self, forKey: .useSystemInstructions) ?? true
        followsRecommended = try container.decodeIfPresent(Bool.self, forKey: .followsRecommended) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(promptText, forKey: .promptText)
        try container.encode(useSystemInstructions, forKey: .useSystemInstructions)
        if followsRecommended { try container.encode(true, forKey: .followsRecommended) }
    }

    var finalPromptText: String {
        if useSystemInstructions {
            return String(format: AIPrompts.enhancementSystemTemplate, text)
        } else {
            return text
        }
    }
}
