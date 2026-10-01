import Foundation
import SwiftData

/// Yap's SwiftData stores in its Application Support folder share one model: every store's metadata records all of
/// its entities. Also compiled into yap-mcp, which has to open default.store with this same model: with any other,
/// Core Data sees a different model and wants to migrate the store.
enum YapStores {
    /// In the order the app has always opened them; append new models.
    static var schema: Schema {
        Schema([Transcription.self, VocabularyWord.self, WordReplacement.self, SessionMetric.self])
    }

    /// History (dictations and meetings), never synced.
    static func historyConfiguration(url: URL, allowsSave: Bool = true) -> ModelConfiguration {
        ModelConfiguration(
            "default", schema: Schema([Transcription.self]), url: url, allowsSave: allowsSave, cloudKitDatabase: .none)
    }

    /// The dictionary (vocabulary and replacements). Release syncs it through the user's private CloudKit database;
    /// Debug and local builds, and yap-mcp's private copy, open it without CloudKit.
    static func dictionaryConfiguration(url: URL, cloudKitDatabase: ModelConfiguration.CloudKitDatabase) -> ModelConfiguration {
        ModelConfiguration(
            "dictionary", schema: Schema([VocabularyWord.self, WordReplacement.self]), url: url,
            cloudKitDatabase: cloudKitDatabase)
    }
}
