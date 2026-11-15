//
//  GlassMenuButton.swift
//  MyAgenda
//
//  The "…" button. A UIKit button with its menu as the primary action, so the
//  whole circle opens the menu — a SwiftUI Menu only reacts on its label's
//  content, which left the edges of the glass dead. The glass itself is drawn
//  by SwiftUI (see the call site) so it still blends with the bar's pills.
//  The menu is rebuilt each time it opens, so it always shows current state.
//

import SwiftUI
import UIKit

struct GlassMenuButton: UIViewRepresentable {
    var systemImage: String
    /// Builds the menu's elements at the moment it opens.
    var elements: () -> [UIMenuElement]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemImage)
        config.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        config.baseForegroundColor = .label
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "More"

        let coordinator = context.coordinator
        coordinator.elements = elements
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak coordinator] completion in
                completion(coordinator?.elements() ?? [])
            }
        ])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.elements = elements
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 44, height: proposal.height ?? 44)
    }

    final class Coordinator {
        var elements: () -> [UIMenuElement] = { [] }
    }
}
