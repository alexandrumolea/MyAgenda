//
//  InkGeometry.swift
//  MyAgenda
//
//  The one geometry behind our own ink: a stroke becomes a polyline of
//  (location, width) points by PencilKit's own B-spline evaluation, so the
//  strokes already on disk keep their shape, and the width comes from the
//  size each point stores (`width(for:inkType:)`). The live stroke builds
//  the same PKStrokePath from the Pencil's samples, so what the renderer
//  draws while writing and what it draws after the commit is, by
//  construction, the same line.
//

import PencilKit

/// One point of a stroke's polyline, in document coordinates.
struct InkPoint: Sendable {
    var location: CGPoint
    var width: CGFloat
}

nonisolated enum InkGeometry {
    /// Who draws a stroke: `.owned` is rendered by `InkRenderer`, `.legacy`
    /// is left to PencilKit (the underlay image).
    enum Ownership { case owned, legacy }

    /// Only the strokes we write ourselves are ours, masked or not: a piece
    /// the eraser left is drawn by our renderer with the mask as a clip. The
    /// expressive inks (`.pencil`, `.fountainPen`, …) stay with PencilKit,
    /// which renders them exactly. The pen is stored as `.pen` (PencilKit
    /// writes `.monoline` to its data as `.pen`, so it would come back as
    /// one anyway) and told apart from a PencilKit pen stroke by its
    /// signature: force 1 and a flat, untilted Pencil on every point, which
    /// a hand never produces, and the start point tripled.
    static func ownership(of stroke: PKStroke) -> Ownership {
        switch stroke.ink.inkType {
        case .marker: return .owned
        case .pen, .monoline: return isOurs(stroke.path) ? .owned : .legacy
        default: return .legacy
        }
    }

    /// Checked on three points only: the stroke count is in the thousands
    /// and the eraser asks on every event.
    private static func isOurs(_ path: PKStrokePath) -> Bool {
        guard path.count >= 3 else { return false }
        let start = path[0].location
        guard path[1].location == start, path[2].location == start else { return false }
        for point in [path[0], path[path.count / 2], path[path.count - 1]] {
            guard point.force > 0.999, abs(point.altitude - .pi / 2) < 0.001, abs(point.azimuth) < 0.001 else {
                return false
            }
        }
        return true
    }

    /// The width a stroke point of `size` is drawn with, both measured on
    /// PencilKit's own rendering so the strokes already stored keep their
    /// look. Monoline is the exact inverse of the commit size
    /// `(width + 4) / 2` (rendered width = 2 × size − 4). The marker's chisel
    /// renders much narrower than its size (height ≈ 0.62 × size + 0.5); new
    /// highlighter strokes still store `size = width`, so the data and the
    /// thumbnails do not change.
    static func width(for size: CGFloat, inkType: PKInkingTool.InkType) -> CGFloat {
        inkType == .marker ? 0.62 * size + 0.5 : max(2 * size - 4, 0.6)
    }

    /// Parametric step between polyline points: a quarter of a B-spline span.
    static let step: CGFloat = 0.25

    /// The stroke as the renderer draws it: PencilKit's interpolation of the
    /// path, widths by the law above, locations through the stroke's
    /// transform (a lasso move).
    static func polyline(of stroke: PKStroke) -> [InkPoint] {
        polyline(of: stroke.path, inkType: stroke.ink.inkType, transform: stroke.transform)
    }

    /// The polyline of a path, for the live stroke: the whole path is
    /// re-evaluated on every touch (O(samples), well under a millisecond for
    /// handwriting).
    static func polyline(of path: PKStrokePath, inkType: PKInkingTool.InkType,
                         transform: CGAffineTransform = .identity) -> [InkPoint] {
        guard !path.isEmpty else { return [] }
        var points: [InkPoint] = []
        points.reserveCapacity(path.count * Int(1 / step) + 1)
        for point in path.interpolatedPoints(by: .parametricStep(step)) {
            points.append(InkPoint(location: point.location.applying(transform),
                                   width: width(for: point.size.width, inkType: inkType)))
        }
        return points
    }

    /// Everything the polyline's rendering touches, with a point of slack for
    /// antialiasing.
    static func bounds(of polyline: [InkPoint]) -> CGRect {
        var rect = CGRect.null
        for point in polyline {
            let pad = point.width / 2 + 1
            rect = rect.union(CGRect(x: point.location.x - pad, y: point.location.y - pad,
                                     width: pad * 2, height: pad * 2))
        }
        return rect
    }

    /// Our rendering's bounds for a stored stroke, from its polyline already
    /// evaluated (the stroke's own, or its parent's: the eraser's pieces
    /// share the path): cut down to the mask, with a point of slack, when
    /// the eraser left one.
    static func bounds(of points: [InkPoint], maskOf stroke: PKStroke) -> CGRect {
        var rect = bounds(of: points)
        if let mask = stroke.mask, !mask.isEmpty {
            rect = rect.intersection(mask.bounds.applying(stroke.transform).insetBy(dx: -1, dy: -1))
        }
        return rect
    }

    // MARK: Eraser

    // The eraser works as PencilKit's own: it never punches a hole in the
    // path, it splits the stroke into pieces, one PKStroke per surviving
    // parametric range, each the whole path under a hull mask that clips
    // the rendering to that range. The masks are local (pre-transform) and
    // the eraser's capsule is in document space, so the pads below are only
    // right while `transform` is a translation — true today, and the lasso
    // must keep it so.

    /// The parametric ranges of the path the mask keeps: the whole path when
    /// there is no mask, else the runs of polyline points inside it (at
    /// parameters `k × step`), their ends refined to 1/32 of a step, so a
    /// re-cut after a reload does not nibble at the existing cuts. `polyline`
    /// is the stroke's (`polyline(of:)`, document space) when the caller has
    /// it already.
    static func keptRanges(of stroke: PKStroke, polyline points: [InkPoint]? = nil) -> [ClosedRange<CGFloat>] {
        let path = stroke.path
        guard !path.isEmpty else { return [] }
        let last = CGFloat(path.count - 1)
        guard let mask = stroke.mask, !mask.isEmpty else { return [0...last] }
        let maskBounds = mask.bounds
        func inside(_ location: CGPoint) -> Bool {
            maskBounds.contains(location) && mask.contains(location)
        }
        func inside(at t: CGFloat) -> Bool { inside(path.interpolatedLocation(at: t)) }
        // The mask's edge between an outside and an inside parameter, from
        // the inside, so the range never leaves the mask.
        func edge(outside: CGFloat, inside t: CGFloat) -> CGFloat {
            var out = outside, within = t
            for _ in 0..<5 {
                let mid = (out + within) / 2
                if inside(at: mid) { within = mid } else { out = mid }
            }
            return within
        }

        // The polyline is in document space and the mask in the path's: the
        // points go back through the transform for the test.
        let points = points ?? polyline(of: stroke)
        let toMask = stroke.transform.inverted()
        func inside(point k: Int) -> Bool { inside(points[k].location.applying(toMask)) }
        var ranges: [ClosedRange<CGFloat>] = []
        var k = 0
        while k < points.count {
            guard inside(point: k) else { k += 1; continue }
            let r0 = k
            while k + 1 < points.count, inside(point: k + 1) { k += 1 }
            let r1 = k
            k += 1
            // The path's own ends map to 0 and `last` exactly, so a natural
            // end is one again after a reload.
            var lo = r0 == 0 ? 0 : CGFloat(r0) * step
            var hi = r1 == points.count - 1 ? last : CGFloat(r1) * step
            if r0 > 0 { lo = edge(outside: CGFloat(r0 - 1) * step, inside: lo) }
            if r1 < points.count - 1 { hi = edge(outside: CGFloat(r1 + 1) * step, inside: hi) }
            ranges.append(lo...hi)
        }
        return ranges
    }

    /// Cuts the eraser's pass from `a` to `b`, `radius` wide (document
    /// space), out of `stroke`: the polyline points whose centreline the
    /// disc covered, within the `kept` ranges, go, and each range left makes
    /// a piece of the same path under its hull. Nil when the pass misses the
    /// centreline (a graze erases nothing); `pieces` empty when nothing of
    /// the stroke remains. `erasedBounds` is where the removed ink was.
    /// `polyline` is the stroke's (`polyline(of:)`) when the caller has it.
    static func cut(_ stroke: PKStroke, polyline points: [InkPoint]? = nil, kept: [ClosedRange<CGFloat>],
                    segment a: CGPoint, _ b: CGPoint,
                    radius: CGFloat) -> (pieces: [PKStroke], ranges: [ClosedRange<CGFloat>], erasedBounds: CGRect)? {
        let points = points ?? polyline(of: stroke)
        guard !points.isEmpty else { return nil }
        let last = CGFloat(stroke.path.count - 1)
        let distances = points.map { distance(from: $0.location, toSegment: a, b) }
        func erased(_ k: Int) -> Bool {
            let t = k == points.count - 1 ? last : CGFloat(k) * step
            return distances[k] <= radius && kept.contains { $0.contains(t) }
        }
        // Where the disc's edge crossed the centreline, between the last
        // point outside and the first inside, by the distances; a neighbour
        // that was not erased for lying in an old gap only widens the
        // interval into that gap.
        func crossing(outside: Int, inside: Int) -> CGFloat {
            let dOut = distances[outside], dIn = distances[inside]
            let f = dOut > radius ? min((dOut - radius) / (dOut - dIn), 1) : 0
            return (CGFloat(outside) + (CGFloat(inside) - CGFloat(outside)) * f) * step
        }

        var removed: [ClosedRange<CGFloat>] = []
        var erasedBounds = CGRect.null
        var k = 0
        while k < points.count {
            guard erased(k) else { k += 1; continue }
            let r0 = k
            while k + 1 < points.count, erased(k + 1) { k += 1 }
            let r1 = k
            k += 1
            let lo = r0 > 0 ? crossing(outside: r0 - 1, inside: r0) : 0
            let hi = r1 < points.count - 1 ? crossing(outside: r1 + 1, inside: r1) : last
            removed.append(lo...hi)
            erasedBounds = erasedBounds.union(
                bounds(of: Array(points[max(r0 - 1, 0)...min(r1 + 1, points.count - 1)])))
        }
        guard !removed.isEmpty else { return nil }

        // `removed` is ascending and disjoint: two runs are parted by a point
        // neither reaches past.
        var ranges: [ClosedRange<CGFloat>] = []
        for range in kept {
            var lo = range.lowerBound
            for gap in removed where gap.upperBound > lo && gap.lowerBound < range.upperBound {
                if gap.lowerBound > lo { ranges.append(lo...gap.lowerBound) }
                lo = max(lo, gap.upperBound)
            }
            if lo < range.upperBound { ranges.append(lo...range.upperBound) }
        }
        ranges.removeAll { $0.upperBound - $0.lowerBound < 0.01 }

        let pieces = ranges.map { range in
            PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform,
                     mask: hull(of: stroke.path, inkType: stroke.ink.inkType,
                                from: range.lowerBound, to: range.upperBound),
                     randomSeed: stroke.randomSeed)
        }
        return (pieces, ranges, erasedBounds)
    }

    /// The mask of the piece of `path` between parameters `t0` and `t1`, in
    /// the path's own space: a polygon offset from the centreline by half
    /// the width and a point on each side, as PencilKit's eraser builds it.
    /// A natural end of the path is extended by the pad along its tangent,
    /// so the round cap stays inside; a cut end is flat.
    static func hull(of path: PKStrokePath, inkType: PKInkingTool.InkType,
                     from t0: CGFloat, to t1: CGFloat) -> UIBezierPath {
        var ts: [CGFloat] = [t0]
        var t = (floor(t0 / step) + 1) * step
        while t < t1 {
            ts.append(t)
            t += step
        }
        if t1 > t0 { ts.append(t1) }
        var centres = ts.map { path.interpolatedLocation(at: $0) }
        let pads = ts.map { width(for: path.interpolatedPoint(at: $0).size.width, inkType: inkType) / 2 + 1 }

        func unit(from: CGPoint, to: CGPoint) -> CGPoint? {
            let length = hypot(to.x - from.x, to.y - from.y)
            guard length > 0 else { return nil }
            return CGPoint(x: (to.x - from.x) / length, y: (to.y - from.y) / length)
        }
        // The direction the path leaves its first sample in and arrives at
        // its last, past any samples that coincide with them.
        let n = centres.count
        guard let firstDirection = (1..<n).lazy.compactMap({ unit(from: centres[0], to: centres[$0]) }).first,
              let lastDirection = (0..<(n - 1)).reversed().lazy
                .compactMap({ unit(from: centres[$0], to: centres[n - 1]) }).first else {
            // A single point, or none apart: a square around it.
            let c = centres[0], pad = pads[0]
            return UIBezierPath(rect: CGRect(x: c.x - pad, y: c.y - pad, width: pad * 2, height: pad * 2))
        }
        if t0 == 0 {
            centres[0] = CGPoint(x: centres[0].x - firstDirection.x * pads[0],
                                 y: centres[0].y - firstDirection.y * pads[0])
        }
        if t1 == CGFloat(path.count - 1) {
            centres[n - 1] = CGPoint(x: centres[n - 1].x + lastDirection.x * pads[n - 1],
                                     y: centres[n - 1].y + lastDirection.y * pads[n - 1])
        }

        // Each side vertex sits on the bisector of the turn at its sample,
        // mitered: `pad` along the averaged normal would come closer than
        // the pad to the centreline at a sharp bend and clip ink, so the
        // offset grows by the cosine of half the turn, at most twofold.
        // Coinciding samples go straight on, so they add no stray vertex.
        let segments = (0..<(n - 1)).map { unit(from: centres[$0], to: centres[$0 + 1]) }
        var incoming = firstDirection
        var left: [CGPoint] = [], right: [CGPoint] = []
        left.reserveCapacity(n)
        right.reserveCapacity(n)
        for i in 0..<n {
            let outgoing = i < n - 1 ? segments[i] ?? incoming : incoming
            var bisector = CGPoint(x: incoming.x + outgoing.x, y: incoming.y + outgoing.y)
            let length = hypot(bisector.x, bisector.y)
            // A full reversal has no bisector: cut it square across.
            bisector = length > 0.001 ? CGPoint(x: bisector.x / length, y: bisector.y / length) : incoming
            let cosHalfTurn = bisector.x * incoming.x + bisector.y * incoming.y
            let offset = pads[i] / max(cosHalfTurn, 0.5)
            let normal = CGPoint(x: -bisector.y * offset, y: bisector.x * offset)
            left.append(CGPoint(x: centres[i].x + normal.x, y: centres[i].y + normal.y))
            right.append(CGPoint(x: centres[i].x - normal.x, y: centres[i].y - normal.y))
            if i < n - 1, let segment = segments[i] { incoming = segment }
        }
        let hull = UIBezierPath()
        hull.usesEvenOddFillRule = false
        hull.move(to: left[0])
        for point in left.dropFirst() { hull.addLine(to: point) }
        for point in right.reversed() { hull.addLine(to: point) }
        hull.close()
        return hull
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        var t: CGFloat = 0
        if lengthSquared > 0 {
            t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        }
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

// MARK: - Ball-pen tuning

/// Shape of the ball-pen ends and lift-off tail. Lengths are in points, the
/// `…Widths` factors scale with the chosen pen width (the larger wins).
struct BallpointTuning: Equatable {
    var leadInMin: CGFloat
    var leadInWidths: CGFloat
    var leadInStart: CGFloat      // width factor at the very start

    var runOutMin: CGFloat
    var runOutWidths: CGFloat
    var tipWidth: CGFloat         // width factor at the very end

    var tailMinSpeed: CGFloat     // pt/s below which no tail is added
    var tailGain: CGFloat         // tail length per pt/s above the minimum
    var tailMaxBase: CGFloat
    var tailMaxWidths: CGFloat
    var tailMaxCap: CGFloat

    /// "Gel 2": long, soft run-out and an eager tail.
    static let current = BallpointTuning(
        leadInMin: 4, leadInWidths: 1.6, leadInStart: 0.6,
        runOutMin: 18, runOutWidths: 5, tipWidth: 0.15,
        tailMinSpeed: 40, tailGain: 0.022, tailMaxBase: 8, tailMaxWidths: 2.5, tailMaxCap: 26
    )

    /// "Gel": short, firm ends. No run-out: the line keeps its full width
    /// right to where the pencil lifts, so nothing changes on lift — a
    /// run-out applied only at commit read as the stroke shrinking back.
    static let classic = BallpointTuning(
        leadInMin: 2, leadInWidths: 0.8, leadInStart: 0.7,
        runOutMin: 8, runOutWidths: 2.5, tipWidth: 1,
        tailMinSpeed: 80, tailGain: 0.015, tailMaxBase: 4, tailMaxWidths: 1.5, tailMaxCap: 16
    )
}

// MARK: - Live stroke

/// The stroke under the Pencil: collects samples and builds, at any moment,
/// the PKStrokePath the commit will store. The live view draws the polyline
/// of `path()` and the commit stores the very same path: same samples, same
/// evaluator, same widths, so nothing visible changes at lift.
@MainActor
final class LiveStroke {
    enum Profile: Equatable {
        /// Gel pen: width breathes with speed and pressure (about ±30%),
        /// short lead-in.
        case gel(BallpointTuning)
        /// Uniform line at the base width.
        case uniform
        /// Uniform `.marker` stroke at the base width.
        case highlighter
    }

    let profile: Profile
    let baseWidth: CGFloat
    let color: UIColor

    private struct Sample {
        var location: CGPoint
        var width: CGFloat
        var force: CGFloat
        var time: TimeInterval
        /// Distance travelled along the stroke up to this sample, in points.
        var arc: CGFloat = 0
    }

    /// Samples closer than this to the last one are dropped.
    static let minSpacing: CGFloat = 0.5

    private var samples: [Sample] = []
    private var smoother = PathSmoother()
    private var smoothedWidth: CGFloat = 0
    /// Shared by every path built from this stroke, so the live and the
    /// committed path are the same path.
    private let creationDate = Date()

    init(profile: Profile, baseWidth: CGFloat, color: UIColor) {
        self.profile = profile
        self.baseWidth = baseWidth
        self.color = color
    }

    var isEmpty: Bool { samples.isEmpty }

    /// `.pen`, not `.monoline`: PencilKit's data keeps no monoline, it comes
    /// back as a pen stroke, so the pen is stored as one from the start and
    /// recognized by its signature (`InkGeometry.ownership`).
    var inkType: PKInkingTool.InkType {
        if case .highlighter = profile { return .marker }
        return .pen
    }

    private var tuning: BallpointTuning? {
        if case .gel(let tuning) = profile { return tuning }
        return nil
    }

    // MARK: Samples

    /// Adds the touch and its coalesced touches, in `view`'s coordinates.
    func append(_ touch: UITouch, event: UIEvent?, in view: UIView) {
        let isFirst = samples.isEmpty
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        for t in coalesced {
            let loc = t.preciseLocation(in: view)
            let force = t.maximumPossibleForce > 0 ? t.force / t.maximumPossibleForce : 1
            // Keep more points for rounder, more faithful curves.
            if !isFirst, let last = samples.last,
               hypot(loc.x - last.location.x, loc.y - last.location.y) < Self.minSpacing {
                continue
            }
            let width = computeWidth(location: loc, force: force, time: t.timestamp)
            var arc: CGFloat = 0
            if let last = samples.last {
                arc = last.arc + hypot(loc.x - last.location.x, loc.y - last.location.y)
            }
            samples.append(Sample(location: loc, width: width, force: force, time: t.timestamp, arc: arc))
            // The highlighter keeps its raw path (see `path()`).
            if inkType != .marker { smoother.append(loc, arc: arc) }
        }
        // No predicted touches: a prediction, however short, reshapes the
        // tip when the real sample replaces it, and the sub-frame lag is
        // accepted instead.
    }

    private func computeWidth(location: CGPoint, force: CGFloat, time: TimeInterval) -> CGFloat {
        guard tuning != nil else { return baseWidth }
        var tSpeed: CGFloat = 0.47   // first sample: same default as before
        if let last = samples.last {
            let dt = max(time - last.time, 1.0 / 240)
            let dist = hypot(location.x - last.location.x, location.y - last.location.y)
            let speed = dist / dt
            tSpeed = min(max((speed - 150) / (2200 - 150), 0), 1)
        }
        // Gel pen: the line stays steady but visibly breathes. Thinner when
        // fast, bolder when slow (the ink pools) and when pressed — about
        // ±40% overall, the same on the live line and the committed one.
        let speedMul = 1.18 - tSpeed * (1.18 - 0.70)
        let forceMul = 0.78 + 0.44 * force
        let target = baseWidth * speedMul * forceMul
        // Smoothing keeps the width fluid; a touch quicker than before, so
        // the response to pressure shows within a letter.
        smoothedWidth = smoothedWidth <= 0 ? target : smoothedWidth * 0.75 + target * 0.25
        return min(max(smoothedWidth, baseWidth * 0.55), baseWidth * 1.45)
    }

    // MARK: Path

    /// The path as PencilKit stores it, from the real samples alone: the
    /// stroke stops where the pencil left. Nil until the first sample.
    func path() -> PKStrokePath? {
        guard !samples.isEmpty else { return nil }
        let base = samples[0].time
        // Raw widths, and for the pen the tremor smoothed out of the points
        // (`PathSmoother`: the start, the tip and the corners stay raw); the
        // highlighter keeps its raw points. The width is already in the size:
        // full force and opacity on every point, so PencilKit has nothing of
        // its own to thin or fade with.
        let locations = inkType == .marker ? nil : smoother.smoothed()
        var points: [PKStrokePoint] = samples.enumerated().map { i, s in
            let taper = tuning == nil ? 1 : ballpointStartTaper(arc: s.arc)
            let width = max(s.width * taper, 0.6)
            let size = inkType == .marker ? width : (width + 4) / 2
            return PKStrokePoint(location: locations?[i] ?? s.location,
                                 timeOffset: max(s.time - base, 0),
                                 size: CGSize(width: size, height: size),
                                 opacity: 1,
                                 force: 1,
                                 azimuth: 0,
                                 altitude: .pi / 2)
        }
        // PKStrokePath is a uniform cubic B-spline: it only passes near its
        // first and last control points, so every stroke came out a little
        // shorter than drawn (more so for fast strokes, whose points are far
        // apart). Repeating each end point three times pins the curve to it.
        if let first = points.first, let last = points.last {
            points.insert(contentsOf: [first, first], at: 0)
            points.append(contentsOf: [last, last])
        }
        return PKStrokePath(controlPoints: points, creationDate: creationDate)
    }

    /// The stroke the document stores and the live view draws. Nil until the
    /// first sample.
    func stroke() -> PKStroke? {
        guard let path = path() else { return nil }
        return PKStroke(ink: PKInk(inkType, color: color), path: path)
    }

    // MARK: Ball pen lead-in

    /// Ball pen start, measured along the stroke in points (not in samples,
    /// whose spacing depends on speed): a lead-in under one pen width, so the
    /// line sets in instead of starting at full width.
    private func ballpointLeadIn(_ tuning: BallpointTuning) -> CGFloat {
        max(tuning.leadInMin, baseWidth * tuning.leadInWidths)
    }

    private func ballpointStartTaper(arc: CGFloat) -> CGFloat {
        guard let tuning else { return 1 }
        let t = min(arc / ballpointLeadIn(tuning), 1)
        return tuning.leadInStart + (1 - tuning.leadInStart) * t
    }
}
