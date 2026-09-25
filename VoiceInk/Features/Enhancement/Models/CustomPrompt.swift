import Foundation

struct CustomPrompt: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let promptText: String
    let useSystemInstructions: Bool

    init(
        id: UUID = UUID(),
        title: String,
        promptText: String,
        useSystemInstructions: Bool = true
    ) {
        self.id = id
        self.title = title
        self.promptText = promptText
        self.useSystemInstructions = useSystemInstructions
    }

    enum CodingKeys: String, CodingKey {
        case id, title, promptText, useSystemInstructions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        promptText = try container.decode(String.self, forKey: .promptText)
        useSystemInstructions = try container.decodeIfPresent(Bool.self, forKey: .useSystemInstructions) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(promptText, forKey: .promptText)
        try container.encode(useSystemInstructions, forKey: .useSystemInstructions)
    }

    var finalPromptText: String {
        if useSystemInstructions {
            return String(format: AIPrompts.enhancementSystemTemplate, self.promptText)
        } else {
            return self.promptText
        }
    }
}
