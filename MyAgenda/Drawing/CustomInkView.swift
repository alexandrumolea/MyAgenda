//
//  CustomInkView.swift
//  MyAgenda
//
//  A custom fountain/ball-pen engine that emulates the GoodNotes feel: stroke
//  width varies with speed (thin when fast, thick when slow) and Apple Pencil
//  pressure, with smoothing. It renders a live preview while drawing and, on
//  lift, commits a real PKStroke to the canvas so eraser/lasso/undo still work.
//
//  Only Apple Pencil touches are captured, by a recognizer on the page's
//  scroll view (the same home as PencilKit's); the view itself takes no
//  touches, so the finger reaches the boxes and scrolling keeps working.
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

// MARK: - SwiftUI wrapper

struct InkOverlay: UIViewRepresentable {
    var isActive: Bool
    var color: UIColor
    /// How `color` shows on the paper (inverted on dark paper), for the live
    /// line; the committed stroke keeps `color`.
    var previewColor: UIColor? = nil
    var baseWidth: CGFloat
    var ballpoint: BallpointTuning?
    var proxy: CanvasProxy
    /// A stroke starts: the page ends any box edit, as for PencilKit's tools.
    var onInkBegan: () -> Void = {}

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
        view.ballpoint = ballpoint
        view.proxy = proxy
        view.onInkBegan = onInkBegan
    }
}

// MARK: - Pencil recognizer

/// Hands the Pencil's touches to the engine. It lives on the page's scroll
/// view, so it sees the Pencil wherever it lands (a box above the canvas
/// included) and the finger never reaches it.
final class PencilInkGestureRecognizer: UIGestureRecognizer {
    weak var engine: CustomInkView?

    init(engine: CustomInkView) {
        self.engine = engine
        super.init(target: nil, action: nil)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        requiresExclusiveTouchType = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        engine?.strokeBegan(touch, event: event)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        engine?.strokeMoved(touch, event: event)
        state = .changed
    }

    // The state always moves on, or the recognizer would stay in `.changed`
    // and keep the Pencil from scrolling the page afterwards.
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { engine?.strokeEnded(touch, event: event) }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { engine?.strokeCancelled(touch, event: event) }
        state = .cancelled
    }
}

// MARK: - Engine

final class CustomInkView: UIView {
    var isActive = false {
        didSet {
            recognizer.isEnabled = isActive
            // SwiftUI sets this on every update, for every page: only a page
            // that just stopped drawing has anything to clear.
            if oldValue, !isActive { clearPreview() }
        }
    }
    var strokeColor: UIColor = .black
    var previewColor: UIColor?
    var baseWidth: CGFloat = 4
    /// Set for the ball-pen styles: near-constant width, short round ends, raw
    /// points and a live preview that matches the committed stroke. Nil for
    /// the other inks, which keep the expressive fountain-pen profile
    /// (speed/pressure width, long taper).
    var ballpoint: BallpointTuning?
    weak var proxy: CanvasProxy?
    var onInkBegan: () -> Void = {}

    /// Ink the committed stroke carries. The probe of 6 Nov 2026 (simulator,
    /// `PKDrawing.image(from:)`) found `.monoline` and `.pen` render the same
    /// width for the same point size, force 0.2 or 1 alike, so the plainer
    /// ink wins.
    static let commitInkType: PKInkingTool.InkType = .monoline

    /// Point size that renders `width` points wide. The same probe measured
    /// rendered width = 2 × size − 4 for sizes 3…16 (size 4 → 4, 12 → 20,
    /// 2 → nothing), the same at 1×, 2× and 3×: handed the width as the size,
    /// the thin gel strokes vanished and the thick ones doubled.
    static func commitSize(for width: CGFloat) -> CGFloat { (width + 4) / 2 }

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
    private lazy var recognizer = PencilInkGestureRecognizer(engine: self)
    /// The last finished stroke, until PencilKit shows its copy of it.
    private let lingerView = LingerView()
    /// Bumped whenever the lingering stroke is replaced or cleared, so a
    /// pending clear from an earlier stroke never wipes a newer one.
    private var lingerGeneration = 0
    /// PencilKit shows a committed stroke 20 to 75 ms later; if it never says
    /// it has, the lingering copy goes after this anyway.
    private static let lingerLimit: Duration = .milliseconds(300)

