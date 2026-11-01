//
//  CanvasProxy.swift
//  MyAgenda
//
//  Lightweight bridge to the active PencilKit canvas: undo/redo, clear, and
//  committing custom-built strokes (from the custom pen engine) with undo.
//

import PencilKit
import Observation

@Observable
final class CanvasProxy {
    @ObservationIgnored weak var canvas: PKCanvasView?

    /// Set by the active page's canvas: writes the current drawing to the model
    /// immediately. Call this before navigating away / pruning so a just-drawn
    /// page is persisted rather than lost to the debounce window.
    @ObservationIgnored var flushPendingSave: (() -> Void)?

    func undo() { canvas?.undoManager?.undo() }
    func redo() { canvas?.undoManager?.redo() }

    /// Clear the entire current page.
    func clear() { canvas?.drawing = PKDrawing() }

    /// Append a custom-built stroke (variable width pen) to the canvas, with
    /// undo/redo support and triggering the normal drawing-did-change save.
    func commit(stroke: PKStroke) {
        guard let canvas else { return }
        var drawing = canvas.drawing
        drawing.strokes.append(stroke)
        apply(drawing, to: canvas)
    }

    /// Append pasted ink (e.g. a lasso copy from another page) as real strokes,
    /// in one undo step.
    func commit(drawing pasted: PKDrawing) {
        guard let canvas, !pasted.strokes.isEmpty else { return }
        var drawing = canvas.drawing
        drawing.append(pasted)
        apply(drawing, to: canvas)
    }

    private func apply(_ drawing: PKDrawing, to canvas: PKCanvasView) {
        let old = canvas.drawing
        canvas.drawing = drawing
        canvas.undoManager?.registerUndo(withTarget: self) { proxy in
            proxy.apply(old, to: canvas)
        }
    }
}
