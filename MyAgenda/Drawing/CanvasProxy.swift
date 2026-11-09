//
//  CanvasProxy.swift
//  MyAgenda
//
//  Lightweight bridge to the active page's ink: undo/redo, clear, and
//  committing strokes (the pen engine's, or pasted ink) with undo.
//

import PencilKit
import Observation

@Observable
final class CanvasProxy {
    @ObservationIgnored weak var canvas: PKCanvasView?
    /// The active page's ink surface; its document takes every edit.
    @ObservationIgnored weak var surface: InkSurfaceView?
    var document: InkDocument? { surface?.document }

    /// Set by the active page's surface: writes the current drawing to the
    /// model immediately. Call this before navigating away / pruning so a
    /// just-drawn page is persisted rather than lost to the debounce window.
    @ObservationIgnored var flushPendingSave: (() -> Void)?

    /// Called when the active canvas has drawn everything visible, a
    /// committed stroke included: the pen engine hands its copy over then.
    @ObservationIgnored var onFinishRendering: (() -> Void)?
    /// The engine that set `onFinishRendering`: every page has one, and only
    /// the owner may take the callback back.
    @ObservationIgnored weak var finishRenderingOwner: AnyObject?

    func undo() { document?.undo() }
    func redo() { document?.redo() }

    /// Clear the entire current page.
    func clear() { document?.clear() }

    /// Append a custom-built stroke (variable width pen), with undo/redo
    /// support and triggering the normal drawing-did-change save.
    func commit(stroke: PKStroke) { document?.append(stroke) }

    /// Append pasted ink (e.g. a lasso copy from another page) as real strokes,
    /// in one undo step.
    func commit(drawing pasted: PKDrawing) { document?.append(contentsOf: pasted) }
}
