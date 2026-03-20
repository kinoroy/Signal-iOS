//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI
import Translation
import NaturalLanguage

@available(iOS 18.0, *)
private struct TranslationHost: View {
    let sourceText: String
    let onTranslation: (String) -> Void

    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .translationTask(configuration) { session in
                do {
                    let response = try await session.translate(sourceText)
                    await MainActor.run {
                        onTranslation(response.targetText)
                    }
                } catch {
                    await MainActor.run {
                        print("Translation failed: \(error)")
                    }
                }
            }
            .onAppear {
                if configuration == nil {
                    let sourceLanguage: Locale.Language?
                    let recognizer = NLLanguageRecognizer()
                    recognizer.processString(sourceText)
                    if let dominant = recognizer.dominantLanguage {
                        sourceLanguage = Locale.Language(identifier: dominant.rawValue)
                    } else {
                        sourceLanguage = nil
                    }

                    configuration = .init(source: sourceLanguage, target: nil)
                } else {
                    configuration?.invalidate()
                }
            }
    }
}

@available(iOS 18.0, *)
@MainActor
class TranslationManager {
    static let shared = TranslationManager()
    private init() {}

    private var activeHostingController: UIHostingController<TranslationHost>?

    func translate(text: String, in viewController: UIViewController) async -> String? {
        // Remove any previous hosting controller
        cleanUp()

        return await withCheckedContinuation { continuation in
            let hostView = TranslationHost(sourceText: text) { [weak self] translatedText in
                continuation.resume(returning: translatedText)
                self?.cleanUp()
            }

            let hostingController = UIHostingController(rootView: hostView)
            hostingController.view.backgroundColor = .clear
            hostingController.view.frame = .zero
            self.activeHostingController = hostingController

            viewController.addChild(hostingController)
            viewController.view.addSubview(hostingController.view)
            hostingController.didMove(toParent: viewController)
        }
    }

    private func cleanUp() {
        activeHostingController?.willMove(toParent: nil)
        activeHostingController?.view.removeFromSuperview()
        activeHostingController?.removeFromParent()
        activeHostingController = nil
    }
}
