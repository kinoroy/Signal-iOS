//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public class CVTranslationState {
    private var translations: [String: String] = [:]
    private var loadingIds: Set<String> = []

    init(translations: [String: String] = [:], loadingIds: Set<String> = []) {
        self.translations = translations
        self.loadingIds = loadingIds
    }

    public func getTranslation(for interactionId: String) -> String? {
        translations[interactionId]
    }

    public func setTranslation(_ text: String, for interactionId: String) {
        translations[interactionId] = text
    }

    public func setLoading(_ interactionId: String) {
        loadingIds.insert(interactionId)
    }

    public func clearLoading(_ interactionId: String) {
        loadingIds.remove(interactionId)
    }

    public func isLoading(_ interactionId: String) -> Bool {
        loadingIds.contains(interactionId)
    }

    func copy() -> CVTranslationState {
        CVTranslationState(translations: translations, loadingIds: loadingIds)
    }
}
