//
//  PathSmoother.swift
//  MyAgenda
//
//  Smooths the pen's path as it is written. Slow writing at 240 Hz puts
//  the samples about half a point apart, and PencilKit's B-spline follows
//  them closely enough to show the hand's tremor. Each point becomes a
//  weighted mean of its neighbours within a few points of arc, a window
//  that never reaches past an anchor: the stroke's start, its tip and its
//  corners stay exactly where the pencil put them. The result depends on
//  the samples alone, and all but the last few points are final, so the
//  line settles behind the nib instead of shifting as it grows.
//

import CoreGraphics

nonisolated struct PathSmoother {
    /// The window's half-width along the stroke, in points. Fixed, not
    /// scaled with the pen: the tremor is the hand's, whatever the width.
    static let radius: CGFloat = 3
    /// How far along the stroke, each way, a turn is measured: far enough
    /// that the tremor between two samples doesn't read as a corner.
    static let cornerReach: CGFloat = 2
    /// A turn at least this sharp (radians) is a corner the hand meant, and
    /// is kept raw.
    static let cornerAngle: CGFloat = 50 * .pi / 180
    /// A point this far behind the tip is final: no later sample reaches
    /// its window or the corners that bound it.
    static let horizon = radius + cornerReach

    private var locations: [CGPoint] = []
    private var arcs: [CGFloat] = []
    /// Corner flags of `..<cornersSettled`. A point less than `cornerReach`
    /// behind the tip has no full reach ahead yet, so it is no corner; its
    /// flag is set, for good, once the tip has moved that far on.
    private var isCorner: [Bool] = []
    private var cornersSettled = 0
    private var output: [CGPoint] = []
    /// `output[..<settled]` is final.
    private(set) var settled = 0
    /// Samples `output` was last computed for.
    private var computed = 0

    mutating func append(_ p: CGPoint, arc: CGFloat) {
        locations.append(p)
        arcs.append(arc)
        output.append(p)
    }

    /// One smoothed location per sample, in order.
    mutating func smoothed() -> [CGPoint] {
        let n = locations.count
        guard n > computed else { return output }
        computed = n
        let end = arcs[n - 1]
        while cornersSettled < n, end - arcs[cornersSettled] >= Self.cornerReach {
            isCorner.append(corner(at: cornersSettled))
            cornersSettled += 1
        }
        for i in settled..<n {
            output[i] = smoothed(at: i)
        }
        while settled < n, end - arcs[settled] >= Self.horizon {
            settled += 1
        }
        return output
    }

    // MARK: Private

    private func isAnchor(_ j: Int) -> Bool {
        j == 0 || j == locations.count - 1 || (j < cornersSettled && isCorner[j])
    }

    /// The turn at `j`, between the chords to the nearest samples at least
    /// `cornerReach` behind and ahead along the stroke.
    private func corner(at j: Int) -> Bool {
        guard j > 0 else { return false }
        let a = arcs[j]
        var back = j - 1
        while back > 0, a - arcs[back] < Self.cornerReach { back -= 1 }
        guard a - arcs[back] >= Self.cornerReach else { return false }
        var fwd = j + 1
        while arcs[fwd] - a < Self.cornerReach { fwd += 1 }
        let p = locations[j], b = locations[back], f = locations[fwd]
        let v1 = CGVector(dx: p.x - b.x, dy: p.y - b.y)
        let v2 = CGVector(dx: f.x - p.x, dy: f.y - p.y)
        let turn = atan2(abs(v1.dx * v2.dy - v1.dy * v2.dx), v1.dx * v2.dx + v1.dy * v2.dy)
        return turn >= Self.cornerAngle
    }

    private func smoothed(at i: Int) -> CGPoint {
        let p = locations[i]
        guard !isAnchor(i) else { return p }
        let a = arcs[i], n = locations.count
        // The window shrinks to the nearest anchor on either side, so an
        // anchor is never averaged in and its neighbours lead into it.
        var r = Self.radius
        var j = i - 1
        while j >= 0, a - arcs[j] < r {
            if isAnchor(j) { r = a - arcs[j]; break }
            j -= 1
        }
        j = i + 1
        while j < n, arcs[j] - a < r {
            if isAnchor(j) { r = arcs[j] - a; break }
            j += 1
        }
        guard r > 0 else { return p }
        var lo = i
        while lo > 0, a - arcs[lo - 1] < r { lo -= 1 }
        var hi = i
        while hi < n - 1, arcs[hi + 1] - a < r { hi += 1 }
        // Biweight in arc length, each sample weighted by the stretch of
        // stroke it stands for, so uneven spacing doesn't pull the mean.
        var sx: CGFloat = 0, sy: CGFloat = 0, total: CGFloat = 0
        for k in lo...hi {
            let q = (arcs[k] - a) / r
            let span = (arcs[min(k + 1, n - 1)] - arcs[max(k - 1, 0)]) / 2
            let w = (1 - q * q) * (1 - q * q) * span
            sx += w * (locations[k].x - p.x)
            sy += w * (locations[k].y - p.y)
            total += w
        }
        guard total > 0 else { return p }
        return CGPoint(x: p.x + sx / total, y: p.y + sy / total)
    }
}
