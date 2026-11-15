//
//  PenToolbar.swift
//  MyAgenda
//
//  Floating toolbar content. Color + width live in a glass popover attached to
//  the pen / highlighter (and the size in one on the eraser), keeping the bar
//  itself uncluttered. The glass capsule
//  itself is applied by NotebookPagesView, which hosts the toolbar in a shared
//  GlassEffectContainer so it can morph into its reopen handle when pushed off
//  to the right.
//

import SwiftUI
import PencilKit
import UIKit

struct PenToolbar: View {
    @Bindable var pen: PenSettings
    var proxy: CanvasProxy
    var showsDrawingTools: Bool = true
    /// Tighter spacing, so the full bar fits beside the iPad tags panel.
    var compact = false
    /// iPad: docked on a side, the bar runs top to bottom.
    var edge: ToolbarEdge = .bottom
    /// iPad: a hold that lifted the bar must not also press the button under it.
    var move: ToolbarMove? = nil
    var onAddText: () -> Void
    var onAddChecklist: () -> Void
    var onAddPhoto: () -> Void
    var onAddPage: () -> Void
    var onTimer: () -> Void

    @State private var showInkOptions = false
    @State private var showEraserOptions = false

    var body: some View {
        let vertical = edge != .bottom
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: compact ? 6 : 12))
        layout {
            if showsDrawingTools {
                inkToolButton(.pen, system: "applepencil.tip", label: "Pen")
                inkToolButton(.highlighter, system: "highlighter", label: "Highlighter")
                eraserButton
                toolButton(.lasso, system: "lasso", label: "Lasso")
            }

            iconButton("character.textbox", label: "Add Text", action: onAddText)
            iconButton("checklist", label: "Add Checklist", action: onAddChecklist)
            iconButton("photo", label: "Add Photo", action: onAddPhoto)

            if showsDrawingTools {
                divider

                iconButton("arrow.uturn.backward", label: "Undo") { proxy.undo() }
                iconButton("arrow.uturn.forward", label: "Redo") { proxy.redo() }
            }

            divider

            iconButton("timer", label: "Timer", action: onTimer)
            iconButton("plus.rectangle.on.rectangle", label: "New Page", action: onAddPage)
        }
        .padding(.horizontal, vertical ? 9 : (compact ? 12 : 16))
        .padding(.vertical, vertical ? 16 : 9)
        // An open popover would point at where the button was.
        .onChange(of: edge) {
            showInkOptions = false
            showEraserOptions = false
        }
        // A tool changed from elsewhere (Pencil double-tap, squeeze bar): the
        // open options belong to the old one, and kept on they reopened when
        // the tool came back.
        .onChange(of: pen.tool) {
            showInkOptions = false
            showEraserOptions = false
        }
    }

    // MARK: - Components

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: edge == .bottom ? 1 : 26, height: edge == .bottom ? 26 : 1)
    }

    /// The options popover of a tool button. Bottom: SwiftUI's, as always.
    /// Sides: UIKit's (see SidePopover). A new anchor per edge: after moving,
    /// SwiftUI's kept pointing at where the button had been.
    private func optionsPopover<P: View>(_ isPresented: Binding<Bool>,
                                         @ViewBuilder content: @escaping () -> P) -> some View {
        Color.clear
            .popover(isPresented: edge == .bottom ? isPresented : .constant(false), content: content)
            .background {
                SidePopover(isPresented: edge == .bottom ? .constant(false) : isPresented,
                            edge: edge, content: content)
            }
            .id(edge)
    }

    /// Pen / highlighter: selecting shows a color dot; tapping again opens the
    /// color + width options popover.
    private func inkToolButton(_ kind: PenSettings.ToolKind, system: String, label: String) -> some View {
        let isSelected = pen.tool == kind
        return Button {
            guard move?.didLift != true else { return }
            if pen.tool == kind {
                showInkOptions = true
            } else {
                pen.tool = kind
            }
        } label: {
            ToolIcon(system: system, isSelected: isSelected, dot: pen.color(for: kind))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "Tap again for color and thickness" : "")
        .background { optionsPopover(popoverBinding(for: kind)) { InkOptionsView(pen: pen) } }
    }

    /// Eraser: tapping it again (once selected) opens the size popover.
    private var eraserButton: some View {
        let isSelected = pen.tool == .eraser
        return Button {
            guard move?.didLift != true else { return }
            if isSelected { showEraserOptions = true } else { pen.tool = .eraser }
        } label: {
            ToolIcon(system: "eraser.fill", isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Eraser")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "Tap again for size" : "")
        .background { optionsPopover($showEraserOptions) { EraserOptionsView(pen: pen) } }
    }

    /// Only show the popover from the currently-active ink tool's button.
    private func popoverBinding(for kind: PenSettings.ToolKind) -> Binding<Bool> {
        Binding(
            get: { showInkOptions && pen.tool == kind },
            set: { showInkOptions = $0 }
        )
    }

    private func toolButton(_ kind: PenSettings.ToolKind, system: String, label: String) -> some View {
        let isSelected = pen.tool == kind
        return Button {
            guard move?.didLift != true else { return }
            pen.tool = kind
        } label: {
            ToolIcon(system: system, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func iconButton(_ system: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            guard move?.didLift != true else { return }
            action()
        } label: {
            Image(systemName: system)
                .font(.system(size: 17))
                .frame(width: 34, height: 34)
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Tool icon

/// A drawing tool's icon: filled with the accent when selected, with the
/// ink's colour as a dot (pen, highlighter). Shared with the squeeze bar.
struct ToolIcon: View {
    let system: String
    let isSelected: Bool
    var dot: Color? = nil
    /// False: the accent circle is drawn by the caller (the squeeze bar's
    /// sliding one).
    var fill = true

    var body: some View {
        Image(systemName: system)
            .font(.system(size: 18))
            .frame(width: 36, height: 36)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected && fill ? Color.accentColor : Color.clear, in: Circle())
            .overlay(alignment: .bottomTrailing) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                        .offset(x: 1, y: 1)
                }
            }
    }
}

// MARK: - Side popover

/// A tool's options beside a bar docked on a side, presented by UIKit:
/// SwiftUI's popover ignored `arrowEdge` there and opened over the bar. The
/// arrow points at the button and the card opens toward the page.
struct SidePopover<Content: View>: UIViewRepresentable {
    @Binding var isPresented: Bool
    var edge: ToolbarEdge
    var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let anchor = UIView()
        anchor.isUserInteractionEnabled = false
        return anchor
    }

    func updateUIView(_ anchor: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        if let shown = coordinator.shown, shown.presentingViewController != nil {
            if isPresented {
                shown.rootView = content()
            } else {
                coordinator.shown = nil
                shown.dismiss(animated: true)
            }
            return
        }
        coordinator.shown = nil
        guard isPresented else { return }
        var responder: UIResponder? = anchor.next
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard anchor.window != nil, let presenter = responder as? UIViewController,
              presenter.presentedViewController == nil else {
            // Nothing to present from: the button must still open it next time.
            DispatchQueue.main.async { isPresented = false }
            return
        }
        let card = UIHostingController(rootView: content())
        card.sizingOptions = .preferredContentSize
        card.view.backgroundColor = .clear
        // Outside the SwiftUI tree the notebook's tint arrives only this way.
        card.view.tintColor = anchor.tintColor
        card.modalPresentationStyle = .popover
        if let popover = card.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
            popover.permittedArrowDirections = edge == .left ? .left : .right
            // The card itself is the glass, as with SwiftUI's presentationBackground(.clear).
            popover.backgroundColor = .clear
            popover.delegate = coordinator
        }
        coordinator.shown = card
        presenter.present(card, animated: true)
    }

    static func dismantleUIView(_ anchor: UIView, coordinator: Coordinator) {
        coordinator.shown?.dismiss(animated: false)
    }

    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var shown: UIHostingController<Content>?
        var isPresented: Binding<Bool>?

        /// A popover in a narrow window too, never a sheet.
        func adaptivePresentationStyle(for controller: UIPresentationController,
                                       traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            shown = nil
            isPresented?.wrappedValue = false
        }
    }
}

