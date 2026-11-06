//
//  TextBoxView.swift
//  MyAgenda
//
//  A rich-text editor (UITextView) with per-range formatting via the editing
//  bar above the keyboard (EditBar), including bullet lists ("•" + tab, hanging indent; Return
//  continues the list, Return on an empty bullet ends it). Content is persisted
//  as RTF on the TextBox model.
//

import SwiftUI
import UIKit
import SwiftData

struct TextBoxView: UIViewRepresentable {
    let box: TextBox
    var isEditing: Bool
    var onEndEditing: () -> Void
    /// Font size for new text in an empty box (larger on iPhone, where the
    /// page is shown scaled down).
    var baseFontSize: CGFloat = 18
    /// The notebook's color, for the editing bar.
    var accent: Color = .accentColor
    /// Text is stored as on white paper; dark paper shows it inverted.
    var paper: PaperColor = .white

    static let defaultFont = UIFont.systemFont(ofSize: 18)

    func makeCoordinator() -> Coordinator { Coordinator(box: box, onEndEditing: onEndEditing) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        tv.textContainer.lineFragmentPadding = 0
        // Wrap text to the box width instead of growing horizontally.
        tv.textContainer.widthTracksTextView = true
        tv.textContainer.lineBreakMode = .byWordWrapping
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.allowsEditingTextAttributes = true
        tv.overrideUserInterfaceStyle = paper.interfaceStyle
        let baseFont = UIFont.systemFont(ofSize: baseFontSize)
        tv.font = baseFont
        tv.textColor = paper.shown(.black)
        tv.typingAttributes = [.font: baseFont, .foregroundColor: paper.shown(.black)]

        context.coordinator.paper = paper
        if let attributed = Self.attributedString(from: box.rtfData), attributed.length > 0 {
            tv.attributedText = paper.shown(attributed)
        }
        context.coordinator.lastAppliedRTFData = box.rtfData

        context.coordinator.textView = tv
        tv.inputAccessoryView = context.coordinator.makeBar(accent: accent)
        // The bar has these tools already; the keyboard needn't repeat them.
        tv.inputAssistantItem.trailingBarButtonGroups = []
        tv.addInteraction(UIScribbleInteraction(delegate: NoScribble.shared))
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification, object: nil)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.onEndEditing = onEndEditing
        context.coordinator.isEditing = isEditing
        context.coordinator.setPaper(paper)
        context.coordinator.applyRemoteTextIfNeeded(from: box.rtfData, isEditing: isEditing)
        if isEditing, !tv.isFirstResponder {
            DispatchQueue.main.async { tv.becomeFirstResponder() }
        } else if !isEditing, tv.isFirstResponder {
            DispatchQueue.main.async { tv.resignFirstResponder() }
        }
    }

    /// Lay out at the proposed width so long text wraps to the next line and the
    /// height grows to fit (never exceeding the page width the parent gives us).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fit.height, 30))
    }

    // MARK: - RTF helpers

    nonisolated static func attributedString(from data: Data) -> NSAttributedString? {
        guard !data.isEmpty else { return nil }
        return try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        let box: TextBox
        var onEndEditing: () -> Void
        var isEditing = false
        private var endingOnPurpose = false
        weak var textView: UITextView?
        var lastAppliedRTFData = Data()
        /// The paper the text view's colors are shown for.
        var paper: PaperColor = .white
        private var saveTask: Task<Void, Never>?

        private let barState = EditBarState()

        init(box: TextBox, onEndEditing: @escaping () -> Void) {
            self.box = box
            self.onEndEditing = onEndEditing
        }

        func applyRemoteTextIfNeeded(from data: Data, isEditing: Bool) {
            guard !isEditing,
                  data != lastAppliedRTFData,
                  let textView else { return }
            if let attributed = TextBoxView.attributedString(from: data), attributed.length > 0 {
                textView.attributedText = paper.shown(attributed)
            } else {
                textView.attributedText = NSAttributedString()
            }
            lastAppliedRTFData = data
        }

        /// Another paper chosen while the text is on screen: show its colors
        /// for the new paper (what is stored doesn't change).
        func setPaper(_ newPaper: PaperColor) {
            guard newPaper != paper, let tv = textView else { return }
            let old = paper
            paper = newPaper
            let selection = tv.selectedRange
            tv.attributedText = newPaper.shown(old.stored(tv.attributedText ?? NSAttributedString()))
            tv.selectedRange = selection
            var typing = tv.typingAttributes
            typing[.foregroundColor] = newPaper.shown(old.stored((typing[.foregroundColor] as? UIColor) ?? .black))
            tv.typingAttributes = typing
            tv.overrideUserInterfaceStyle = newPaper.interfaceStyle
        }

        // MARK: Editing bar

        func makeBar(accent: Color) -> EditBarAccessory {
            var actions = EditBarActions()
            actions.toggleBold = { [weak self] in self?.apply { $0.toggleBold() } }
            actions.toggleItalic = { [weak self] in self?.apply { $0.toggleItalic() } }
            actions.toggleUnderline = { [weak self] in self?.apply { $0.toggleUnderline() } }
            actions.toggleBullets = { [weak self] in self?.apply { $0.toggleBullets() } }
            actions.changeSize = { [weak self] delta in self?.apply { $0.changeSize(by: delta) } }
            actions.setTextColor = { [weak self] color in self?.apply { $0.setColor(color) } }
            actions.setAlignment = { [weak self] alignment in self?.apply { $0.setAlignment(alignment) } }
            actions.setBackground = { [weak self] hex in self?.setBackground(hex) }
            actions.done = { [weak self] in self?.endEditing() }
            barState.backgroundHex = box.backgroundColorRaw
            return EditBarAccessory(kind: .text, state: barState, actions: actions, accent: accent)
        }

        private func apply(_ change: (Coordinator) -> Void) {
            change(self)
            refreshBar()
        }

        private func setBackground(_ hex: String) {
            box.backgroundColorRaw = hex
            box.updatedAt = .now
            box.page?.updatedAt = .now
            try? box.modelContext?.save()
            refreshBar()
        }

        /// Shows what applies at the caret (or the selection's start).
        private func refreshBar() {
            guard let tv = textView else { return }
            let storage = tv.textStorage
            let selection = tv.selectedRange
            let attrs = selection.length > 0 && selection.location < storage.length
                ? storage.attributes(at: selection.location, effectiveRange: nil)
                : tv.typingAttributes
            let traits = ((attrs[.font] as? UIFont) ?? TextBoxView.defaultFont).fontDescriptor.symbolicTraits
            barState.isBold = traits.contains(.traitBold)
            barState.isItalic = traits.contains(.traitItalic)
            barState.isUnderline = (attrs[.underlineStyle] as? Int ?? 0) != 0
            // The bar offers white-paper colors, as they are stored.
            barState.textColor = (attrs[.foregroundColor] as? UIColor).map(paper.stored) ?? .black
            barState.alignment = (attrs[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .left
            barState.backgroundHex = box.backgroundColorRaw
            let text = storage.string as NSString
            let line = text.substring(with: text.paragraphRange(for: NSRange(location: selection.location, length: 0)))
            barState.isBulleted = line.hasPrefix(Self.bullet)
        }

        func textViewDidChangeSelection(_ textView: UITextView) { refreshBar() }

        // MARK: Formatting actions

        private func toggleBold() { toggleTrait(.traitBold) }
        private func toggleItalic() { toggleTrait(.traitItalic) }

        private func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
            guard let tv = textView else { return }
            let range = tv.selectedRange
            if range.length == 0 {
                var attrs = tv.typingAttributes
                let font = (attrs[.font] as? UIFont) ?? TextBoxView.defaultFont
                attrs[.font] = font.byToggling(trait)
                tv.typingAttributes = attrs
                return
            }
            let storage = tv.textStorage
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, subRange, _ in
                let font = (value as? UIFont) ?? TextBoxView.defaultFont
                storage.addAttribute(.font, value: font.byToggling(trait), range: subRange)
            }
            storage.endEditing()
            scheduleSave()
        }

        private func toggleUnderline() {
            guard let tv = textView else { return }
            let range = tv.selectedRange
            if range.length == 0 {
                var attrs = tv.typingAttributes
                let on = (attrs[.underlineStyle] as? Int ?? 0) != 0
                attrs[.underlineStyle] = on ? 0 : NSUnderlineStyle.single.rawValue
                tv.typingAttributes = attrs
                return
            }
            let storage = tv.textStorage
            let current = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
            let newValue = current != 0 ? 0 : NSUnderlineStyle.single.rawValue
            storage.addAttribute(.underlineStyle, value: newValue, range: range)
            scheduleSave()
        }

        private func changeSize(by delta: CGFloat) {
            guard let tv = textView else { return }
            let range = tv.selectedRange
            if range.length == 0 {
                var attrs = tv.typingAttributes
                let font = (attrs[.font] as? UIFont) ?? TextBoxView.defaultFont
                attrs[.font] = font.withSize(max(8, font.pointSize + delta))
                tv.typingAttributes = attrs
                return
            }
            let storage = tv.textStorage
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, subRange, _ in
                let font = (value as? UIFont) ?? TextBoxView.defaultFont
                storage.addAttribute(.font, value: font.withSize(max(8, font.pointSize + delta)), range: subRange)
            }
            storage.endEditing()
            scheduleSave()
        }

        private func setColor(_ stored: UIColor) {
            guard let tv = textView else { return }
            let color = paper.shown(stored)
            let range = tv.selectedRange
            if range.length == 0 {
                var attrs = tv.typingAttributes
                attrs[.foregroundColor] = color
                tv.typingAttributes = attrs
                return
            }
            tv.textStorage.addAttribute(.foregroundColor, value: color, range: range)
            scheduleSave()
        }

        private func setAlignment(_ alignment: NSTextAlignment) {
            guard let tv = textView else { return }
            let storage = tv.textStorage
            let full = NSRange(location: 0, length: storage.length)
            // Change only the alignment, so bullet indents survive.
            if full.length > 0 {
                storage.beginEditing()
                storage.enumerateAttribute(.paragraphStyle, in: full) { value, subRange, _ in
                    let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                        ?? NSMutableParagraphStyle()
                    style.alignment = alignment
                    storage.addAttribute(.paragraphStyle, value: style, range: subRange)
                }
                storage.endEditing()
            }
            var typing = tv.typingAttributes
            let style = ((typing[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            style.alignment = alignment
            typing[.paragraphStyle] = style
            tv.typingAttributes = typing
            scheduleSave()
        }

        // MARK: Bullet lists

        private static let bullet = "\u{2022}\t"
        private var bulletLength: Int { (Self.bullet as NSString).length }

        /// Paragraph style for a bulleted (hanging indent) or plain paragraph,
        /// keeping everything else — alignment in particular — as it was.
        private func paragraphStyle(from base: NSParagraphStyle?, bulleted: Bool,
                                    font: UIFont) -> NSParagraphStyle {
            let style = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            if bulleted {
                let indent = ceil(font.pointSize * 1.3)
                style.firstLineHeadIndent = 0
                style.headIndent = indent
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                style.defaultTabInterval = indent
            } else {
                style.firstLineHeadIndent = 0
                style.headIndent = 0
                style.tabStops = []
            }
            return style
        }

        private func font(at location: Int, in tv: UITextView) -> UIFont {
            let storage = tv.textStorage
            if location < storage.length,
               let font = storage.attribute(.font, at: location, effectiveRange: nil) as? UIFont {
                return font
            }
            return (tv.typingAttributes[.font] as? UIFont) ?? TextBoxView.defaultFont
        }

        private func setBulletStyle(_ bulleted: Bool, paragraph range: NSRange, in tv: UITextView) {
            let storage = tv.textStorage
            let font = font(at: range.location, in: tv)
            if range.length > 0 {
                let base = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
                storage.addAttribute(.paragraphStyle,
                                     value: paragraphStyle(from: base, bulleted: bulleted, font: font),
                                     range: range)
            }
        }

        private func setTypingBullet(_ bulleted: Bool, in tv: UITextView) {
            var typing = tv.typingAttributes
            let font = (typing[.font] as? UIFont) ?? TextBoxView.defaultFont
            typing[.paragraphStyle] = paragraphStyle(from: typing[.paragraphStyle] as? NSParagraphStyle,
                                                     bulleted: bulleted, font: font)
            tv.typingAttributes = typing
        }

        /// Turn the selected paragraphs into a bullet list, or back to plain
        /// text when they all are bullets already.
        private func toggleBullets() {
            guard let tv = textView else { return }
            let storage = tv.textStorage
            let text = storage.string as NSString
            let selection = tv.selectedRange
            let span = text.paragraphRange(for: selection)

            var paragraphs: [NSRange] = []
            text.enumerateSubstrings(in: span, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
                paragraphs.append(range)
            }
            // Caret on an empty last line: that line is the paragraph.
            if paragraphs.isEmpty { paragraphs = [NSRange(location: span.location, length: 0)] }

            let allBulleted = paragraphs.allSatisfy { text.substring(with: $0).hasPrefix(Self.bullet) }
            var newLocation = selection.location
            var newLength = selection.length

            storage.beginEditing()
            // Back to front, so earlier ranges stay valid while editing.
            for range in paragraphs.reversed() {
                let delta: Int
                if allBulleted {
                    storage.replaceCharacters(in: NSRange(location: range.location, length: bulletLength), with: "")
                    delta = -bulletLength
                } else if text.substring(with: range).hasPrefix(Self.bullet) {
                    delta = 0
                } else {
                    var attrs = range.length > 0
                        ? storage.attributes(at: range.location, effectiveRange: nil)
                        : tv.typingAttributes
                    attrs[.paragraphStyle] = nil
                    storage.insert(NSAttributedString(string: Self.bullet, attributes: attrs), at: range.location)
                    delta = bulletLength
                }
                let updated = NSRange(location: range.location, length: range.length + delta)
                setBulletStyle(!allBulleted, paragraph: updated, in: tv)

                // Keep the caret / selection on the same text.
                if range.location <= selection.location {
                    newLocation = max(range.location, newLocation + delta)
                } else if range.location < selection.location + selection.length {
                    newLength += delta
                }
            }
            storage.endEditing()

            tv.selectedRange = NSRange(location: min(newLocation, storage.length),
                                       length: max(0, min(newLength, storage.length - min(newLocation, storage.length))))
            setTypingBullet(!allBulleted, in: tv)
            scheduleSave()
        }

        /// Return inside a bullet continues the list; Return on an empty
        /// bullet ends it.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            guard text == "\n" else { return true }
            let storage = textView.textStorage
            let string = storage.string as NSString
            let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
            let line = string.substring(with: paragraph).trimmingCharacters(in: .newlines)
            guard line.hasPrefix(Self.bullet) else { return true }

            if line == Self.bullet, range.length == 0 {
                storage.beginEditing()
                storage.replaceCharacters(in: NSRange(location: paragraph.location, length: bulletLength), with: "")
                let rest = NSRange(location: paragraph.location, length: paragraph.length - bulletLength)
                setBulletStyle(false, paragraph: rest, in: textView)
                storage.endEditing()
                textView.selectedRange = NSRange(location: paragraph.location, length: 0)
                setTypingBullet(false, in: textView)
            } else {
                var attrs = textView.typingAttributes
                if range.location > 0, range.location <= storage.length {
                    attrs = storage.attributes(at: range.location - 1, effectiveRange: nil)
                }
                let insert = NSAttributedString(string: "\n" + Self.bullet, attributes: attrs)
                storage.replaceCharacters(in: range, with: insert)
                textView.selectedRange = NSRange(location: range.location + insert.length, length: 0)
                textView.typingAttributes = attrs
            }
            scheduleSave()
            return false
        }

        private func endEditing() {
            endingOnPurpose = true
            textView?.resignFirstResponder()
        }

        /// iPad's hide-keyboard key keeps the text view focused: the keyboard
        /// slides away, the formatting bar comes back up on its own and only
        /// then does editing end and the bar leave again, so everything
        /// docked above the keyboard bounced along. Hiding the keyboard ends
        /// editing right away instead, exactly like the Done button.
        @objc func keyboardWillHide(_ note: Notification) {
            guard let textView, textView.isFirstResponder else { return }
            endEditing()
        }

        // MARK: UITextViewDelegate

        func textViewDidBeginEditing(_ textView: UITextView) {
            PhoneKeyboardScroll.shared.begin(textView)
        }

        func textViewDidChange(_ textView: UITextView) {
            scheduleSave()
            PhoneKeyboardScroll.shared.followCaret(of: textView)
        }

        /// A double tap on the page creates the box, and the canvas under it
        /// reaches for the focus a moment later. A box that was only just
        /// created keeps it: giving it up, even briefly, sent the keyboard down
        /// and back up.
        func textViewShouldEndEditing(_ textView: UITextView) -> Bool {
            let isNew = Date.now.timeIntervalSince(box.createdAt) < 0.8
            return !(isEditing && isNew && !endingOnPurpose)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            // UIKit calls this at any moment, also while SwiftUI is updating
            // the screen (a text view leaving the hierarchy ends its editing).
            // Saving and ending change observed state, so they wait for the
            // update to finish. The text is taken now: the view may be gone.
            let text = textView.attributedText ?? NSAttributedString()
            saveTask?.cancel()
            DispatchQueue.main.async { [self] in
                save(text)
                onEndEditing()
            }
        }

        // MARK: Persistence

        private func scheduleSave() {
            saveTask?.cancel()
            saveTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
                self.saveNow()
            }
        }

        private func saveNow() {
            guard let tv = textView else { return }
            save(tv.attributedText ?? NSAttributedString())
        }

        private func save(_ attributed: NSAttributedString) {
            guard box.modelContext != nil else { return }
            let attributed = paper.stored(attributed)
            let range = NSRange(location: 0, length: attributed.length)
            if let data = try? attributed.data(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            ) {
                box.rtfData = data
                box.updatedAt = .now
                box.page?.updatedAt = .now
                lastAppliedRTFData = data
                try? box.modelContext?.save()
                SyncLog.saved("text", bytes: data.count)
            }
        }
    }
}

/// Scribble off: on the page the Pencil always means ink, never handwriting
/// turned into text. Shared, because an interaction holds its delegate weakly.
final class NoScribble: NSObject, UIScribbleInteractionDelegate {
    static let shared = NoScribble()

    func scribbleInteraction(_ interaction: UIScribbleInteraction,
                             shouldBeginAt location: CGPoint) -> Bool {
        false
    }
}

private extension UIFont {
    func byToggling(_ trait: UIFontDescriptor.SymbolicTraits) -> UIFont {
        var traits = fontDescriptor.symbolicTraits
        if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
