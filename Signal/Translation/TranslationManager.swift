//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI
import Translation

@available(iOS 17.4, *)
struct TranslationView: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Color.clear
            .translationPresentation(isPresented: $isPresented, text: text)
            .onAppear {
                isPresented = true
            }
    }
}

@available(iOS 17.4, *)
@MainActor
class TranslationManager {
    static let shared = TranslationManager()
    private init() {}

    func presentTranslation(for text: String, from viewController: UIViewController) {
        let hostingController = UIHostingController(rootView: TranslationView(text: text))
        hostingController.view.backgroundColor = .clear
        hostingController.view.frame = .zero

        viewController.addChild(hostingController)
        viewController.view.addSubview(hostingController.view)
        hostingController.didMove(toParent: viewController)
    }
}
