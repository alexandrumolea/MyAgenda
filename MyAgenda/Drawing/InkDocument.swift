//
//  InkDocument.swift
//  MyAgenda
//
//  The page's ink as a PKDrawing we own: strokes split into the ones our
//  renderer draws and the legacy ones PencilKit draws, undo/redo as whole
//  drawing snapshots, and one change event per edit so the surface can
//  redraw only what moved. The stored format is PencilKit's own, untouched.
//

import PencilKit

/// A stroke `InkRenderer` draws, with what the document caches about it.
nonisolated struct InkEntry {
    var stroke: PKStroke
    /// The bounds of our rendering (`InkGeometry.bounds`, not PencilKit's
    /// `renderBounds`, which follow its nibs and are tighter than our round
    /// marker stroke), so a redraw tests a rect instead of evaluating every
    /// polyline.
    var bounds: CGRect
    /// The parametric ranges the stroke's mask keeps: exact for the pieces
    /// the eraser cut here, nil until the eraser first needs them for a
    /// stroke that came from disk (`InkGeometry.keptRanges`).
    var kept: [ClosedRange<CGFloat>]?
    /// The polyline the renderer draws (`InkGeometry.polyline`), kept while
    /// the page is resident so a redraw strokes it instead of evaluating
    /// PencilKit's spline again; nil when not kept.
    var polyline: [InkPoint]?
}

@MainActor
final class InkDocument {
    enum Change {
        /// One stroke appended, with the bounds our renderer draws it in:
        /// draw it on top of what is there.
        case appended(PKStroke, bounds: CGRect)
        /// Ink erased from `bounds`; `legacyChanged` when a PencilKit-drawn
        /// stroke was cut, so the underlay must be rendered again.
        case removed(bounds: CGRect, legacyChanged: Bool)
        /// A lasso move: our ink left `from` and lands in `to` (`.null` when
        /// only PencilKit-drawn strokes moved; those are the underlay's).
        case moved(from: CGRect, to: CGRect, legacyChanged: Bool)
        /// Strokes appended together (a lasso duplicate), ours drawn in
        /// `bounds`.
        case added(bounds: CGRect, legacyChanged: Bool)
        /// Anything else (undo, redo, clear, paste, load): redraw everything.
        case replaced
    }

    private(set) var drawing: PKDrawing
    /// Strokes `InkRenderer` draws, in document order.
    private(set) var owned: [InkEntry] = []
    /// Strokes left to PencilKit, in document order.
    private(set) var legacy: [PKStroke] = []
    /// Who draws each stroke of `drawing`, in its order: the eraser walks
    /// every stroke on every event, and the check reads the path.
    private var ownerships: [InkGeometry.Ownership] = []
    /// Where each legacy stroke's ink is, parallel to `legacy`; nil until the
    /// eraser first asks. PencilKit's `renderBounds` takes tens of
    /// milliseconds for a full page on the first pass, and the getter on
    /// every event adds up.
    private var legacyBounds: [CGRect?] = []
    /// Whether the owned entries keep their polylines: on for the pages that
    /// hold bitmaps (one full evaluation when it turns on), off for the rest,
    /// whose ink only takes memory.
    var keepsPolylines = false {
        didSet {
            guard keepsPolylines != oldValue else { return }
            for index in owned.indices {
                if !keepsPolylines {
                    owned[index].polyline = nil
                } else if owned[index].polyline == nil {
                    owned[index].polyline = InkGeometry.polyline(of: owned[index].stroke)
                }
            }
        }
    }
    var onChange: ((Change) -> Void)?

    private var undoStack: [PKDrawing] = []
    private var redoStack: [PKDrawing] = []
    /// Snapshots are whole drawings; the cap keeps a long session in memory.
    private static let undoLimit = 50
    /// Set by `beginEraseGesture`: the first stroke the gesture cuts pushes
    /// the snapshot, so one eraser pass is one undo step.
    private var eraseSnapshotPending = false

