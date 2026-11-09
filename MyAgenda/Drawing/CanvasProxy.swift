//
//  CanvasProxy.swift
//  MyAgenda
//
//  Lightweight bridge to the active page's ink: undo/redo, clear, and
//  pasting ink with undo.
//

import PencilKit
import Observation

@Observable
final class CanvasProxy {
    /// The active page's ink surface; its document takes every edit.
    @ObservationIgnored weak var surface: InkSurfaceView?
    var document: InkDocument? { surface?.document }

    /// Set by the active page's surface: writes the current drawing to the
    /// model immediately. Call this before navigating away / pruning so a
    /// just-drawn page is persisted rather than lost to the debounce window.
    @ObservationIgnored var flushPendingSave: (() -> Void)?

    func undo() { document?.undo() }
    func redo() { document?.redo() }

    /// Clear the entire current page.
    func clear() { document?.clear() }

    /// Append pasted ink (e.g. a lasso copy from another page) as real strokes,
    /// in one undo step.
    func commit(drawing pasted: PKDrawing) { document?.append(contentsOf: pasted) }
}
