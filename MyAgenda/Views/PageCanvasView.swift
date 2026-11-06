//
//  PageCanvasView.swift
//  MyAgenda
//
//  SwiftUI wrapper around PKCanvasView. Loads a page's drawing, applies the
//  current tool and persists changes (debounced). On iPad the canvas sits
//  above the page's text, checklists and photos, so the Pencil writes over
//  them; the finger goes through to whatever is underneath.
//

import SwiftUI
import PencilKit
import SwiftData

/// The canvas covers the whole page, boxes included, so it lets touches fall
/// through: a view can't tell the Pencil from a finger when it is hit (the
/// touch isn't known yet). PencilKit's drawing recognizer sits on the page's
/// scroll view instead, which sees the Pencil whatever it lands on, and draws
/// with the same tools as ever. Hover stays, for the Pencil's tool preview.
final class PencilCanvasView: PKCanvasView {
    /// Pen, highlighter, eraser: the Pencil draws over the boxes too.
    var reachesOverBoxes = false {
        didSet { if reachesOverBoxes != oldValue { placeDrawingRecognizer() } }
    }

    /// With the lasso the canvas works as PencilKit made it and takes every
    /// touch, so a selection can be dragged and its menu opened.
    var takesTouches = false

    private let pencilAnywhere = PencilAnywhereDelegate()
    private weak var pencilKitHome: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard takesTouches || event?.type == .hover else { return nil }
        return super.hitTest(point, with: event)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        placeDrawingRecognizer()
    }

    // Leaving the page: PencilKit gets its recognizer back, so the scroll view
    // never keeps one whose delegate is gone.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        if drawingGestureRecognizer.delegate === pencilAnywhere {
            drawingGestureRecognizer.delegate = pencilAnywhere.pencilKit
        }
        if let home = pencilKitHome, drawingGestureRecognizer.view !== home {
            home.addGestureRecognizer(drawingGestureRecognizer)
        }
    }

    private func placeDrawingRecognizer() {
        guard window != nil, let page = pageScrollView else { return }
        let recognizer = drawingGestureRecognizer
        if pencilKitHome == nil { pencilKitHome = recognizer.view }
        if reachesOverBoxes {
            if recognizer.delegate !== pencilAnywhere {
                pencilAnywhere.pencilKit = recognizer.delegate
                pencilAnywhere.canvas = self
                recognizer.delegate = pencilAnywhere
            }
        } else if recognizer.delegate === pencilAnywhere {
            recognizer.delegate = pencilAnywhere.pencilKit
        }
        if let home = reachesOverBoxes ? page : pencilKitHome, recognizer.view !== home {
            home.addGestureRecognizer(recognizer)
        }
    }

    /// The scroll view holding the page: the canvas and every box.
    private var pageScrollView: UIScrollView? {
        var next = superview
        while let candidate = next {
            if let scroll = candidate as? UIScrollView { return scroll }
            next = candidate.superview
        }
        return nil
    }
}

/// Stands in for PencilKit as the drawing recognizer's delegate. PencilKit
/// only takes touches that land on the canvas itself, and the Pencil now
/// often lands on a box above it; everything else is PencilKit's own call.
private final class PencilAnywhereDelegate: NSObject, UIGestureRecognizerDelegate {
    // UIKit asks `responds(to:)` and `forwardingTarget(for:)` from outside the
    // main actor's view, but only ever on the main thread.
    nonisolated(unsafe) weak var pencilKit: UIGestureRecognizerDelegate?
    weak var canvas: UIView?

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if pencilKit?.gestureRecognizer?(recognizer, shouldReceive: touch) ?? true { return true }
        // A touch on the canvas itself stays PencilKit's call.
        guard let canvas, touch.view?.isDescendant(of: canvas) != true else { return false }
        return touch.type == .pencil && canvas.bounds.contains(touch.location(in: canvas))
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (pencilKit?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? { pencilKit }
}

struct PageCanvasView: UIViewRepresentable {
    let page: JournalPage
    let tool: PKTool
    let toolKind: PenSettings.ToolKind
    var proxy: CanvasProxy
    var isActive: Bool
    /// Dark paper shows the ink inverted (PencilKit's dark mode); the strokes
    /// are still stored with their white-paper colors.
    var paper: PaperColor = .white
    /// iPad: the Pencil draws over the page's boxes. Off on iPhone, where the
    /// finger must always reach the page.
    var isPencilDevice = false
    /// Apple Pencil Pro squeeze.
    var onSqueeze: () -> Void = {}
    /// Apple Pencil double-tap.
    var onDoubleTap: () -> Void = {}
    /// Any tool starts on the canvas (pen, highlighter, eraser, lasso).
    var onInkBegan: () -> Void = {}

    // Pencil-only everywhere: on iPhone (no Pencil) this makes the page
    // view-only for drawing; the finger scrolls instead.
    private var drawingPolicy: PKCanvasViewDrawingPolicy { .pencilOnly }

