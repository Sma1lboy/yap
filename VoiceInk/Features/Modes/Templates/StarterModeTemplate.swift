import Foundation

enum StarterModeKind: String, CaseIterable, Identifiable {
    case clean
    case enhance
    case email
    case rewrite
    case assistant

    var id: String { rawValue }
}

struct StarterModeTemplate: Identifiable {
    let kind: StarterModeKind
    let id: UUID
    let name: String
    let icon: ModeIcon
    let promptId: UUID?
    let outputMode: ModeOutputMode
    let usesAIEnhancement: Bool
    let useSelectedTextContext: Bool
    let useScreenCapture: Bool
    let isDefault: Bool
}

enum StarterModeCatalog {
    // Computed so names follow the current language when a mode is seeded.
    static var templates: [StarterModeTemplate] {
        [
            StarterModeTemplate(
                kind: .clean,
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                name: String(localized: "Dictation"),
                icon: .symbol("mic.fill"),
                promptId: nil,
                outputMode: .paste,
                usesAIEnhancement: false,
                useSelectedTextContext: false,
                useScreenCapture: false,
                isDefault: true
            ),
            StarterModeTemplate(
                kind: .enhance,
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                name: String(localized: "Enhancement"),
                icon: .symbol("sparkles"),
                promptId: PromptTemplates.defaultPromptId,
                outputMode: .paste,
                usesAIEnhancement: true,
                useSelectedTextContext: true,
                useScreenCapture: true,
                isDefault: false
            ),
            StarterModeTemplate(
                kind: .email,
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                name: String(localized: "Email"),
                icon: .symbol("envelope.fill"),
                promptId: PromptTemplates.emailPromptId,
                outputMode: .paste,
                usesAIEnhancement: true,
                useSelectedTextContext: true,
                useScreenCapture: true,
                isDefault: false
            ),
            StarterModeTemplate(
                kind: .rewrite,
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
                name: String(localized: "Rewrite"),
                icon: .symbol("quote.bubble.fill"),
                promptId: PromptTemplates.rewritePromptId,
                outputMode: .paste,
                usesAIEnhancement: true,
                useSelectedTextContext: true,
                useScreenCapture: false,
                isDefault: false
            ),
            StarterModeTemplate(
                kind: .assistant,
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
                name: String(localized: "Assistant"),
                icon: .symbol("bubble.left.and.bubble.right.fill"),
                promptId: PromptTemplates.assistantPromptId,
                outputMode: .respond,
                usesAIEnhancement: true,
                useSelectedTextContext: false,
                useScreenCapture: false,
                isDefault: false
            ),
        ]
    }

    static var ids: Set<UUID> {
        Set(templates.map(\.id))
    }
}
