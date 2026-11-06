//
//  ChecklistBoxContainer.swift
//  MyAgenda
//
//  A dedicated checklist, used like text: it sits directly on the paper, opens
//  for editing the same way (one tap on iPhone, two on iPad), moves after press
//  and hold, has the same editing bar and disappears when left empty. A tap on
//  a circle ticks it. Uses UIKit text fields so Return moves to a new row
//  without the keyboard flickering, and Backspace on an empty row deletes it
//  and moves up (like Reminders).
//

import SwiftUI
import SwiftData
import UIKit

struct ChecklistBoxContainer: View {
    let box: ChecklistBox
    let pageSize: CGSize
    /// How much the page is shrunk on screen (iPhone), as for text boxes.
    var scale: CGFloat = 1
    var fontSize: CGFloat = 19
    var editTapCount: Int = 2
    /// Items are black on light paper and white on dark paper.
    var paper: PaperColor = .white
    var accent: Color = .accentColor
    var isEditing: Bool
    var onSetEditing: (Bool) -> Void
    var onMove: (Double, Double) -> Void
    var onResize: (Double) -> Void
    /// Held long enough to move (true), then let go (false).
    var onLift: (Bool) -> Void
    var onDelete: () -> Void

    @Environment(\.modelContext) private var context
    @State private var dragOffset: CGSize = .zero
    /// Held long enough to move.
    @State private var isLifted = false
    @State private var widthDelta: CGFloat = 0
    @State private var draft: [ChecklistItem] = []
    @State private var focusedItem: UUID?
    @State private var draftStart = Date.distantPast
    @State private var saveTask: Task<Void, Never>?
    @State private var barState = EditBarState()
    @State private var bar: EditBarAccessory?

    private var displayItems: [ChecklistItem] { isEditing ? draft : box.items }