    init(drawing: PKDrawing = PKDrawing()) {
        self.drawing = drawing
        classify()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Edits

    func append(_ stroke: PKStroke) {
        pushUndoSnapshot()
        HitchLog.measure("document.append, \(owned.count + legacy.count) linii") {
            drawing.strokes.append(stroke)
        }
        // Only the new stroke is classified: a full pass would evaluate every
        // stroke's polyline at each pencil lift.
        let bounds = classify(stroke)
        HitchLog.measure("document.append → onChange") {
            onChange?(.appended(stroke, bounds: bounds))
        }
    }

    /// Appends every stroke of `other` (a paste) as one undo step.
    func append(contentsOf other: PKDrawing) {
        guard !other.strokes.isEmpty else { return }
        pushUndoSnapshot()
        drawing.strokes.append(contentsOf: other.strokes)
        classify()
        onChange?(.replaced)
    }

    /// Call when the eraser touches down; the gesture's cuts then share one
    /// undo snapshot.
    func beginEraseGesture() {
        eraseSnapshotPending = true
    }

    /// Cuts the eraser's pass from `a` to `b`, `radius` wide, out of every
    /// stroke it crossed, the legacy ones included: the covered part goes,
    /// the rest stays as masked pieces of the same path, in place. A pass
    /// that touches nothing changes nothing and pushes no snapshot.
    func erase(from a: CGPoint, to b: CGPoint, radius: CGFloat) {
        HitchLog.measure("document.erase, \(owned.count + legacy.count) linii") {
            eraseStep(from: a, to: b, radius: radius)
        }
    }

    private func eraseStep(from a: CGPoint, to b: CGPoint, radius: CGFloat) {
        let segmentBounds = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                   width: abs(b.x - a.x), height: abs(b.y - a.y))
            .insetBy(dx: -radius, dy: -radius)
        var bounds = CGRect.null
        var legacyChanged = false
        // From the back, so the earlier indices stay valid; the stroke's
        // place among the owned or the legacy ones is walked along with it.
        var ownedIndex = owned.count, legacyIndex = legacy.count
        // The `strokes` getter bridges the whole array on every call: work on
        // one copy and write it back once. The undo snapshot pushed below
        // still captures `drawing` before the erase, since the write-back
        // comes after the loop.
        var strokes = drawing.strokes
        for index in strokes.indices.reversed() {
            let stroke = strokes[index]
            let isOwned = ownerships[index] == .owned
            if isOwned { ownedIndex -= 1 } else { legacyIndex -= 1 }
            // Where the stroke's ink is, by its mask when it has one: the
            // whole path's bounds would have every piece of a stroke already
            // cut evaluated on each event.
            let inkBounds = isOwned ? owned[ownedIndex].bounds : legacyInkBounds(at: legacyIndex, stroke: stroke)
            guard inkBounds.insetBy(dx: -radius, dy: -radius).intersects(segmentBounds) else { continue }
            // One polyline per stroke serves the ranges, the cut and the
            // pieces (the same path under other masks): the cached one when
            // the page keeps them.
            let points: [InkPoint]
            let kept: [ClosedRange<CGFloat>]
            if isOwned {
                points = owned[ownedIndex].polyline ?? InkGeometry.polyline(of: stroke)
                if owned[ownedIndex].kept == nil {
                    owned[ownedIndex].kept = InkGeometry.keptRanges(of: stroke, polyline: points)
                }
                kept = owned[ownedIndex].kept!
            } else {
                points = InkGeometry.polyline(of: stroke)
                kept = InkGeometry.keptRanges(of: stroke, polyline: points)
            }
            guard let cut = InkGeometry.cut(stroke, polyline: points, kept: kept,
                                            segment: a, b, radius: radius) else { continue }
            if eraseSnapshotPending {
                pushUndoSnapshot()
            }
            strokes.replaceSubrange(index...index, with: cut.pieces)
            ownerships.replaceSubrange(index...index, with: Array(repeating: ownerships[index], count: cut.pieces.count))
            if isOwned {
                let entries = zip(cut.pieces, cut.ranges).map { piece, range in
                    InkEntry(stroke: piece, bounds: InkGeometry.bounds(of: points, maskOf: piece), kept: [range],
                             polyline: keepsPolylines ? points : nil)
                }
                owned.replaceSubrange(ownedIndex...ownedIndex, with: entries)
            } else {
                legacy.replaceSubrange(legacyIndex...legacyIndex, with: cut.pieces)
                legacyBounds.replaceSubrange(legacyIndex...legacyIndex,
                                             with: Array(repeating: nil, count: cut.pieces.count))
                legacyChanged = true
            }
            bounds = bounds.union(cut.erasedBounds)
        }
        if !bounds.isNull {
            drawing.strokes = strokes
            onChange?(.removed(bounds: bounds, legacyChanged: legacyChanged))
        }
    }

    // MARK: Lasso

    /// The strokes the lasso's `loop` takes, as indices into
    /// `drawing.strokes`: half the visible polyline points inside the loop,
    /// or the centre of a dot. A masked piece counts by what is left of it.
    func strokes(inside loop: CGPath) -> IndexSet {
        let box = loop.boundingBox
        var selected = IndexSet()
        // `owned` and `legacy` hold the strokes themselves: no copy of
        // `drawing.strokes` is needed.
        var ownedIndex = 0, legacyIndex = 0
        for (index, ownership) in ownerships.enumerated() {
            let points: [InkPoint]
            if ownership == .owned {
                let entry = owned[ownedIndex]
                ownedIndex += 1
                guard entry.bounds.intersects(box) else { continue }
                points = entry.polyline ?? InkGeometry.polyline(of: entry.stroke)
                if Self.isTaken(points, of: entry.stroke, by: loop) { selected.insert(index) }
            } else {
                let stroke = legacy[legacyIndex]
                let inkBounds = legacyInkBounds(at: legacyIndex, stroke: stroke)
                legacyIndex += 1
                guard inkBounds.intersects(box) else { continue }
                points = InkGeometry.polyline(of: stroke)
                if Self.isTaken(points, of: stroke, by: loop) { selected.insert(index) }
            }
        }
        return selected
    }

