//
//  PagerPullDetector.swift
//  MyAgenda
//
//  Pull past the last page to create a new one. Sits invisibly inside the
//  last page, finds the TabView's paging scroll view above it and follows its
//  pan: how far the page is pulled beyond the end (rubber band) is reported as
//  progress, and letting go beyond the threshold commits. The threshold is
//  deliberately long so an ordinary swipe or flick never creates a page.
//

import SwiftUI
import UIKit

/// Pull progress, kept out of the main view so only the hint re-renders.
@Observable
final class PagePullState {
    /// 0 = not pulling, 1 = far enough to create a page on release.
    var progress: CGFloat = 0
}

struct PagerPullDetector: UIViewRepresentable {
    let state: PagePullState
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(state: state, onCommit: onCommit) }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.onCommit = onCommit
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class ProbeView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { coordinator?.detach() } else { coordinator?.attach(from: self) }
        }
    }

    final class Coordinator: NSObject {
        let state: PagePullState
        var onCommit: () -> Void
        private weak var scrollView: UIScrollView?
        private var armed = false
        private let haptic = UIImpactFeedbackGenerator(style: .medium)

        init(state: PagePullState, onCommit: @escaping () -> Void) {
            self.state = state
            self.onCommit = onCommit
        }

        /// The probe sits beside the page's own scroll view, not inside it, so
        /// the nearest scroll view above it is the TabView's pager (a paging
        /// one is preferred, in case of nesting).
        func attach(from view: UIView) {
            var nearest: UIScrollView?
            var current = view.superview
            while let candidate = current {
                if let scroll = candidate as? UIScrollView {
                    if scroll.isPagingEnabled { nearest = scroll; break }
                    if nearest == nil { nearest = scroll }
                }
                current = candidate.superview
            }
            guard let pager = nearest, pager !== scrollView else { return }
            detach()
            scrollView = pager
            // A notebook with a single page must still stretch past its end.
            pager.alwaysBounceHorizontal = true
            pager.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        }

        private func setProgress(_ value: CGFloat) {
            if state.progress != value { state.progress = value }
        }

        func detach() {
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(handlePan(_:)))
            scrollView = nil
            armed = false
            setProgress(0)
        }

        /// Long enough that it has to be meant: with the rubber band, the
        /// finger travels roughly twice this distance.
        private func threshold(for pager: UIScrollView) -> CGFloat {
            min(max(pager.bounds.width * 0.14, 90), 170)
        }

        /// How far the content is dragged beyond its trailing end.
        private func overscroll(of pager: UIScrollView) -> CGFloat {
            pager.contentOffset.x + pager.bounds.width
                - pager.adjustedContentInset.right - pager.contentSize.width
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard let pager = scrollView else { return }
            let limit = threshold(for: pager)
            switch pan.state {
            case .began:
                haptic.prepare()
            case .changed:
                let progress = max(0, overscroll(of: pager)) / limit
                setProgress(progress)
                if progress >= 1, !armed {
                    armed = true
                    haptic.impactOccurred()
                } else if progress < 1, armed {
                    armed = false
                }
            case .ended:
                let commit = overscroll(of: pager) >= limit
                armed = false
                setProgress(0)
                if commit { onCommit() }
            default:
                armed = false
                setProgress(0)
            }
        }
    }
}

/// The glass "+" that grows out of the right edge while pulling.
struct PagePullHint: View {
    let state: PagePullState

    var body: some View {
        let progress = min(state.progress, 1)
        let ready = state.progress >= 1
        Image(systemName: ready ? "plus" : "doc.badge.plus")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(ready ? Color.white : Color.primary)
            .frame(width: 52, height: 52)
            .glassEffect(ready ? .regular.tint(.accentColor) : .regular, in: .circle)
            .overlay(alignment: .bottom) {
                Text(ready ? "Release" : "New Page")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(y: 22)
            }
            .scaleEffect(0.5 + 0.5 * progress)
            .opacity(state.progress > 0.05 ? Double(0.3 + 0.7 * progress) : 0)
            .padding(.trailing, 20)
            .animation(.spring(duration: 0.3, bounce: 0.35), value: ready)
            .allowsHitTesting(false)
    }
}