    var body: some View {
        let baseX = box.x * pageSize.width
        // Anchor Y to the page WIDTH (stable) so boxes don't slide down as the
        // page grows taller on scroll.
        let baseY = box.y * pageSize.width
        // Leaves room for the padding around the rows, inside the page's edge.
        let maxWidth = max(140, pageSize.width * (1 - box.x) - 26)
        let width = min(max(140, box.widthFraction * pageSize.width + widthDelta), maxWidth)

        content
            .frame(width: width, alignment: .topLeading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(boxFill))
            .overlay(alignment: .bottomTrailing) { if isEditing { resizeHandle(width: width) } }
            .contentShape(Rectangle())
            .onTapGesture(count: editTapCount) { if !isEditing { onSetEditing(true) } }
            .modifier(EnabledGesture(enabled: !isEditing, gesture: moveGesture(baseX: baseX, baseY: baseY)))
            // Lifts slightly under the finger once it can be moved.
            .scaleEffect(isLifted ? 1.02 : 1, anchor: .topLeading)
            .animation(.snappy(duration: 0.18), value: isLifted)
            .offset(x: baseX + dragOffset.width, y: baseY + dragOffset.height)
            .onChange(of: isLifted) { _, lifted in
                onLift(lifted)
                guard lifted else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            .onAppear { if isEditing { beginDraft() } }
            .onChange(of: isEditing) { _, editing in
                if editing { beginDraft() } else { endDraft() }
            }
            .onChange(of: draft) { if isEditing { scheduleSave() } }
            .onChange(of: box.backgroundColorRaw) { _, hex in barState.backgroundHex = hex }
            // The keyboard's own hide key ends editing, as for text.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                guard isEditing, Date.now.timeIntervalSince(draftStart) > 0.8 else { return }
                // Right now, like text: left focused, the bar above the keyboard
                // stays docked at the bottom a moment longer. The state changes
                // wait for the next turn: this signal can arrive while SwiftUI
                // is updating the screen.
                dismissKeyboard()
                DispatchQueue.main.async { onSetEditing(false) }
            }
            .onDisappear { if isEditing { commit(cleaned(draft)) } }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(displayItems) { item in
                row(item)
            }
            if !isEditing && displayItems.isEmpty {
                Text("Checklist gol").font(.system(size: fontSize)).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ item: ChecklistItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { toggle(item.id) } label: {
                Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: fontSize))
                    .foregroundStyle(item.checked ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)

            if isEditing {
                ChecklistItemField(
                    text: draftBinding(item.id),
                    isFocused: focusedItem == item.id,
                    fontSize: fontSize,
                    textColor: item.checked ? UIColor.systemGreen : paper.shown(.black),
                    interfaceStyle: paper.interfaceStyle,
                    accessory: bar,
                    onReturn: { onReturn(item.id) },
                    onBackspaceWhenEmpty: { backspace(item.id) },
                    onBeginEditing: { if focusedItem != item.id { focusedItem = item.id } }
                )
            } else {
                Text(item.text.isEmpty ? " " : item.text)
                    .font(.system(size: fontSize))
                    .foregroundStyle(item.checked ? Color.green : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Background color

    private var boxFill: Color {
        guard !box.backgroundColorRaw.isEmpty, let color = Color(hex: box.backgroundColorRaw) else { return .clear }
        return color.opacity(EditPalette.backgroundOpacity)
    }

    private func setBackground(_ hex: String) {
        box.backgroundColorRaw = hex
        box.page?.updatedAt = .now
        try? context.save()
    }

    // MARK: - Controls

    private func resizeHandle(width: CGFloat) -> some View {
        WidthHandleMark(scale: scale)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { widthDelta = $0.translation.width / scale }
                    .onEnded { value in
                        let base = box.widthFraction * pageSize.width
                        let maxFraction = max(0.2, 1 - box.x - 0.02)
                        let fraction = (base + value.translation.width / scale) / pageSize.width
                        onResize(min(max(Double(fraction), 0.15), maxFraction))
                        widthDelta = 0
                    }
            )
    }

    /// Press and hold, then drag, exactly like text: a plain drag scrolls.
    private func moveGesture(baseX: CGFloat, baseY: CGFloat) -> HoldToMoveGesture {
        HoldToMoveGesture(
            onLift: { isLifted = $0 },
            onChange: { moved in
                dragOffset = CGSize(width: moved.width / scale, height: moved.height / scale)
            },
            onEnd: { moved in
                let nx = (baseX + moved.width / scale) / pageSize.width
                let ny = (baseY + moved.height / scale) / pageSize.width
                let maxY = Double((pageSize.height - 20) / pageSize.width)
                onMove(min(max(Double(nx), 0), 0.97), min(max(Double(ny), 0), maxY))
                dragOffset = .zero
            }
        )
    }

    // MARK: - Draft / mutations

    private func beginDraft() {
        if bar == nil {
            var actions = EditBarActions()
            actions.addItem = { addItem() }
            actions.setBackground = { setBackground($0) }
            actions.done = { onSetEditing(false) }
            bar = EditBarAccessory(kind: .checklist, state: barState, actions: actions, accent: accent)
        }
        barState.backgroundHex = box.backgroundColorRaw
        draftStart = .now
        let existing = box.items
        draft = existing.isEmpty ? [ChecklistItem()] : existing
        focusedItem = draft.first?.id
    }

    private func endDraft() {
        saveTask?.cancel()
        let items = cleaned(draft)
        commit(items)
        // Like a text box: left empty, it goes away.
        if items.isEmpty { onDelete() }
        draft = []
        focusedItem = nil
        dismissKeyboard()
    }

    private func cleaned(_ items: [ChecklistItem]) -> [ChecklistItem] {
        items.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// While typing, as for text, so the rows reach the other device without
    /// leaving the checklist. Rows left blank wait until editing ends.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            let items = cleaned(draft)
            if !items.isEmpty, items != box.items { commit(items) }
        }
    }

    private func commit(_ items: [ChecklistItem]) {
        box.items = items
        box.page?.updatedAt = .now
        try? context.save()
        SyncLog.saved("checklist", bytes: box.itemsData.count)
    }

    private func toggle(_ id: UUID) {
        if isEditing {
            if let i = draft.firstIndex(where: { $0.id == id }) { draft[i].checked.toggle() }
        } else {
            var arr = box.items
            if let i = arr.firstIndex(where: { $0.id == id }) {
                arr[i].checked.toggle()
                commit(arr)
            }
        }
    }

    private func addItem() {
        let new = ChecklistItem()
        draft.append(new)
        focusedItem = new.id
    }

    private func onReturn(_ id: UUID) {
        guard let i = draft.firstIndex(where: { $0.id == id }) else { return }
        if draft[i].text.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.remove(at: i)
            onSetEditing(false)   // empty item + Return → leave the checklist
        } else {
            let new = ChecklistItem()
            draft.insert(new, at: i + 1)
            focusedItem = new.id
        }
    }