    /// `indices` (into `drawing.strokes`) as indices into `owned` and into
    /// `legacy`.
    func partition(_ indices: IndexSet) -> (owned: IndexSet, legacy: IndexSet) {
        var ownedSet = IndexSet(), legacySet = IndexSet()
        var ownedIndex = 0, legacyIndex = 0
        for (index, ownership) in ownerships.enumerated() {
            if ownership == .owned {
                if indices.contains(index) { ownedSet.insert(ownedIndex) }
                ownedIndex += 1
            } else {
                if indices.contains(index) { legacySet.insert(legacyIndex) }
                legacyIndex += 1
            }
        }
        return (ownedSet, legacySet)
    }

    /// Where the ink of `indices` (into `drawing.strokes`) is.
    func inkBounds(of indices: IndexSet) -> CGRect {
        let (ownedSet, legacySet) = partition(indices)
        return inkBounds(owned: ownedSet, legacy: legacySet)
    }

    /// The same, for indices already split into `owned` and `legacy`.
    private func inkBounds(owned ownedSet: IndexSet, legacy legacySet: IndexSet) -> CGRect {
        var bounds = CGRect.null
        for index in ownedSet { bounds = bounds.union(owned[index].bounds) }
        for index in legacySet { bounds = bounds.union(legacyInkBounds(at: index, stroke: legacy[index])) }
        return bounds
    }

