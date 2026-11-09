//
//  InkRenderer.swift
//  MyAgenda
//
//  Draws our own ink with CoreGraphics: round-capped segments along the
//  polyline `InkGeometry` makes of a stroke. Both the live line and the
//  committed bitmap go through `draw(_:inkType:color:in:)`, so the pixels
//  are the same before and after the pencil lifts. Legacy strokes are left
//  to PencilKit, as an image under our ink (the page's underlay, and the
//  thumbnails through `drawPage`).
//

import PencilKit

nonisolated enum InkRenderer {
    /// Marker strokes read through each other and the writing underneath.
    private static let markerAlpha: CGFloat = 0.35
    /// Consecutive points closer in width than this share one stroked path:
    /// with round joins the union is the same geometry, far fewer paths.
    private static let widthTolerance: CGFloat = 0.05
    /// Polyline points per B-spline span. The marker's outline and the pen's
    /// halo are built from one point per span, counted from the stroke's
    /// start so a growing live stroke keeps them: filling an outline of
    /// every point is what costs, and a span is far shorter than the marker
    /// is wide.
    private static let spanStride = Int(1 / InkGeometry.step)
    /// The pen's soft edge: a translucent halo this much wider than the line
    /// under an opaque core this much narrower, so the antialiased edge ramps
    /// over about twice as many pixels (closer to PencilKit's), and the line
    /// reads slightly bolder, by about 0.25 pt.
    private static let edgeGrow: CGFloat = 0.6
    private static let edgeShrink: CGFloat = 0.25
    /// The halo's opacity: enough to read as part of the line, not as a rim.
    private static let edgeAlpha: CGFloat = 0.65
    /// A span whose points stray further than this (points) from its chord
    /// keeps them all in the halo: a fast tight curve would otherwise cut
    /// the chord through the halo's `(edgeGrow + edgeShrink) / 2` margin and
    /// bare the core.
    private static let edgeChordError: CGFloat = 0.2
    /// A turn sharper than this (radians) gets a round join on the halo's
    /// outer side; below it one point on the mean normal misses the round
    /// join by about 1 % of the halo's radius.
    private static let edgeArcTurn: CGFloat = 0.3

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
            // where its own segments overlap. Its outline is filled rather
            // than the path stroked: CoreGraphics strokes a long path in
            // batches and composites each on its own, so the join between two
            // batches was painted twice, a darker disk that came and went
            // with the redraws. Plain alpha, no blend mode: the live view is
            // composited normally over the committed bitmap, and only normal
            // compositing gives the same pixels whether the marker is drawn
            // into the bitmap or over it, so nothing changes at lift.
            ctx.setAlpha(markerAlpha)
            ctx.setFillColor(color.cgColor)
            ctx.setLineWidth(polyline[0].width)
            let outline = CGMutablePath()
            if addLines(polyline, from: 0, to: polyline.count, stride: spanStride, touching: rect, to: outline) {
                ctx.addPath(outline)
                ctx.replacePathWithStrokedPath()
                ctx.fillPath()
            }
            return
        }

        // Each batch's path is kept for the core, drawn over the halo.
        var batches: [(path: CGPath, width: CGFloat)] = []
        var start = 0
        while start < polyline.count {
            let width = polyline[start].width
            var end = start + 1
            while end < polyline.count, abs(polyline[end].width - width) < widthTolerance {
                end += 1
            }
            // Each batch begins at the previous point, so the segment into it
            // is drawn with the width of its end.
            let batch = CGMutablePath()
            if addLines(polyline, from: max(start - 1, 0), to: end, touching: rect, to: batch) {
                batches.append((batch, width))
            }
            start = end
        }
        guard !batches.isEmpty else { return }
        // The halo is one outline of the whole stroke, filled once: a
        // translucent fill per batch would darken where batches overlap, and
        // the union of their stroked outlines filled several times slower
        // than the line itself. It leaves `rect` to the clip, so every tile
        // and the live view fill the same shape and no seam shows.
        ctx.saveGState()
        ctx.setAlpha(edgeAlpha)
        ctx.setFillColor(color.cgColor)
        ctx.addPath(haloOutline(of: polyline))
        ctx.fillPath(using: .winding)
        ctx.restoreGState()
        for batch in batches {
            // Never under half the width: a hairline keeps its weight.
            ctx.setLineWidth(max(batch.width - edgeShrink, batch.width / 2))
            ctx.addPath(batch.path)
            ctx.strokePath()
        }
    }

    /// The halo: a ribbon `edgeGrow / 2` wider than the line on each side,
    /// along every `spanStride`-th point and the last (all the points of a
    /// span that bends away from its chord), round at both ends and on the
    /// outer side of sharp turns; a single point is a disk. One closed path,
    /// so the fill crosses two edges a scanline where the batches' stroked
    /// outlines overlapped many times over.
    private static func haloOutline(of polyline: [InkPoint]) -> CGPath {
        var points: [InkPoint] = []
        func keep(_ point: InkPoint) {
            // A repeated location has no direction to offset from.
            if let last = points.last, last.location == point.location {
                points[points.count - 1] = point
            } else {
                points.append(point)
            }
        }
        keep(polyline[0])
        var index = 0
        while index < polyline.count - 1 {
            let next = min(index + spanStride, polyline.count - 1)
            if spanBends(polyline, from: index, to: next) {
                for k in index + 1 ..< next { keep(polyline[k]) }
            }
            keep(polyline[next])
            // Back on the span grid, so the spans before a growing live
            // stroke's tail are decided once.
            index = next
        }
        func radius(_ k: Int) -> CGFloat { points[k].width / 2 + edgeGrow / 2 }
        func offset(_ k: Int, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: points[k].location.x + cos(angle) * radius(k),
                    y: points[k].location.y + sin(angle) * radius(k))
        }
        let path = CGMutablePath()
        guard points.count > 1 else {
            let r = radius(0), center = points[0].location
            path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            return path
        }
        let directions = (1..<points.count).map { k in
            atan2(points[k].location.y - points[k - 1].location.y, points[k].location.x - points[k - 1].location.x)
        }
        let last = points.count - 1

        enum Step { case point(CGPoint), arc(Int, from: CGFloat, to: CGFloat) }
        // One side, first point to last: `side` is +1 for the left, -1 for
        // the right. A point on the mean normal at each turn, or on the
        // outer side of a sharp one an arc between the two segments' normals.
        func steps(_ side: CGFloat) -> [Step] {
            var steps = [Step.point(offset(0, directions[0] + side * .pi / 2))]
            for k in stride(from: 1, to: last, by: 1) {
                var turn = directions[k] - directions[k - 1]
                if turn > .pi { turn -= 2 * .pi } else if turn < -.pi { turn += 2 * .pi }
                let normal = directions[k - 1] + side * .pi / 2
                if turn * side < 0, abs(turn) > edgeArcTurn {
                    steps.append(.arc(k, from: normal, to: normal + turn))
                } else {
                    steps.append(.point(offset(k, normal + turn / 2)))
                }
            }
            steps.append(.point(offset(last, directions[last - 1] + side * .pi / 2)))
            return steps
        }

        // Left side forward, round end, right side back, round start.
        for (n, step) in steps(1).enumerated() {
            switch step {
            case .point(let point):
                if n == 0 { path.move(to: point) } else { path.addLine(to: point) }
            case .arc(let k, let from, let to):
                path.addArc(center: points[k].location, radius: radius(k), startAngle: from, endAngle: to,
                            clockwise: to < from)
            }
        }
        path.addArc(center: points[last].location, radius: radius(last), startAngle: directions[last - 1] + .pi / 2,
                    endAngle: directions[last - 1] - .pi / 2, clockwise: true)
        for step in steps(-1).reversed() {
            switch step {
            case .point(let point):
                path.addLine(to: point)
            case .arc(let k, let from, let to):
                path.addArc(center: points[k].location, radius: radius(k), startAngle: to, endAngle: from,
                            clockwise: from < to)
            }
        }
        path.addArc(center: points[0].location, radius: radius(0), startAngle: directions[0] - .pi / 2,
                    endAngle: directions[0] - .pi * 1.5, clockwise: true)
        path.closeSubpath()
        return path
    }

    /// Whether a point inside `polyline[start...end]` strays more than
    /// `edgeChordError` from the chord between its ends.
    private static func spanBends(_ polyline: [InkPoint], from start: Int, to end: Int) -> Bool {
        let a = polyline[start].location, b = polyline[end].location
        let length = hypot(b.x - a.x, b.y - a.y)
        for point in polyline[start..<end].dropFirst() {
            let p = point.location
            // A span that comes back to where it started has no chord.
            let distance = length > 0
                ? abs((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) / length
                : hypot(p.x - a.x, p.y - a.y)
            if distance > edgeChordError { return true }
        }
        return false
    }

    /// Appends to `path` the segments of `polyline[start..<end]` whose padded
    /// box meets `rect` (all of them when nil); a skipped segment ends the
    /// subpath and the next kept one starts a new one. False when nothing
    /// was added. With a `stride`, only every `stride`-th point counted from
    /// `start` and the last one are joined: a growing stroke keeps the same
    /// points at its start as samples arrive, so the live line and the
    /// committed one match.
    private static func addLines(_ polyline: [InkPoint], from start: Int, to end: Int, stride: Int = 1,
                                 touching rect: CGRect?, to path: CGMutablePath) -> Bool {
        if end - start == 1 {
            let point = polyline[start]
            if let rect, !box(around: point).intersects(rect) { return false }
            path.move(to: point.location)
            path.addLine(to: point.location)
            return true
        }
        var added = false
        var subpathOpen = false
        var previous = start
        while previous < end - 1 {
            let index = min(previous + stride, end - 1)
            let from = polyline[previous], to = polyline[index]
            previous = index
            if let rect, !box(around: from).union(box(around: to)).intersects(rect) {
                subpathOpen = false
                continue
            }
            if !subpathOpen {
                path.move(to: from.location)
                subpathOpen = true
            }
            path.addLine(to: to.location)
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
    /// many strokes were drawn. Only the markers, or only the rest: the
    /// highlights have their own layer, under all the writing. The entries
    /// at `skipping` are left out (a lasso selection, drawn above the page
    /// while it is dragged).
    @discardableResult
    static func draw(_ strokes: [InkEntry], markers: Bool, paper: PaperColor, rect: CGRect,
                     skipping: IndexSet = [], in ctx: CGContext) -> Int {
        var drawn = 0
        for (index, entry) in strokes.enumerated()
        where entry.bounds.intersects(rect) && entry.isMarker == markers && !skipping.contains(index) {
            draw(entry, paper: paper, rect: rect.contains(entry.bounds) ? nil : rect, in: ctx)
            drawn += 1
        }
        return drawn
    }

    /// The page's ink within `rect` (document coordinates) in the page's
    /// layer order: the highlights, then the legacy strokes PencilKit
    /// renders, then our writing. For a thumbnail, so nothing is cached;
    /// the strokes outside `rect` are left out by the bounds tests in `draw`
    /// and by PencilKit's own clip. Draws a UIImage, so it must run inside a
    /// UIKit image renderer's block.
    static func drawPage(_ drawing: PKDrawing, paper: PaperColor, rect: CGRect, in ctx: CGContext) {
        var owned: [InkEntry] = []
        var legacy: [PKStroke] = []
        // `strokes` copies the whole list on every read.
        for stroke in drawing.strokes {
            if InkGeometry.ownership(of: stroke) == .owned {
                let points = InkGeometry.polyline(of: stroke)
                owned.append(InkEntry(stroke: stroke, bounds: InkGeometry.bounds(of: points, maskOf: stroke),
                                      kept: nil, polyline: points))
            } else {
                legacy.append(stroke)
            }
        }
        draw(owned, markers: true, paper: paper, rect: rect, in: ctx)
        if !legacy.isEmpty {
            underlayImage(strokes: legacy, bounds: rect, paper: paper, scale: 1)?.draw(in: rect)
        }
        draw(owned, markers: false, paper: paper, rect: rect, in: ctx)
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