    private func backspace(_ id: UUID) {
        guard let i = draft.firstIndex(where: { $0.id == id }), i > 0 else { return }
        let previous = draft[i - 1].id
        // Move focus to the previous row FIRST so it grabs first responder
        // (keeping the keyboard up), then drop the now-unfocused empty row.
        focusedItem = previous
        DispatchQueue.main.async {
            draft.removeAll { $0.id == id }
        }
    }

    private func draftBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { draft.first(where: { $0.id == id })?.text ?? "" },
            set: { newText in
                if let i = draft.firstIndex(where: { $0.id == id }) { draft[i].text = newText }
            }
        )
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

// MARK: - UIKit text field for a checklist row

private final class BackspaceTextField: UITextField {
    var onBackspaceWhenEmpty: (() -> Void)?
    override func deleteBackward() {
        if (text ?? "").isEmpty {
            onBackspaceWhenEmpty?()
            return
        }
        super.deleteBackward()
    }
}

private struct ChecklistItemField: UIViewRepresentable {
    @Binding var text: String
    var isFocused: Bool
    var fontSize: CGFloat
    var textColor: UIColor
    var interfaceStyle: UIUserInterfaceStyle = .light
    var accessory: UIView?
    var onReturn: () -> Void
    var onBackspaceWhenEmpty: () -> Void
    var onBeginEditing: () -> Void

    func makeUIView(context: Context) -> BackspaceTextField {
        let tf = BackspaceTextField()
        tf.delegate = context.coordinator
        tf.font = .systemFont(ofSize: fontSize)
        tf.textColor = textColor
        tf.text = text
        tf.returnKeyType = .next
        tf.overrideUserInterfaceStyle = interfaceStyle
        tf.inputAccessoryView = accessory
        tf.inputAssistantItem.trailingBarButtonGroups = []
        tf.addInteraction(UIScribbleInteraction(delegate: NoScribble.shared))
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.onBackspaceWhenEmpty = { context.coordinator.parent.onBackspaceWhenEmpty() }
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        return tf
    }

    func updateUIView(_ tf: BackspaceTextField, context: Context) {
        context.coordinator.parent = self
        if tf.text != text { tf.text = text }
        tf.textColor = textColor
        tf.overrideUserInterfaceStyle = interfaceStyle
        // Only become first responder; never explicitly resign — that keeps the
        // keyboard up when focus moves between rows (no flicker). Doing this
        // synchronously (not via async) makes the previous row grab focus before
        // a deleted row is torn down, so Backspace-to-merge keeps the keyboard up.
        if isFocused && !tf.isFirstResponder {
            tf.becomeFirstResponder()
            let end = tf.endOfDocument
            tf.selectedTextRange = tf.textRange(from: end, to: end)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BackspaceTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        // Match the display-mode SwiftUI Text height (its font line height) so
        // rows aren't more spaced out while editing.
        let height = ceil(UIFont.systemFont(ofSize: fontSize).lineHeight)
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ChecklistItemField
        init(_ parent: ChecklistItemField) { self.parent = parent }

        @objc func editingChanged(_ tf: UITextField) { parent.text = tf.text ?? "" }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onReturn()
            return false
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            PhoneKeyboardScroll.shared.begin(textField)
            parent.onBeginEditing()
        }
    }
}

/// Applies the move gesture only when enabled.
private struct EnabledGesture: ViewModifier {
    let enabled: Bool
    let gesture: HoldToMoveGesture
    func body(content: Content) -> some View {
        if enabled { content.gesture(gesture) } else { content }
    }
}