// MARK: - Ink options popover (color + width slider), as a Liquid Glass card

struct InkOptionsView: View {
    @Bindable var pen: PenSettings

    /// VoiceOver names of the swatches, in `PenSettings.palette`'s order.
    private static let swatchNames = ["Black", "Blue", "Red", "Green", "Orange", "Purple"]

    private var widthRange: ClosedRange<Double> {
        pen.tool == .highlighter ? 6...96 : 0.5...18
    }

    /// The width the line is drawn with: the highlighter's chisel draws much
    /// narrower than its stored size.
    private var shownWidth: CGFloat {
        pen.tool == .highlighter ? InkGeometry.width(for: pen.activeWidth, inkType: .marker) : pen.activeWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(pen.tool == .highlighter ? "Highlighter" : "Pen")
                .font(.headline)

            // Ink style (writing pen only)
            if pen.tool == .pen {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ink").font(.subheadline).foregroundStyle(.secondary)
                    // Each ink remembers its own color and width (PenInkMemory).
                    Picker("Ink", selection: Binding(
                        get: { pen.penInk },
                        set: { ink in withAnimation(.snappy(duration: 0.2)) { pen.selectInk(ink) } }
                    )) {
                        ForEach(PenSettings.PenInk.allCases) { ink in
                            Text(ink.label).tag(ink)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            // Colors
            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(PenSettings.palette.indices, id: \.self) { index in
                        swatch(PenSettings.palette[index], name: Self.swatchNames.indices.contains(index) ? Self.swatchNames[index] : "Color")
                    }
                    ColorPicker("More Colors", selection: $pen.color, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 30, height: 30)
                }
            }

            // Width slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Thickness").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f pt", shownWidth))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Circle().fill(.primary).frame(width: 4, height: 4)
                    Slider(
                        value: Binding(
                            get: { Double(pen.activeWidth) },
                            set: { pen.activeWidth = CGFloat($0) }
                        ),
                        in: widthRange
                    )
                    .accessibilityLabel("Thickness")
                    .accessibilityValue(Double(shownWidth).formatted(.number.precision(.fractionLength(1))
                        .locale(.app)) + " pt")
                    Circle().fill(.primary).frame(width: 16, height: 16)
                }
                // Live preview
                Capsule()
                    .fill(pen.color)
                    .frame(height: max(shownWidth, 1))
                    .frame(maxWidth: .infinity)
                    .frame(height: pen.tool == .highlighter ? 64 : 44)
            }
        }
        .padding(20)
        .frame(width: 300)
        // The popover chrome is cleared so the card itself is the glass.
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .presentationCompactAdaptation(.popover)
        .presentationBackground(.clear)
    }

    private func swatch(_ color: Color, name: String) -> some View {
        let isSelected = pen.color == color
        return Button {
            withAnimation(.snappy(duration: 0.2)) { pen.color = color }
        } label: {
            Circle()
                .fill(color)
                .frame(width: 28, height: 28)
                .overlay(
                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: isSelected ? 2.5 : 0)
                        .padding(isSelected ? 2 : 0)
                )
                .overlay(
                    Circle().strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                          lineWidth: isSelected ? 2 : 1)
                )
                .scaleEffect(isSelected ? 1.1 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Eraser options popover (size), as a Liquid Glass card

struct EraserOptionsView: View {
    @Bindable var pen: PenSettings

    var body: some View {
        let range = PenSettings.eraserWidthRange
        VStack(alignment: .leading, spacing: 18) {
            Text("Eraser").font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Size").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f pt", pen.eraserWidth))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Circle().strokeBorder(.primary, lineWidth: 1).frame(width: 6, height: 6)
                    Slider(
                        value: Binding(
                            // Clamped, so a stored size outside the range
                            // can't pin the thumb to an end.
                            get: { Double(min(max(pen.eraserWidth, range.lowerBound), range.upperBound)) },
                            set: { pen.eraserWidth = CGFloat($0) }
                        ),
                        in: Double(range.lowerBound)...Double(range.upperBound)
                    )
                    .accessibilityLabel("Size")
                    .accessibilityValue(Double(pen.eraserWidth).formatted(.number.precision(.fractionLength(0))
                        .locale(.app)) + " pt")
                    Circle().strokeBorder(.primary, lineWidth: 1).frame(width: 18, height: 18)
                }
                // Live preview at real size (capped to the card).
                Circle()
                    .strokeBorder(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                    .frame(width: min(pen.eraserWidth, 120), height: min(pen.eraserWidth, 120))
                    .frame(maxWidth: .infinity)
                    .frame(height: 124)
            }
        }
        .padding(20)
        .frame(width: 280)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .presentationCompactAdaptation(.popover)
        .presentationBackground(.clear)
    }
}
