//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Ephemeral state storage for message translations.
/// Translations are not persisted and are cleared on navigation.
public class CVTranslationState {
    public struct TranslationResult: Equatable {
        public let translatedText: String
        public let sourceLanguage: String
        public let targetLanguage: String

        public init(translatedText: String, sourceLanguage: String, targetLanguage: String) {
            self.translatedText = translatedText
            self.sourceLanguage = sourceLanguage
            self.targetLanguage = targetLanguage
        }
    }

    private var translations: [String: TranslationResult] = [:]
    private var loadingIds: Set<String> = []

    public init(translations: [String: TranslationResult]? = nil, loadingIds: Set<String>? = nil) {
        if let translations {
            self.translations = translations
        }
        if let loadingIds {
            self.loadingIds = loadingIds
        }
    }

    public func setTranslation(for interactionId: String, result: TranslationResult) {
        translations[interactionId] = result
        loadingIds.remove(interactionId)
    }

    public func getTranslation(for interactionId: String) -> TranslationResult? {
        translations[interactionId]
    }

    public func setLoading(for interactionId: String) {
        loadingIds.insert(interactionId)
    }

    public func clearLoading(for interactionId: String) {
        loadingIds.remove(interactionId)
    }

    public func isLoading(for interactionId: String) -> Bool {
        loadingIds.contains(interactionId)
    }

    public func copy() -> CVTranslationState {
        CVTranslationState(translations: translations, loadingIds: loadingIds)
    }
}
