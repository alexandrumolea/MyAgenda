//
//  CustomInkView.swift
//  MyAgenda
//
//  A custom fountain/ball-pen engine that emulates the GoodNotes feel: stroke
//  width varies with speed (thin when fast, thick when slow) and Apple Pencil
//  pressure, with smoothing. It renders a live preview while drawing and, on
//  lift, commits a real PKStroke to the canvas so eraser/lasso/undo still work.
//
//  Only Apple Pencil touches are captured; finger touches pass through (so
//  finger-to-add-text and scrolling keep working).
//

import SwiftUI
import PencilKit

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

    /// "Pix": long, soft run-out and an eager tail.
    static let current = BallpointTuning(
        leadInMin: 4, leadInWidths: 1.6, leadInStart: 0.6,
        runOutMin: 18, runOutWidths: 5, tipWidth: 0.15,
        tailMinSpeed: 40, tailGain: 0.022, tailMaxBase: 8, tailMaxWidths: 2.5, tailMaxCap: 26
    )

    /// "Pix 2": short, firm ends. No run-out: the line keeps its full width
    /// right to where the pencil lifts, so nothing changes on lift — a
    /// run-out applied only at commit read as the stroke shrinking back.
    static let classic = BallpointTuning(
        leadInMin: 2, leadInWidths: 0.8, leadInStart: 0.7,
        runOutMin: 8, runOutWidths: 2.5, tipWidth: 1,
        tailMinSpeed: 80, tailGain: 0.015, tailMaxBase: 4, tailMaxWidths: 1.5, tailMaxCap: 16
    )
}

// MARK: - SwiftUI wrapper

struct InkOverlay: UIViewRepresentable {
    var isActive: Bool
    var color: UIColor
    /// How `color` shows on the paper (inverted on dark paper), for the live
    /// line; the committed stroke keeps `color`.
    var previewColor: UIColor? = nil
    var baseWidth: CGFloat
    var inkType: PKInkingTool.InkType
    var ballpoint: BallpointTuning?
    var proxy: CanvasProxy

    func makeUIView(context: Context) -> CustomInkView {
        let view = CustomInkView()
        view.proxy = proxy
        return view
    }

    func updateUIView(_ view: CustomInkView, context: Context) {
        view.isActive = isActive
        view.strokeColor = color
        view.previewColor = previewColor
        view.baseWidth = baseWidth
        view.inkType = inkType
        view.ballpoint = ballpoint
        view.proxy = proxy
    }
}

// MARK: - Engine

final class CustomInkView: UIView {
    var isActive = false
    var strokeColor: UIColor = .black
    var previewColor: UIColor?
    var baseWidth: CGFloat = 4
    var inkType: PKInkingTool.InkType = .pen
    /// Set for the ball-pen styles: near-constant width, short round ends, raw
    /// points and a live preview that matches the committed stroke. Nil for
    /// the other inks, which keep the expressive fountain-pen profile
    /// (speed/pressure width, long taper).
    var ballpoint: BallpointTuning?
    weak var proxy: CanvasProxy?

    private var isBallpoint: Bool { ballpoint != nil }

    private struct Sample {
        var location: CGPoint
        var width: CGFloat
        var force: CGFloat
        var time: TimeInterval
        /// Distance travelled along the stroke up to this sample, in points.
        var arc: CGFloat = 0
    }

