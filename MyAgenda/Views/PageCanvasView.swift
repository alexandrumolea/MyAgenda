//
//  PageCanvasView.swift
//  MyAgenda
//
//  SwiftUI wrapper around PKCanvasView. Loads a page's drawing, applies the
//  current tool, persists changes (debounced), and reports finger taps so the
//  page can place a text box (Pencil draws, finger = text on iPad).
//

import SwiftUI
import PencilKit
import SwiftData

struct PageCanvasView: UIViewRepresentable {
    let page: JournalPage
    let tool: PKTool
    let toolKind: PenSettings.ToolKind
    var proxy: CanvasProxy
    var isActive: Bool
    /// Dark paper shows the ink inverted (PencilKit's dark mode); the strokes
    /// are still stored with their white-paper colors.
    var paper: PaperColor = .white
    /// Apple Pencil Pro squeeze.
    var onSqueeze: () -> Void = {}
    /// Apple Pencil double-tap.
    var onDoubleTap: () -> Void = {}
    /// Finger double-tap on the bare page (nil = off). Boxes and photos sit
    /// above the canvas, so they keep their own taps; Pencil is excluded.
    var onFingerDoubleTap: ((CGPoint) -> Void)?

    // Pencil-only everywhere: on iPhone (no Pencil) this makes the page
    // view-only for drawing; the finger scrolls instead.
    private var drawingPolicy: PKCanvasViewDrawingPolicy { .pencilOnly }

    func makeCoordinator() -> Coordinator {
        Coordinator(page: page, proxy: proxy, onSqueeze: onSqueeze, onDoubleTap: onDoubleTap)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
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

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleFingerDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = context.coordinator
        canvas.addGestureRecognizer(doubleTap)
        // The paper decides the appearance, not the system: black ink stays
        // black on light paper even in dark mode, and turns white on dark paper.
        canvas.overrideUserInterfaceStyle = paper.interfaceStyle

        if let drawing = try? PKDrawing(data: page.drawingData) {
            canvas.drawing = drawing
        }
        context.coordinator.lastAppliedDrawingData = page.drawingData
        canvas.tool = tool

        context.coordinator.canvas = canvas
        if isActive { proxy.canvas = canvas }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.tool = tool
        canvas.drawingPolicy = drawingPolicy
        canvas.overrideUserInterfaceStyle = paper.interfaceStyle
        context.coordinator.onSqueeze = onSqueeze
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.onFingerDoubleTap = onFingerDoubleTap
        context.coordinator.applyRemoteDrawingIfNeeded(from: page.drawingData)
        if isActive { proxy.canvas = canvas }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate,
                             UIGestureRecognizerDelegate {
        let page: JournalPage
        let proxy: CanvasProxy
        var onSqueeze: () -> Void
        var onDoubleTap: () -> Void
        var onFingerDoubleTap: ((CGPoint) -> Void)?
        weak var canvas: PKCanvasView?
        var lastAppliedDrawingData = Data()
        private var saveTask: Task<Void, Never>?
        private var isApplyingRemoteDrawing = false

        init(page: JournalPage,
             proxy: CanvasProxy,
             onSqueeze: @escaping () -> Void,
             onDoubleTap: @escaping () -> Void) {
            self.page = page
            self.proxy = proxy
            self.onSqueeze = onSqueeze
            self.onDoubleTap = onDoubleTap
        }

        func applyRemoteDrawingIfNeeded(from data: Data) {
            guard data != lastAppliedDrawingData,
                  saveTask == nil,
                  let canvas,
                  let drawing = try? PKDrawing(data: data) else { return }
            isApplyingRemoteDrawing = true
            canvas.drawing = drawing
            isApplyingRemoteDrawing = false
            lastAppliedDrawingData = data
        }

        @objc func handleFingerDoubleTap(_ tap: UITapGestureRecognizer) {
            guard tap.state == .ended, let view = tap.view else { return }
            let point = tap.location(in: view)
            onFingerDoubleTap?(point)
        }

        /// The page's scrolling and other taps carry on as usual.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
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

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingRemoteDrawing else { return }
            let size = canvasView.bounds.size
            // Persist on demand by reading the *live* canvas — serializing only
            // when it actually runs (debounce or flush), not on every change.
            proxy.flushPendingSave = { [weak self, weak canvasView, page] in
                guard let canvasView, page.modelContext != nil else { return }
                let data = canvasView.drawing.dataRepresentation()
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