    func makeCoordinator() -> Coordinator {
        Coordinator(page: page, proxy: proxy, onSqueeze: onSqueeze, onDoubleTap: onDoubleTap,
                    onInkBegan: onInkBegan)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PencilCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = drawingPolicy
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // The outer SwiftUI ScrollView handles vertical scrolling so the page
        // can grow downward; the canvas itself does not scroll.
        canvas.isScrollEnabled = false
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false

        // Apple Pencil (Pro) interactions: squeeze / double-tap.
        let pencil = UIPencilInteraction()
        pencil.delegate = context.coordinator
        canvas.addInteraction(pencil)

        // The paper decides the appearance, not the system: black ink stays
        // black on light paper even in dark mode, and turns white on dark paper.
        canvas.overrideUserInterfaceStyle = paper.interfaceStyle

        if let drawing = try? PKDrawing(data: page.drawingData) {
            context.coordinator.show(drawing, on: canvas)
        }
        context.coordinator.lastAppliedDrawingData = page.drawingData
        canvas.tool = tool
        applyInput(to: canvas)

        context.coordinator.canvas = canvas
        if isActive { proxy.canvas = canvas }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.tool = tool
        canvas.drawingPolicy = drawingPolicy
        canvas.overrideUserInterfaceStyle = paper.interfaceStyle
        applyInput(to: canvas)
        context.coordinator.onSqueeze = onSqueeze
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.onInkBegan = onInkBegan
        context.coordinator.applyRemoteDrawingIfNeeded(from: page.drawingData)
        if isActive { proxy.canvas = canvas }
    }

    private func applyInput(to canvas: PKCanvasView) {
        guard let canvas = canvas as? PencilCanvasView else { return }
        canvas.takesTouches = isPencilDevice && toolKind == .lasso
        canvas.reachesOverBoxes = isPencilDevice && toolKind != .lasso
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        let page: JournalPage
        let proxy: CanvasProxy
        var onSqueeze: () -> Void
        var onDoubleTap: () -> Void
        var onInkBegan: () -> Void
        weak var canvas: PKCanvasView?
        var lastAppliedDrawingData = Data()
        private var saveTask: Task<Void, Never>?
        private var isApplyingRemoteDrawing = false

        init(page: JournalPage,
             proxy: CanvasProxy,
             onSqueeze: @escaping () -> Void,
             onDoubleTap: @escaping () -> Void,
             onInkBegan: @escaping () -> Void) {
            self.page = page
            self.proxy = proxy
            self.onSqueeze = onSqueeze
            self.onDoubleTap = onDoubleTap
            self.onInkBegan = onInkBegan
        }

        func applyRemoteDrawingIfNeeded(from data: Data) {
            guard data != lastAppliedDrawingData,
                  saveTask == nil,
                  let canvas,
                  let drawing = try? PKDrawing(data: data) else { return }
            show(drawing, on: canvas)
            lastAppliedDrawingData = data
        }

        /// Puts ink on the canvas that nobody drew here (the stored page, or a
        /// change from the other device). PencilKit reports it as a change,
        /// sometimes a moment later; saving that would send the same ink back
        /// to iCloud, and the two devices kept bouncing a page between them.
        func show(_ drawing: PKDrawing, on canvas: PKCanvasView) {
            isApplyingRemoteDrawing = true
            canvas.drawing = drawing
            Task { @MainActor [weak self] in self?.isApplyingRemoteDrawing = false }
        }

        // MARK: UIPencilInteractionDelegate

        func pencilInteraction(_ interaction: UIPencilInteraction,
                               didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            if squeeze.phase == .ended {
                Task { @MainActor in self.onSqueeze() }
            }
        }

        func pencilInteraction(_ interaction: UIPencilInteraction,
                               didReceiveTap tap: UIPencilInteraction.Tap) {
            Task { @MainActor in self.onDoubleTap() }
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            onInkBegan()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingRemoteDrawing else { return }
            let size = canvasView.bounds.size
            // Persist on demand by reading the *live* canvas — serializing only
            // when it actually runs (debounce or flush), not on every change.
            proxy.flushPendingSave = { [weak self, weak canvasView, page] in
                guard let canvasView, page.modelContext != nil else { return }
                let data = canvasView.drawing.dataRepresentation()
                // The same ink as stored: nothing to save or send.
                guard data != self?.lastAppliedDrawingData else {
                    self?.saveTask = nil
                    return
                }
                page.drawingData = data
                if size.width > 0, size.height > 0 {
                    page.canvasWidth = Double(size.width)
                    page.canvasHeight = Double(size.height)
                }
                page.updatedAt = .now
                self?.lastAppliedDrawingData = data
                try? page.modelContext?.save()
                SyncLog.saved("cerneală", bytes: data.count)
                self?.saveTask = nil
            }
            saveTask?.cancel()
            saveTask = Task { @MainActor [weak self] in
                // After a real pause, not between two words: each save sends the
                // page's whole ink to iCloud, and too many in a row get throttled.
                // Leaving the page or the app saves right away.
                try? await Task.sleep(for: .milliseconds(1500))
                if Task.isCancelled { return }
                self?.proxy.flushPendingSave?()
            }
        }
    }
}