    /// Moves the strokes at `indices` by `offset`, as one undo step. Only
    /// the transform changes: the path keeps its points, so our pen keeps
    /// its signature, and the mask (in the path's space) goes along.
    func translate(_ indices: IndexSet, by offset: CGVector) {
        guard offset != .zero, !indices.isEmpty else { return }
        pushUndoSnapshot()
        let shift = CGAffineTransform(translationX: offset.dx, y: offset.dy)
        var from = CGRect.null, to = CGRect.null
        var legacyChanged = false
        var ownedIndex = 0, legacyIndex = 0
        var strokes = drawing.strokes
        for index in strokes.indices {
            let isOwned = ownerships[index] == .owned
            let slot = isOwned ? ownedIndex : legacyIndex
            if isOwned { ownedIndex += 1 } else { legacyIndex += 1 }
            guard indices.contains(index) else { continue }
            let stroke = strokes[index]
            let moved = PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform.concatenating(shift),
                                 mask: stroke.mask, randomSeed: stroke.randomSeed)
            strokes[index] = moved
            if isOwned {
                let old = owned[slot].bounds
                owned[slot].stroke = moved
                owned[slot].bounds = old.offsetBy(dx: offset.dx, dy: offset.dy)
                owned[slot].polyline = owned[slot].polyline?.map {
                    InkPoint(location: CGPoint(x: $0.location.x + offset.dx, y: $0.location.y + offset.dy),
                             width: $0.width)
                }
                from = from.union(old)
                to = to.union(owned[slot].bounds)
            } else {
                // The underlay renders these again; no tile needs them.
                legacy[slot] = moved
                legacyBounds[slot] = legacyBounds[slot]?.offsetBy(dx: offset.dx, dy: offset.dy)
                legacyChanged = true
            }
        }
        drawing.strokes = strokes
        onChange?(.moved(from: from, to: to, legacyChanged: legacyChanged))
    }

    /// Removes the strokes at `indices`, as one undo step.
    func remove(_ indices: IndexSet) {
        guard !indices.isEmpty else { return }
        pushUndoSnapshot()
        let (ownedSet, legacySet) = partition(indices)
        let bounds = inkBounds(owned: ownedSet, legacy: legacySet)
        drawing.strokes = Self.removing(indices, from: drawing.strokes)
        ownerships = Self.removing(indices, from: ownerships)
        owned = Self.removing(ownedSet, from: owned)
        legacy = Self.removing(legacySet, from: legacy)
        legacyBounds = Self.removing(legacySet, from: legacyBounds)
        onChange?(.removed(bounds: bounds, legacyChanged: !legacySet.isEmpty))
    }

    /// Appends copies of the strokes at `indices`, moved by `offset`, as one
    /// undo step; returns the copies' indices.
    func duplicate(_ indices: IndexSet, offset: CGVector) -> IndexSet {
        guard !indices.isEmpty else { return [] }
        pushUndoSnapshot()
        let shift = CGAffineTransform(translationX: offset.dx, y: offset.dy)
        let strokes = drawing.strokes
        let copies = indices.map { index in
            let stroke = strokes[index]
            return PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform.concatenating(shift),
                            mask: stroke.mask, randomSeed: stroke.randomSeed)
        }
        drawing.strokes.append(contentsOf: copies)
        var bounds = CGRect.null
        var legacyChanged = false
        for copy in copies {
            let copyBounds = classify(copy)
            if ownerships.last == .legacy { legacyChanged = true } else { bounds = bounds.union(copyBounds) }
        }
        onChange?(.added(bounds: bounds, legacyChanged: legacyChanged))
        return IndexSet(strokes.count..<strokes.count + copies.count)
    }

    func clear() {
        guard !drawing.strokes.isEmpty else { return }
        pushUndoSnapshot()
        drawing = PKDrawing()
        classify()
        onChange?(.replaced)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(drawing)
        eraseSnapshotPending = false
        drawing = previous
        classify()
        onChange?(.replaced)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(drawing)
        eraseSnapshotPending = false
        drawing = next
        classify()
        onChange?(.replaced)
    }

    /// A drawing from outside (load, remote change): not undoable, and the
    /// old history no longer applies to it.
    func replace(with drawing: PKDrawing) {
        undoStack.removeAll()
        redoStack.removeAll()
        eraseSnapshotPending = false
        self.drawing = drawing
        classify()
        onChange?(.replaced)
    }

    // MARK: Internals

    private func pushUndoSnapshot() {
        undoStack.append(drawing)
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
        redoStack.removeAll()
        eraseSnapshotPending = false
    }

    /// Where a legacy stroke's ink is, by its mask when it has one, cached:
    /// the whole path's bounds would have every piece of a stroke already
    /// cut evaluated on each eraser event.
    private func legacyInkBounds(at legacyIndex: Int, stroke: PKStroke) -> CGRect {
        if let cached = legacyBounds[legacyIndex] { return cached }
        let bounds: CGRect
        if let mask = stroke.mask, !mask.isEmpty {
            bounds = stroke.renderBounds.intersection(mask.bounds.applying(stroke.transform))
        } else {
            bounds = stroke.renderBounds
        }
        legacyBounds[legacyIndex] = bounds
        return bounds
    }

    /// Whether the lasso takes a stroke whose polyline is `points`: a point
    /// counts when the mask keeps it (the mask is in the path's space, the
    /// points in the page's). A dot, under 3 pt across, is taken by its
    /// centre; anything else when half its visible points are inside.
    private static func isTaken(_ points: [InkPoint], of stroke: PKStroke, by loop: CGPath) -> Bool {
        var visible: [CGPoint] = []
        visible.reserveCapacity(points.count)
        if let mask = stroke.mask, !mask.isEmpty {
            let maskBounds = mask.bounds
            let toMask = stroke.transform.inverted()
            for point in points {
                let local = point.location.applying(toMask)
                if maskBounds.contains(local), mask.contains(local) { visible.append(point.location) }
            }
        } else {
            visible = points.map(\.location)
        }
        guard !visible.isEmpty else { return false }
        var extent = CGRect.null
        for point in visible { extent = extent.union(CGRect(origin: point, size: .zero)) }
        if extent.width < 3, extent.height < 3 {
            return loop.contains(CGPoint(x: extent.midX, y: extent.midY), using: .winding)
        }
        // Decided as soon as either side has more than the other can reach.
        let needed = (visible.count + 1) / 2
        var inside = 0, outside = 0
        for point in visible {
            if loop.contains(point, using: .winding) {
                inside += 1
                if inside >= needed { return true }
            } else {
                outside += 1
                if outside > visible.count - needed { return false }
            }
        }
        return false
    }

    private static func removing<T>(_ indices: IndexSet, from array: [T]) -> [T] {
        array.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
    }

    private func classify() {
        owned.removeAll(keepingCapacity: true)
        legacy.removeAll(keepingCapacity: true)
        legacyBounds.removeAll(keepingCapacity: true)
        ownerships.removeAll(keepingCapacity: true)
        for stroke in drawing.strokes {
            classify(stroke)
        }
    }

    /// Files `stroke` after the ones already classified; returns the bounds
    /// our renderer draws it in.
    @discardableResult
    private func classify(_ stroke: PKStroke) -> CGRect {
        let points = InkGeometry.polyline(of: stroke)
        let bounds = InkGeometry.bounds(of: points, maskOf: stroke)
        let ownership = InkGeometry.ownership(of: stroke)
        ownerships.append(ownership)
        switch ownership {
        case .owned:
            owned.append(InkEntry(stroke: stroke, bounds: bounds, kept: nil,
                                  polyline: keepsPolylines ? points : nil))
        case .legacy:
            legacy.append(stroke)
            legacyBounds.append(nil)
        }
        return bounds
    }
}
