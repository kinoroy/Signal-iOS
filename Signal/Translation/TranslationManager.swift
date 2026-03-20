//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import NaturalLanguage
import Translation

@available(iOS 26.0, *)
public class TranslationManager {
    public static let shared = TranslationManager()

    public struct TranslationResult {
        public let translatedText: String
        public let sourceLanguage: String
        public let targetLanguage: String
    }

    private init() {}

    /// Translates text to the user's system language automatically.
    /// Uses NaturalLanguage framework to detect source language and Translation framework to translate.
    public func translate(text: String) async throws -> TranslationResult {
        // Detect source language using NaturalLanguage framework
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominantLanguage = recognizer.dominantLanguage else {
            throw TranslationError.unableToIdentifyLanguage
        }

        let sourceLanguage = Locale.Language(identifier: dominantLanguage.rawValue)

        // Get user's preferred language for the target
        let preferredLanguageCode = Locale.preferredLanguages.first ?? "en"
        let targetLanguage = Locale.Language(identifier: preferredLanguageCode)

        // Check if source and target are the same (no translation needed)
        if sourceLanguage.languageCode == targetLanguage.languageCode {
            throw TranslationError.unsupportedLanguagePairing
        }

        // Create a session with the detected source and user's preferred language as target
        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        let response = try await session.translate(text)

        let sourceLanguageName = Locale.current.localizedString(
            forLanguageCode: sourceLanguage.languageCode?.identifier ?? dominantLanguage.rawValue
        ) ?? dominantLanguage.rawValue

        let targetLanguageName = Locale.current.localizedString(
            forLanguageCode: response.targetLanguage.languageCode?.identifier ?? preferredLanguageCode
        ) ?? preferredLanguageCode

        return TranslationResult(
            translatedText: response.targetText,
            sourceLanguage: sourceLanguageName,
            targetLanguage: targetLanguageName
        )
    }
}