    private var drawer: PreviewDrawer { PreviewDrawer(baseWidth: baseWidth, ballpoint: ballpoint) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = false
        contentMode = .redraw
        // Never hit: the Pencil arrives through the recognizer, everything
        // else goes to the boxes and the canvas underneath.
        isUserInteractionEnabled = false
        lingerView.frame = bounds
        addSubview(lingerView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Recognizer home

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, let page = pageScrollView else { return }
        recognizer.isEnabled = isActive
        if recognizer.view !== page {
            page.addGestureRecognizer(recognizer)
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        recognizer.view?.removeGestureRecognizer(recognizer)
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

    // MARK: Touches

    func strokeBegan(_ touch: UITouch, event: UIEvent?) {
        guard isActive, touch.type == .pencil else { return }
        onInkBegan()
        // The previous stroke keeps lingering on its own: between two letters
        // PencilKit has often not drawn it yet.
        samples.removeAll()
        smoothedWidth = 0
        appendSamples(for: touch, event: event, isFirst: true)
        invalidateSamples(from: 0)
    }

    func strokeMoved(_ touch: UITouch, event: UIEvent?) {
        guard isActive, touch.type == .pencil else { return }
        let oldCount = samples.count
        appendSamples(for: touch, event: event, isFirst: false)
        invalidateSamples(from: oldCount)
    }

    func strokeEnded(_ touch: UITouch, event: UIEvent?) {
        guard isActive, touch.type == .pencil else { return }
        appendSamples(for: touch, event: event, isFirst: false)
        commitStroke()
        startLingering()
    }

    func strokeCancelled(_ touch: UITouch, event: UIEvent?) {
        clearPreview()
    }

    /// PencilKit draws the committed stroke 20 to 75 ms after it gets it;
    /// clearing the preview at once left the line gone for those frames, a
    /// blink on every lift. The finished stroke moves to the linger view, in
    /// the same frame, and leaves the moment PencilKit says it has drawn its
    /// own. Never both at once: measured on the iPad, the two copies on top
    /// of each other read up to half a point bolder, which was the "settle"
    /// after every lift. Only the latest stroke lingers: an older one is
    /// long drawn.
    private func startLingering() {
        guard let lastArc = samples.last?.arc else { return }
        // The ball pen's flick past the lift point is part of the committed
        // stroke: shown here too, from the lift on, it doesn't grow out of
        // the line a moment later when PencilKit draws it.
        let tail = ballpoint.map { ballpointTail(after: samples, tuning: $0) } ?? []
        let total = tail.last?.arc ?? lastArc
        // The run-out thins the end only now that the stroke has a length;
        // the linger view draws it that way from its first frame.
        lingerView.show(samples + tail, total: isBallpoint ? total : nil,
                        drawer: drawer, color: previewColor ?? strokeColor)
        let rect = drawer.bounds(of: samples)
        samples.removeAll()
        setNeedsDisplay(rect)
        lingerGeneration += 1
        let generation = lingerGeneration
        // Set after the commit, so only a render that includes the new
        // stroke can call it.
        let start = CFAbsoluteTimeGetCurrent()
        proxy?.onFinishRendering = { [weak self] in
            self?.endLingering(generation, rendered: true, since: start)
        }
        proxy?.finishRenderingOwner = self
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.lingerLimit)
            self?.endLingering(generation, rendered: false, since: start)
        }
    }

    private func endLingering(_ generation: Int, rendered: Bool, since start: CFAbsoluteTime) {
        guard generation == lingerGeneration else { return }
        #if DEBUG
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        InkWidthProbe.note("Predare: \(rendered ? "PencilKit a anunțat" : "limită, fără semnal") după \(elapsed) ms")
        #endif
        clearLingering()
        // PencilKit's copy is already on screen: the clear goes out now, not
        // when the main thread next gets round to it.
        CATransaction.flush()
    }

    private func clearLingering() {
        lingerGeneration += 1
        if let proxy, proxy.finishRenderingOwner === self {
            proxy.onFinishRendering = nil
            proxy.finishRenderingOwner = nil
        }
        lingerView.clear()
    }

    /// Drops the live and the lingering preview, redrawing only where they were.
    private func clearPreview() {
        clearLingering()
        guard !samples.isEmpty else { return }
        let rect = drawer.bounds(of: samples)
        samples.removeAll()
        setNeedsDisplay(rect)
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
        drawer.draw(samples, total: nil, color: previewColor ?? strokeColor, in: rect, ctx: ctx)
    }

    /// One way to draw a sample sequence, shared by the live view and the
    /// linger view so the stroke does not change when it moves between them.
    private struct PreviewDrawer {
        var baseWidth: CGFloat
        var ballpoint: BallpointTuning?

        private var isBallpoint: Bool { ballpoint != nil }

        func draw(_ sequence: [Sample], total: CGFloat?, color: UIColor, in rect: CGRect, ctx: CGContext) {
            guard !sequence.isEmpty else { return }
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            color.setStroke()
            color.setFill()

            if sequence.count == 1 {
                let s = sequence[0]
                ctx.fillEllipse(in: CGRect(x: s.location.x - s.width / 2,
                                           y: s.location.y - s.width / 2,
                                           width: s.width, height: s.width))
                return
            }

            // One piece per sample: a quadratic curve from the midpoint before the
            // sample to the midpoint after it, with the sample as control point.
            // The pieces chain into a smooth curve that passes through the raw
            // points' neighbourhood — the same shape PencilKit draws on commit.
            let count = sequence.count
            for i in 0..<count {
                guard pieceRect(sequence, at: i).intersects(rect) else { continue }
                let p = sequence[i].location
                let start = i == 0 ? p : midpoint(sequence[i - 1].location, p)
                let end = i == count - 1 ? p : midpoint(p, sequence[i + 1].location)
                ctx.setLineWidth(previewWidth(sequence, at: i, total: total))
                ctx.move(to: start)
                ctx.addQuadCurve(to: end, control: p)
                ctx.strokePath()
            }
        }

        /// Width the preview draws sample `i` with. For the ball pen this is
        /// exactly what the committed stroke gets: the short start taper while
        /// drawing and, once the stroke has ended and `total` is known, the
        /// run-out too, so nothing visibly changes when the pencil lifts.
        private func previewWidth(_ sequence: [Sample], at i: Int, total: CGFloat?) -> CGFloat {
            guard isBallpoint else { return sequence[i].width }
            let taper = total.map { ballpointTaper(arc: sequence[i].arc, total: $0) }
                        ?? ballpointStartTaper(arc: sequence[i].arc)
            return max(sequence[i].width * taper, 0.6)
        }

        private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }

        /// The curve PencilKit draws from the committed points: a uniform
        /// cubic B-spline with each end repeated, as `commitStroke` builds it.
        /// Each span is drawn as its exact Bézier, with the span's mean width.
        func drawSpline(_ sequence: [Sample], total: CGFloat?, color: UIColor, ctx: CGContext) {
            guard let first = sequence.first, let last = sequence.last else { return }
            let points = [first.location, first.location] + sequence.map { $0.location }
                       + [last.location, last.location]
            let inner = sequence.indices.map { previewWidth(sequence, at: $0, total: total) }
            let widths = [inner[0], inner[0]] + inner + [inner[inner.count - 1], inner[inner.count - 1]]
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            color.setStroke()
            func mix(_ terms: [(CGPoint, CGFloat)]) -> CGPoint {
                CGPoint(x: terms.reduce(0) { $0 + $1.0.x * $1.1 }, y: terms.reduce(0) { $0 + $1.0.y * $1.1 })
            }
            for i in 1..<(points.count - 2) {
                let a = points[i - 1], b = points[i], c = points[i + 1], d = points[i + 2]
                ctx.setLineWidth((widths[i - 1] + 11 * widths[i] + 11 * widths[i + 1] + widths[i + 2]) / 24)
                ctx.move(to: mix([(a, 1.0 / 6), (b, 4.0 / 6), (c, 1.0 / 6)]))
                ctx.addCurve(to: mix([(b, 1.0 / 6), (c, 4.0 / 6), (d, 1.0 / 6)]),
                             control1: mix([(b, 2.0 / 3), (c, 1.0 / 3)]),
                             control2: mix([(b, 1.0 / 3), (c, 2.0 / 3)]))
                ctx.strokePath()
            }
        }

        /// Bounds of preview piece `i` of `sequence`: the quadratic curve lies
        /// inside the hull of its control polygon (previous point, this point,
        /// next point), padded by the line width.
        func pieceRect(_ sequence: [Sample], at i: Int) -> CGRect {
            let lo = max(0, i - 1), hi = min(sequence.count - 1, i + 1)
            var rect = CGRect(origin: sequence[i].location, size: .zero)
            for j in lo...hi {
                rect = rect.union(CGRect(origin: sequence[j].location, size: .zero))
            }
            let inset = max(sequence[i].width, baseWidth) * 2
            return rect.insetBy(dx: -inset, dy: -inset)
        }

        /// Everything a sequence's preview touches.
        func bounds(of sequence: [Sample]) -> CGRect {
            var rect = CGRect.null
            for index in sequence.indices {
                rect = rect.union(pieceRect(sequence, at: index))
            }
            return rect
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

        func ballpointTaper(arc: CGFloat, total: CGFloat) -> CGFloat {
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
    }

    /// Holds the last finished stroke above the live preview until PencilKit
    /// shows its own copy, so no frame goes without the line.
    private final class LingerView: UIView {
        private var samples: [Sample] = []
        private var total: CGFloat?
        private var drawer = PreviewDrawer(baseWidth: 4, ballpoint: nil)
        private var color: UIColor = .black

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            contentMode = .redraw
            isUserInteractionEnabled = false
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Takes over `sequence`, drawn exactly as the live view drew it; any
        /// stroke still lingering is dropped.
        func show(_ sequence: [Sample], total: CGFloat?, drawer: PreviewDrawer, color: UIColor) {
            var dirty = samples.isEmpty ? CGRect.null : self.drawer.bounds(of: samples)
            samples = sequence
            self.total = total
            self.drawer = drawer
            self.color = color
            alpha = 1
            dirty = dirty.union(drawer.bounds(of: sequence))
            if !dirty.isNull { setNeedsDisplay(dirty) }
        }

        func clear() {
            alpha = 0
            guard !samples.isEmpty else { return }
            let rect = drawer.bounds(of: samples)
            samples.removeAll()
            total = nil
            setNeedsDisplay(rect)
        }

        override func draw(_ rect: CGRect) {
            guard !samples.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }
            drawer.draw(samples, total: total, color: color, in: rect, ctx: ctx)
        }
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
        // The width is already in the size: full force and opacity on every
        // point, so PencilKit has nothing of its own to thin or fade with.
        var points: [PKStrokePoint] = (0..<count).map { index in
            let s = all[index]
            let taper = isBallpoint ? drawer.ballpointTaper(arc: s.arc, total: all[count - 1].arc)
                                    : taperMultiplier(index: index, count: count)
            let size = Self.commitSize(for: max(widths[index] * taper, 0.6))
            return PKStrokePoint(location: locations[index],
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

        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let ink = PKInk(Self.commitInkType, color: strokeColor)
        let stroke = PKStroke(ink: ink, path: path)
        #if DEBUG
        if let canvas = proxy.canvas {
            let drawer = self.drawer, color = previewColor ?? strokeColor
            let drawn = all, total = all[count - 1].arc
            InkWidthProbe.measure(on: canvas, rect: drawer.bounds(of: drawn), length: total,
                                  width: baseWidth) { ctx in
                drawer.draw(drawn, total: total, color: color, in: .infinite, ctx: ctx)
            } drawSpline: { ctx in
                drawer.drawSpline(drawn, total: total, color: color, ctx: ctx)
            }
        }
        #endif
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
            dirty = dirty.union(drawer.pieceRect(samples, at: index))
        }
        if !dirty.isNull {
            setNeedsDisplay(dirty)
        }
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
