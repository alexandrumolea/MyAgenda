//
//  PhoneKeyboardScroll.swift
//  MyAgenda
//
//  iPhone: moves the page so the line being written clears the keyboard, in
//  one movement that runs with the keyboard. Left to the system, the page
//  shrank at once (a step up, and blank paper where the keyboard was still
//  to come), then snapped up again once the keyboard had stopped. Now the
//  page ignores the keyboard, as on iPad, gets room below it to scroll into
//  (`keyboardOverlap`), and is moved here, on the keyboard's own curve.
//  On iPad the keyboard simply covers the page, so nothing here runs there.
//

import Observation
import UIKit

@Observable
final class PhoneKeyboardScroll: NSObject {
    static let shared = PhoneKeyboardScroll()

    /// How much of the page the keyboard covers (iPhone): the page gets that
    /// much room below, so its last lines can rise above the keyboard.
    private(set) var keyboardOverlap: CGFloat = 0

    /// Room left between the line being written and the bar above the keyboard.
    /// The system's own scroll for the caret keeps this much too: with less,
    /// it nudged the page a little further once ours had finished.
    @ObservationIgnored private let gap: CGFloat = 36

    @ObservationIgnored private weak var input: UIView?
    /// The keyboard's frame in screen coordinates while it is up.
    @ObservationIgnored private var keyboardFrame: CGRect?
    /// The keyboard's animation, when it has just started one.
    @ObservationIgnored private var keyboardTiming: (duration: TimeInterval, curve: UIView.AnimationOptions)?
    @ObservationIgnored private var revealScheduled = false

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// A text box or checklist row started editing: the page moves only if
    /// the keyboard covers it (or it starts above the screen).
    func begin(_ input: UIView & UITextInput) {
        guard isPhone else { return }
        self.input = input
        scheduleReveal()
    }

    /// Typing: a new line under the bar moves up just enough to be seen.
    func followCaret(of input: UIView & UITextInput) {
        guard isPhone, input === self.input else { return }
        scheduleReveal()
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard isPhone, let info = note.userInfo,
              let frame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        keyboardFrame = frame
        keyboardTiming = (duration, UIView.AnimationOptions(rawValue: curve << 16))
        // Measured from the safe area's bottom, where the page ends while the
        // keyboard is up. More would leave the system thinking the line is
        // still covered, and it scrolled the page a second time.
        if let window = input?.window ?? keyWindow {
            let top = window.convert(frame, from: window.screen.coordinateSpace).minY
            keyboardOverlap = max(0, window.bounds.maxY - window.safeAreaInsets.bottom - top)
        }
        scheduleReveal()
    }

    /// The room below the page goes: if it was scrolled into that room, it
    /// comes back with the keyboard instead of snapping.
    @objc private func keyboardWillHide(_ note: Notification) {
        guard isPhone else { return }
        keyboardFrame = nil
        keyboardOverlap = 0
        guard let input, let window = input.window, let scroll = pageScrollView(of: input) else { return }
        // Done with this field: another one's keyboard never moves the page.
        if !input.isFirstResponder { self.input = nil }
        let info = note.userInfo
        let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        let pageTop = scroll.convert(scroll.bounds, to: window).minY
        let maxY = scroll.contentSize.height + window.safeAreaInsets.bottom - (window.bounds.height - pageTop)
        guard scroll.contentOffset.y > maxY else { return }
        let target = CGPoint(x: scroll.contentOffset.x, y: max(maxY, -scroll.adjustedContentInset.top))
        move(scroll, to: target, duration: duration, curve: UIView.AnimationOptions(rawValue: curve << 16))
    }

    /// Once per turn of the run loop: the field and the keyboard announce
    /// themselves in either order, and a checklist row takes the focus while
    /// SwiftUI is still updating.
    private func scheduleReveal() {
        guard !revealScheduled else { return }
        revealScheduled = true
        DispatchQueue.main.async { [self] in
            revealScheduled = false
            reveal()
        }
    }

    private func reveal() {
        // With the keyboard when it is moving; on its own when it is already up
        // (another box, another row, a new line).
        let timing = keyboardTiming ?? (0.25, .curveEaseInOut)
        keyboardTiming = nil
        guard let input, let textInput = input as? UITextInput, input.isFirstResponder,
              let window = input.window, let screenFrame = keyboardFrame,
              let scroll = pageScrollView(of: input) else { return }
        let keyboardTop = window.convert(screenFrame, from: window.screen.coordinateSpace).minY
        guard keyboardTop < window.bounds.maxY else { return }

        let page = scroll.convert(scroll.bounds, to: window)
        let visibleTop = page.minY + scroll.adjustedContentInset.top
        guard let selection = textInput.selectedTextRange else { return }
        let caret = input.convert(textInput.caretRect(for: selection.end), to: window)
        let bottom = keyboardTop - gap
        let delta: CGFloat
        if caret.maxY > bottom {
            delta = caret.maxY - bottom
        } else if caret.minY < visibleTop {
            // Added from the toolbar on a line scrolled away above.
            delta = caret.minY - visibleTop - gap
        } else {
            return
        }

        // Within the page as it is with the keyboard up.
        let inset = scroll.adjustedContentInset
        let maxY = max(-inset.top, scroll.contentSize.height - (keyboardTop - page.minY))
        let offset = scroll.contentOffset
        let target = CGPoint(x: offset.x, y: min(max(offset.y + delta, -inset.top), maxY))
        guard target != offset else { return }
        move(scroll, to: target, duration: timing.duration, curve: timing.curve)
    }

    private func move(_ scroll: UIScrollView, to target: CGPoint,
                      duration: TimeInterval, curve: UIView.AnimationOptions) {
        UIView.animate(withDuration: duration, delay: 0,
                       options: [curve, .beginFromCurrentState, .allowUserInteraction]) {
            scroll.contentOffset = target
        }
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.lazy
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    /// The scroll view holding the page (a text view is a scroll view itself).
    private func pageScrollView(of input: UIView) -> UIScrollView? {
        var next = input.superview
        while let candidate = next {
            if let scroll = candidate as? UIScrollView { return scroll }
            next = candidate.superview
        }
        return nil
    }
}
