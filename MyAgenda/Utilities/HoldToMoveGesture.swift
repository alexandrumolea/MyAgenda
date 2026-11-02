//
//  HoldToMoveGesture.swift
//  MyAgenda
//
//  Press and hold, then drag, to move a text or checklist. A UIKit long press
//  rather than a SwiftUI LongPressGesture + DragGesture: that pair held on to
//  the touch, so a swipe that started on text never scrolled the page. This
//  one lets the page's scrolling run alongside until the hold is reached.
//

import SwiftUI
import UIKit

struct HoldToMoveGesture: UIGestureRecognizerRepresentable {
    /// Held long enough to move (true), then let go (false).
    var onLift: (Bool) -> Void
    /// Finger movement since the hold, in global points.
    var onChange: (CGSize) -> Void
    /// Where the finger was let go, as movement since the hold.
    var onEnd: (CGSize) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.35
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let point = context.converter.location(in: .global)
        let start = context.coordinator.start
        let moved = CGSize(width: point.x - start.x, height: point.y - start.y)
        switch recognizer.state {
        case .began:
            context.coordinator.start = point
            onLift(true)
        case .changed:
            onChange(moved)
        case .ended:
            onEnd(moved)
            onLift(false)
        case .cancelled, .failed:
            onChange(.zero)
            onLift(false)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var start: CGPoint = .zero

        /// The page keeps scrolling (and taps keep working) until the hold.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