    private var samples: [Sample] = []
    private var smoothedWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Only intercept touches when the pen is active AND a Pencil is involved;
    // otherwise let the touch fall through to the canvas / text layer.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isActive else { return nil }
        if let touches = event?.allTouches, touches.contains(where: { $0.type == .pencil }) {
            return self
        }
        return nil
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isActive, let touch = touches.first, touch.type == .pencil else { return }
        samples.removeAll()
        smoothedWidth = 0
        appendSamples(for: touch, event: event, isFirst: true)
        invalidateSamples(from: 0)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isActive, let touch = touches.first, touch.type == .pencil else { return }
        let oldCount = samples.count
        appendSamples(for: touch, event: event, isFirst: false)
        invalidateSamples(from: oldCount)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isActive, let touch = touches.first, touch.type == .pencil else { return }
        appendSamples(for: touch, event: event, isFirst: false)
        commitStroke()
        samples.removeAll()
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        samples.removeAll()
        setNeedsDisplay()
    }

    private func appendSamples(for touch: UITouch, event: UIEvent?, isFirst: Bool) {
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        for t in coalesced {
            let loc = t.preciseLocation(in: self)
            let force = t.maximumPossibleForce > 0 ? t.force / t.maximumPossibleForce : 1
            // Keep more points for rounder, more faithful curves.
            if !isFirst, let last = samples.last,
               hypot(loc.x - last.location.x, loc.y - last.location.y) < 0.5 {
                continue
            }
            let width = computeWidth(location: loc, force: force, time: t.timestamp)
            var arc: CGFloat = 0
            if let last = samples.last {
                arc = last.arc + hypot(loc.x - last.location.x, loc.y - last.location.y)
            }
            samples.append(Sample(location: loc, width: width, force: force, time: t.timestamp, arc: arc))
        }
    }

    private func computeWidth(location: CGPoint, force: CGFloat, time: TimeInterval) -> CGFloat {
        var tSpeed: CGFloat = 0.47   // first sample: same default as before (≈0.85× for the fountain pen)
        if let last = samples.last {
            let dt = max(time - last.time, 1.0 / 240)
            let dist = hypot(location.x - last.location.x, location.y - last.location.y)
            let speed = dist / dt
            tSpeed = min(max((speed - 150) / (2200 - 150), 0), 1)
        }

        let target: CGFloat
        let minMul: CGFloat, maxMul: CGFloat
        if isBallpoint {
            // Ball pen: the ink line barely changes. A touch thinner when
            // fast, a touch bolder when pressed — about ±20% overall.
            let speedMul = 1.08 - tSpeed * (1.08 - 0.82)
            let forceMul = 0.9 + 0.2 * force
            target = baseWidth * speedMul * forceMul
            minMul = 0.7; maxMul = 1.3
        } else {
            // Fountain pen: thin when fast, thick when slow, strongly pressure-sensitive.
            let speedMul = 1.25 - tSpeed * (1.25 - 0.4)
            let forceMul = 0.7 + 0.6 * force
            target = baseWidth * speedMul * forceMul
            minMul = 0.25; maxMul = 2.0
        }
        // Stronger smoothing → more fluid width transitions.
        smoothedWidth = smoothedWidth <= 0 ? target : smoothedWidth * 0.8 + target * 0.2
        return min(max(smoothedWidth, baseWidth * minMul), baseWidth * maxMul)
    }

    // MARK: Live preview

    override func draw(_ rect: CGRect) {
        guard !samples.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let shown = previewColor ?? strokeColor
        shown.setStroke()
        shown.setFill()

        if samples.count == 1 {
            let s = samples[0]
            ctx.fillEllipse(in: CGRect(x: s.location.x - s.width / 2,
                                       y: s.location.y - s.width / 2,
                                       width: s.width, height: s.width))
            return
        }

        // One piece per sample: a quadratic curve from the midpoint before the
        // sample to the midpoint after it, with the sample as control point.
        // The pieces chain into a smooth curve that passes through the raw
        // points' neighbourhood — the same shape PencilKit draws on commit.
        let count = samples.count
        for i in 0..<count {
            guard pieceRect(at: i).intersects(rect) else { continue }
            let p = samples[i].location
            let start = i == 0 ? p : midpoint(samples[i - 1].location, p)
            let end = i == count - 1 ? p : midpoint(p, samples[i + 1].location)
            ctx.setLineWidth(previewWidth(at: i))
            ctx.move(to: start)
            ctx.addQuadCurve(to: end, control: p)
            ctx.strokePath()
        }
    }

    /// Width the live preview draws sample `i` with. For the ball pen this is
    /// exactly what the committed stroke gets (short start taper included), so
    /// nothing visibly changes when the pencil lifts.
    private func previewWidth(at i: Int) -> CGFloat {
        guard isBallpoint else { return samples[i].width }
        return max(samples[i].width * ballpointStartTaper(arc: samples[i].arc), 0.6)
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    // MARK: Commit

    private func commitStroke() {
        guard !samples.isEmpty, let proxy else { return }
        // The ball pen gets a short flick past the lift point when the hand
        // was still moving; the other inks stop where the pencil left.
        var all = samples
        if let ballpoint {
            all.append(contentsOf: ballpointTail(after: samples, tuning: ballpoint))
        }
        let base = all[0].time
        let count = all.count
        // Ball pen: raw points and raw widths, so the stroke is the hand's own
        // shape — PencilKit's spline rounds it, nothing "corrects" it.
        let locations = isBallpoint ? all.map { $0.location } : smoothedLocations(of: all)
        let widths = isBallpoint ? all.map { $0.width }
                                 : smoothed(all.map { $0.width }, kernel: Self.smoothingKernel)
        // Ball pen: one steady force for the whole stroke. The force collapses
        // in the last samples as the pencil lifts; handed to PencilKit as-is
        // it can thin the very end, which reads as the line pulling back.
        let steadyForce = isBallpoint ? Self.median(samples.map { $0.force }) : nil
        var points: [PKStrokePoint] = (0..<count).map { index in
            let s = all[index]
            let taper = isBallpoint ? ballpointTaper(arc: s.arc, total: all[count - 1].arc)
                                    : taperMultiplier(index: index, count: count)
            let width = max(widths[index] * taper, 0.6)
            return PKStrokePoint(location: locations[index],
                                 timeOffset: max(s.time - base, 0),
                                 size: CGSize(width: width, height: width),
                                 opacity: 1,
                                 force: steadyForce ?? s.force,
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

        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let ink = PKInk(inkType, color: strokeColor)
        let stroke = PKStroke(ink: ink, path: path)
        proxy.commit(stroke: stroke)
    }

    private func invalidateSamples(from startIndex: Int) {
        guard !samples.isEmpty else { return }
        if samples.count == 1 {
            let sample = samples[0]
            let inset = max(sample.width, baseWidth) * 2
            setNeedsDisplay(CGRect(origin: sample.location, size: .zero).insetBy(dx: -inset, dy: -inset))
            return
        }

        // A new sample also reshapes the piece before it (its end midpoint
        // moved), so redraw from one piece earlier.
        var dirty = CGRect.null
        for index in max(0, startIndex - 1)..<samples.count {
            dirty = dirty.union(pieceRect(at: index))
        }
        if !dirty.isNull {
            setNeedsDisplay(dirty)
        }
    }

    /// Bounds of preview piece `i`: the quadratic curve lies inside the hull of
    /// its control polygon (previous point, this point, next point), padded by
    /// the line width.
    private func pieceRect(at i: Int) -> CGRect {
        let lo = max(0, i - 1), hi = min(samples.count - 1, i + 1)
        var rect = CGRect(origin: samples[i].location, size: .zero)
        for j in lo...hi {
            rect = rect.union(CGRect(origin: samples[j].location, size: .zero))
        }
        let inset = max(samples[i].width, baseWidth) * 2
        return rect.insetBy(dx: -inset, dy: -inset)
    }

    /// Ball pen ends, measured along the stroke in points (not in samples, whose
    /// spacing depends on speed): a lead-in under one pen width and a run-out
    /// of a couple of pen widths that eases down to a thin tip, so the line
    /// settles instead of stopping dead.
    private var tuning: BallpointTuning { ballpoint ?? .current }
    private var ballpointLeadIn: CGFloat { max(tuning.leadInMin, baseWidth * tuning.leadInWidths) }
    private var ballpointRunOut: CGFloat { max(tuning.runOutMin, baseWidth * tuning.runOutWidths) }

    private func ballpointStartTaper(arc: CGFloat) -> CGFloat {
        let t = min(arc / ballpointLeadIn, 1)
        return tuning.leadInStart + (1 - tuning.leadInStart) * t
    }

    private func ballpointTaper(arc: CGFloat, total: CGFloat) -> CGFloat {
        // Very short strokes (dots, i-dots) stay full so they don't vanish.
        guard total > ballpointRunOut else { return ballpointStartTaper(arc: arc) }
        var mul = ballpointStartTaper(arc: arc)
        let fromEnd = total - arc
        if fromEnd < ballpointRunOut {
            let t = fromEnd / ballpointRunOut            // 0 at the tip … 1 at full width
            let eased = t * t * (3 - 2 * t)              // smoothstep: gentle in, gentle out
            mul *= tuning.tipWidth + (1 - tuning.tipWidth) * eased
        }
        return mul
    }

    /// Fountain-pen taper: thins the start slightly and trails the end off to a
    /// fine point over a longer distance so the stroke doesn't stop abruptly.
    private func taperMultiplier(index: Int, count: Int) -> CGFloat {
        guard count > 3 else { return 1 }
        var mul: CGFloat = 1

        // Start: thin → full over the first ~8%.
        let startLen = max(count / 12, 2)
        if index < startLen {
            let t = CGFloat(index) / CGFloat(startLen)
            mul *= 0.6 + 0.4 * t
        }

        // End: full → very thin trailing tip over the last ~62% for a long trail.
        let endLen = max((count * 31) / 50, 8)
        let fromEnd = count - 1 - index
        if fromEnd < endLen {
            let t = CGFloat(fromEnd) / CGFloat(endLen)   // 0 at the tip … 1 at full
            // ease-out so it stays thin near the tip → a longer, softer trail
            let eased = t * (2 - t)
            mul *= 0.06 + 0.94 * eased
        }

        return mul
    }

    /// Ballpoint tail: lifted while still moving, a real ball pen leaves a
    /// short, thinning flick in the direction of travel. Extends the stroke
    /// past the lift point along the exit velocity, scaled by how fast the pen
    /// was going — a pen that came to rest before lifting gets no tail.
    private func ballpointTail(after samples: [Sample], tuning: BallpointTuning) -> [Sample] {
        guard samples.count >= 4, let last = samples.last else { return [] }
        // Direction and speed over the last few samples, so one noisy point
        // can't decide where the flick goes.
        let window = min(5, samples.count - 1)
        let from = samples[samples.count - 1 - window]
        let dx = last.location.x - from.location.x
        let dy = last.location.y - from.location.y
        let dist = hypot(dx, dy)
        let dt = max(last.time - from.time, 1.0 / 240)
        let speed = dist / dt
        guard dist > 0.5, speed > tuning.tailMinSpeed else { return [] }

        let maxLength = min(tuning.tailMaxBase + baseWidth * tuning.tailMaxWidths, tuning.tailMaxCap)
        let length = min((speed - tuning.tailMinSpeed) * tuning.tailGain, maxLength)
        guard length >= 1 else { return [] }

        let ux = dx / dist, uy = dy / dist
        let steps = max(3, Int(length / 1.5))
        var tail: [Sample] = []
        tail.reserveCapacity(steps)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            // Ease-out: the pen decelerates as it leaves the paper.
            let d = length * (1 - (1 - t) * (1 - t))
            tail.append(Sample(
                location: CGPoint(x: last.location.x + ux * d, y: last.location.y + uy * d),
                width: last.width * (1 - 0.85 * t),
                force: last.force * (1 - t),
                time: last.time + TimeInterval(d / speed),
                arc: last.arc + d
            ))
        }
        return tail
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 1 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// 5-tap kernel used for position and width smoothing. The samples are
    /// dense (coalesced, 240 Hz), so spatially this spans only a couple of
    /// points: it takes the jitter out without rounding the handwriting away.
    private static let smoothingKernel: [CGFloat] = [0.1, 0.2, 0.4, 0.2, 0.1]

    private func smoothedLocations(of samples: [Sample]) -> [CGPoint] {
        let xs = smoothed(samples.map { $0.location.x }, kernel: Self.smoothingKernel)
        let ys = smoothed(samples.map { $0.location.y }, kernel: Self.smoothingKernel)
        return zip(xs, ys).map { CGPoint(x: $0, y: $1) }
    }

    /// Convolves `values` with `kernel`; the first/last `kernel.count / 2`
    /// values are left untouched so the ends of the stroke stay anchored.
    private func smoothed(_ values: [CGFloat], kernel: [CGFloat]) -> [CGFloat] {
        let radius = kernel.count / 2
        guard values.count > kernel.count else { return values }
        var out = values
        for i in radius..<(values.count - radius) {
            var acc: CGFloat = 0
            for j in 0..<kernel.count { acc += values[i + j - radius] * kernel[j] }
            out[i] = acc
        }
        return out
    }
}
