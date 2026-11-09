//
//  InkRenderer.swift
//  MyAgenda
//
//  Draws our own ink with CoreGraphics: round-capped segments along the
//  polyline `InkGeometry` makes of a stroke. Both the live line and the
//  committed bitmap go through `draw(_:inkType:color:in:)`, so the pixels
//  are the same before and after the pencil lifts. Legacy strokes are not
//  drawn here: PencilKit renders them into an underlay image.
//

import PencilKit

nonisolated enum InkRenderer {
    /// Marker strokes read through each other and the writing underneath.
    private static let markerAlpha: CGFloat = 0.35
    /// Consecutive points closer in width than this share one stroked path:
    /// with round joins the union is the same geometry, far fewer paths.
    private static let widthTolerance: CGFloat = 0.05

    /// Strokes `polyline` in `color`, only the segments that can touch `rect`
    /// (the dirty rect, document coordinates) when given. Round caps and
    /// joins, so a run of segments is the union of round-capped segments
    /// whatever the batching, and leaving out the segments that miss `rect`
    /// changes no pixel inside it; a zero-length segment with a round cap is
    /// a dot, so a single point draws too.
    static func draw(_ polyline: [InkPoint], inkType: PKInkingTool.InkType,
                     color: UIColor, rect: CGRect? = nil, in ctx: CGContext) {
        guard !polyline.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color.cgColor)

        if inkType == .marker {
            // One path, filled once: the translucent ink must not darken
            // where its own segments overlap. Plain alpha, no blend mode: the
            // live view is composited normally over the committed bitmap, and
            // only normal compositing gives the same pixels whether the marker
            // is drawn into the bitmap or over it, so nothing changes at lift.
            ctx.setAlpha(markerAlpha)
            ctx.setLineWidth(polyline[0].width)
            if addLines(polyline, from: 0, to: polyline.count, touching: rect, in: ctx) {
                ctx.strokePath()
            }
            return
        }

        var start = 0
        while start < polyline.count {
            let width = polyline[start].width
            var end = start + 1
            while end < polyline.count, abs(polyline[end].width - width) < widthTolerance {
                end += 1
            }
            ctx.setLineWidth(width)
            // Each batch begins at the previous point, so the segment into it
            // is drawn with the width of its end.
            if addLines(polyline, from: max(start - 1, 0), to: end, touching: rect, in: ctx) {
                ctx.strokePath()
            }
            start = end
        }
    }

    /// Adds the segments of `polyline[start..<end]` whose padded box meets
    /// `rect` (all of them when nil); a skipped segment ends the subpath and
    /// the next kept one starts a new one. False when nothing was added.
    private static func addLines(_ polyline: [InkPoint], from start: Int, to end: Int,
                                 touching rect: CGRect?, in ctx: CGContext) -> Bool {
        if end - start == 1 {
            let point = polyline[start]
            if let rect, !box(around: point).intersects(rect) { return false }
            ctx.move(to: point.location)
            ctx.addLine(to: point.location)
            return true
        }
        var added = false
        var subpathOpen = false
        for index in (start + 1)..<end {
            let from = polyline[index - 1], to = polyline[index]
            if let rect, !box(around: from).union(box(around: to)).intersects(rect) {
                subpathOpen = false
                continue
            }
            if !subpathOpen {
                ctx.move(to: from.location)
                subpathOpen = true
            }
            ctx.addLine(to: to.location)
            added = true
        }
        return added
    }

    /// What a point's round cap can touch, with a point of slack for
    /// antialiasing (the same box `InkGeometry.bounds` unions).
    private static func box(around point: InkPoint) -> CGRect {
        let pad = point.width / 2 + 1
        return CGRect(x: point.location.x - pad, y: point.location.y - pad, width: pad * 2, height: pad * 2)
    }

    /// How a stroke's stored color (the one for white paper) shows on
    /// `paper`: inverted on dark paper, as PencilKit would. The live and the
    /// committed line take their color from here alike.
    static func shownColor(_ stored: UIColor, on paper: PaperColor) -> UIColor {
        paper.shown(stored.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
    }

    /// Draws one stored stroke as it shows on `paper`, within `rect` when
    /// given, from the polyline the entry keeps (evaluated here when it keeps
    /// none). A piece the eraser left is the whole polyline clipped to its
    /// mask: the clip squares the cut ends, and the marker stays one stroked
    /// path, so no seam shows.
    static func draw(_ entry: InkEntry, paper: PaperColor, rect: CGRect? = nil, in ctx: CGContext) {
        let stroke = entry.stroke
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let mask = stroke.mask, !mask.isEmpty {
            var transform = stroke.transform
            if let clip = mask.cgPath.copy(using: &transform) {
                ctx.addPath(clip)
                ctx.clip(using: mask.usesEvenOddFillRule ? .evenOdd : .winding)
            }
        }
        draw(entry.polyline ?? InkGeometry.polyline(of: stroke), inkType: stroke.ink.inkType,
             color: shownColor(stroke.ink.color, on: paper), rect: rect, in: ctx)
    }

    /// Draws, in document order, the strokes whose bounds (our own, cached by
    /// the document) touch `rect`, and of each only the segments that do; a
    /// stroke wholly inside `rect` skips the per-segment test. Returns how
    /// many strokes were drawn. The entries at `skipping` are left out (a
    /// lasso selection, drawn above the page while it is dragged).
    @discardableResult
    static func draw(_ strokes: [InkEntry], paper: PaperColor, rect: CGRect, skipping: IndexSet = [],
                     in ctx: CGContext) -> Int {
        var drawn = 0
        for (index, entry) in strokes.enumerated()
        where entry.bounds.intersects(rect) && !skipping.contains(index) {
            draw(entry, paper: paper, rect: rect.contains(entry.bounds) ? nil : rect, in: ctx)
            drawn += 1
        }
        return drawn
    }

    /// PencilKit's rendering of a drawing (the legacy strokes), in the paper's
    /// appearance rather than the system's, so black ink stays black on light
    /// paper and turns white on dark paper, as on the page. `bounds` may be
    /// a part of the page: the image covers exactly that rect. Strokes are
    /// Sendable, so the drawing is built off the main thread too.
    static func underlayImage(strokes: [PKStroke], bounds: CGRect, paper: PaperColor, scale: CGFloat) -> UIImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let drawing = PKDrawing(strokes: strokes)
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: paper.interfaceStyle).performAsCurrent {
            image = drawing.image(from: bounds, scale: scale)
        }
        return image
    }

    /// The underlay with one rect rendered again: `base` (the whole page,
    /// `bounds`, as the layer shows it) with `rect` cleared and `patch`
    /// (that rect's new rendering; nil when no legacy ink is left there)
    /// drawn in its place. The pixel grid is the base's, so it comes back
    /// unchanged outside the cut. CoreGraphics places an image's first row
    /// at the top of a rect only in its own bottom-up coordinates (flipping
    /// the context would turn both images over), so the rects go to those.
    static func underlayImage(patching base: CGImage, with patch: UIImage?, in rect: CGRect,
                              bounds: CGRect) -> CGImage? {
        guard bounds.width > 0, bounds.height > 0,
              let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(base.width) / bounds.width, y: CGFloat(base.height) / bounds.height)
        let cut = CGRect(x: rect.minX - bounds.minX, y: bounds.maxY - rect.maxY,
                         width: rect.width, height: rect.height)
        ctx.draw(base, in: CGRect(origin: .zero, size: bounds.size))
        ctx.clear(cut)
        if let patch = patch?.cgImage {
            ctx.draw(patch, in: cut)
        }
        return ctx.makeImage()
    }
}
