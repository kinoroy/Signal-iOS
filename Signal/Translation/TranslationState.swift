//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

/// Tracks translated text keyed by interaction ID.
/// This is a class (reference type) so `CVViewState` can hold a single shared instance
/// that gets mutated from the message action delegate. `copy()` is used to snapshot
/// the state for `CVViewStateSnapshot` during async loads.
public class CVTranslationState {
    public var translations: [String: String] = [:]

    public init() {}

    private init(translations: [String: String]) {
        self.translations = translations
    }

    func copy() -> CVTranslationState {
        CVTranslationState(translations: translations)
    }
}
