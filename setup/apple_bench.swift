// Apple Intelligence (Foundation Models, macOS 26) over bench.py's 25 cleanup cases, with the app's request:
// AppleIntelligenceService.enhance — RecommendedPrompt.md as instructions, "\n<TRANSCRIPT>\n…\n</TRANSCRIPT>"
// as the prompt (AIEnhancementService), temperature 0.3, a new session per case.
// Needs a Mac on macOS 26 with Apple Intelligence turned on.
//
//     swift setup/apple_bench.swift [rounds]      (default 3)
//     python3 setup/bench.py score
//
// Writes setup/enhance-results/local-apple-intelligence.jsonl; bench.py scores it next to Yap Refine and the
// cloud models (docs/cloud-models.md, "On-device").
import Foundation
import FoundationModels

let setup = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let prompt = try String(contentsOf: setup.appending(path: "../VoiceInk/Resources/RecommendedPrompt.md"), encoding: .utf8)
struct Case: Decodable { let id: String; let `in`: String }
let cases = try ["cases.json", "cases_extra.json"].flatMap {
    try JSONDecoder().decode([Case].self, from: Data(contentsOf: setup.appending(path: $0)))
}
let rounds = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 3

guard SystemLanguageModel.default.isAvailable else {
    print("The on-device model isn't available: \(SystemLanguageModel.default.availability)")
    exit(1)
}

var lines: [String] = []
for round in 1...rounds {
    for c in cases {
        let start = Date()
        var text: String
        do {
            let session = LanguageModelSession(instructions: prompt)
            text = try await session.respond(
                to: "\n<TRANSCRIPT>\n\(c.in)\n</TRANSCRIPT>", options: GenerationOptions(temperature: 0.3)
            ).content
        } catch {
            text = "ERROR \(error)"  // guardrail or context errors count as failed cases
        }
        let secs = Date().timeIntervalSince(start)
        print("--- [\(round) \(c.id) \(String(format: "%.2f", secs))s]\nIN:  \(c.in)\nOUT: \(text)")
        let row: [String: Any] = ["id": c.id, "round": round, "text": text, "secs": (secs * 1000).rounded() / 1000]
        lines.append(String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self))
    }
}
let results = setup.appending(path: "enhance-results")
try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
try (lines.joined(separator: "\n") + "\n").write(
    to: results.appending(path: "local-apple-intelligence.jsonl"), atomically: true, encoding: .utf8)
