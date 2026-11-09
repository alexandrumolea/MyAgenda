//
//  InkSurfaceView.swift
//  MyAgenda
//
//  The page's ink, in place of PKCanvasView. Three layers: an underlay image
//  PencilKit renders of the legacy strokes, bitmap tiles of the committed
//  strokes our renderer draws (only the tiles a stroke lands on are redrawn,
//  and only where ink is are there tiles), and the live stroke under the
//  Pencil, in a view the size of that stroke. Live and committed go through the
//  same geometry and renderer, so the line does not change when the pencil
//  lifts. Only the pages in reach keep these bitmaps (`isResident`); the
//  others hold just the document and redraw when they come back. The
//  surface takes no touches itself: the Pencil arrives through a recognizer
//  on the page's scroll view, so it writes over the boxes too, and the
//  finger reaches the boxes and scrolls as before. With the lasso, a finger
//  on the selection drags or taps it through recognizers there too.
//

import SwiftUI
import PencilKit
import SwiftData
import UniformTypeIdentifiers

// MARK: - Pencil recognizer

/// Hands the Pencil's touches to the surface. It lives on the page's scroll
/// view, so it sees the Pencil wherever it lands (a box above the ink
/// included) and the finger never reaches it.
final class InkPencilRecognizer: UIGestureRecognizer {
    weak var surface: InkSurfaceView?

    init(surface: InkSurfaceView) {
        self.surface = surface
        super.init(target: nil, action: nil)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        requiresExclusiveTouchType = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        surface?.strokeBegan(touch, event: event)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        surface?.strokeMoved(touch, event: event)
        state = .changed
    }

    // The state always moves on, or the recognizer would stay in `.changed`
    // and keep the Pencil from scrolling the page afterwards.
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { surface?.strokeEnded(touch, event: event) }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { surface?.strokeCancelled(touch, event: event) }
        state = .cancelled
    }
}

// MARK: - Surface

final class InkSurfaceView: UIView {
    enum Mode: Equatable {
        case pen(LiveStroke.Profile, color: UIColor, width: CGFloat)
        case highlighter(color: UIColor, width: CGFloat)
        case eraser(width: CGFloat)
        /// The Pencil draws a loop round the ink to select it, and drags the
        /// selection; nothing is drawn into the page.
        case lasso
    }

    let document = InkDocument()
    /// Called after the document changed and the surface redrew.
    var onDocumentChange: (() -> Void)?
    /// A stroke starts: the page ends any box edit, as for PencilKit's tools.
    var onInkBegan: () -> Void = {}

    var mode: Mode = .lasso {
        didSet { if mode != oldValue { deselect(); updateRecognizer(); refreshRing() } }
    }
    // The recognizer first: deactivation drops a half stroke before its
    // live store goes.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if !isActive { deselect() }
            updateRecognizer()
            applyLiveResidency()
        }
    }
    var isPencilDevice = false {
        didSet { if isPencilDevice != oldValue { updateRecognizer(); applyLiveResidency() } }
    }
    /// Only the selected page and its neighbours keep bitmaps (committed,
    /// live, underlay); the others hold just the document, and draw it all
    /// again when they come back in reach.
    var isResident = false {
        didSet { if isResident != oldValue { applyResidency() } }
    }
    /// Dark paper shows the ink inverted; the strokes keep their white-paper
    /// colors.
    var paper: PaperColor = .white {
        didSet { if paper != oldValue { deselect(); redrawAll(); refreshRing() } }
    }
    /// The notebook's colour, for the lasso's outline.
    var accent: UIColor = .systemBlue {
        didSet { if accent != oldValue { outlineLayer.strokeColor = accent.cgColor } }
    }
    /// Bitmap pixels per point, on top of the screen's: 1 on iPad; on iPhone
    /// the page's fit-to-width scale, so three live pages stay small.
    var renderScale: CGFloat = 1 {
        didSet { if renderScale != oldValue { applyScale() } }
    }

    private let underlayLayer = CALayer()
    /// Holds the tiles of the committed ink; draws nothing itself. A single
    /// page-sized bitmap gets no partial updates from CoreAnimation: every
    /// lift redrew the whole page.
    private let committedContainer = UIView()
    private var tiles: [TileIndex: DrawingView] = [:]
    private struct TileIndex: Hashable { var col: Int; var row: Int }
    /// Tiles are sized in pixels, so every tile origin falls on the page's
    /// pixel grid, also on iPhone with its fractional `renderScale`.
    private static let tilePixels: CGFloat = 512
    private var bitmapScale: CGFloat { traitCollection.displayScale * renderScale }
    private var tileSide: CGFloat { Self.tilePixels / bitmapScale }
    /// The width and scale the tiles were laid out for; a change of either
    /// moves the tile grid, so the tiles are built again.
    private var tileLayout = (width: CGFloat(0), height: CGFloat(0), scale: CGFloat(0))
    private let liveView = DrawingView()
    /// The live view covers the stroke, not the page: it grows with the
    /// stroke on a coarse grid, so it seldom moves. `.null` between strokes.
    private var liveFrame = CGRect.null
    private static let liveGrid: CGFloat = 64
    private lazy var recognizer = InkPencilRecognizer(surface: self)

    private var live: LiveStroke?
    /// The live stroke's polyline, evaluated once per touch and drawn from
    /// here, so the dirty rect and the drawing agree.
    private var livePolyline: [InkPoint] = []
    /// The eraser gesture under way: where it last was, and how wide.
    private var erasing: (location: CGPoint, width: CGFloat)?
    /// The eraser's disc, outlined under the hovering or touching Pencil. An
    /// overlay only: never in a bitmap, never in the document.
    private let ringLayer = CAShapeLayer()
    /// The path is rebuilt only when the width changes.
    private var ringWidth: CGFloat = 0
    /// Where the Pencil hovers; nil when it does not.
    private var hoverLocation: CGPoint?
    private lazy var hoverRecognizer = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))

    /// The lasso's selection: indices into `document.drawing.strokes`, the
    /// loop that took them, as it shows now, and where their ink is.
    private var selection: (indices: IndexSet, loop: CGPath, bounds: CGRect)?
    /// The loop the Pencil is drawing; nil otherwise.
    private var loopPath: CGMutablePath?
    private var loopLast = CGPoint.zero
    private var loopPointCount = 0
    /// The dashed loop round the selection; above the ink like the ring,
    /// moved by its position while the selection is dragged.
    private let outlineLayer = CAShapeLayer()
    /// A touch on the selection: where it landed, and how far the selection
    /// has followed it (whole device pixels, kept on the page).
    private var drag: (start: CGPoint, offset: CGVector)?
    /// What a drag lifted out of the page, as indices into `document.owned`
    /// and `document.legacy`: the tiles and the underlay leave them out.
    private var liftedOwned = IndexSet()
    private var liftedLegacy = IndexSet()
    /// The lifted owned strokes, drawn once at the pick-up and then only
    /// moved; above the committed ink, below the live stroke. Frame zero
    /// when nothing is lifted.
    private let selectionView = DrawingView()
    /// Where `selectionView` was at the pick-up: it draws relative to this,
    /// not to its frame, so the drag moves its pixels unchanged.
    private var liftOrigin = CGPoint.zero
    /// The lifted legacy strokes' image, between the underlay and our ink.
    private let liftedLegacyLayer = CALayer()
    private var liftedLegacyRect = CGRect.zero
    /// The underlay without the selected legacy strokes, and those strokes
    /// alone, rendered when the selection is made: the pick-up only swaps
    /// images.
    private var preparedLegacy: LiftedLegacy?
    private var prepareGeneration = 0
    /// Set while the selection edits the document, so the change does not
    /// end the selection as an edit from elsewhere does.
    private var editingSelection = false
    private var lastDropTime: CFTimeInterval = 0
    private lazy var selectionPan = UIPanGestureRecognizer(target: self, action: #selector(selectionPanned(_:)))
    private lazy var selectionTap = UITapGestureRecognizer(target: self, action: #selector(selectionTapped(_:)))
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var menuVisible = false
    /// When the menu last went away: the system may hide it at touch-down,
    /// and a tap that meant to hide it would show it again.
    private var lastMenuDismissal: CFTimeInterval = 0
    /// A Pencil touch that landed while the finger drags the selection: it
    /// does nothing, to its lift.
    private weak var ignoredPencil: UITouch?

    private var underlayGeneration = 0
    private var underlayBounds = CGRect.zero
    /// One PencilKit render at a time: an eraser pass over a legacy stroke
    /// asks for one per event, and a queue of full-page renders would land
    /// the final gap long after the lift. A request during a render only
    /// marks it dirty; the render that returns starts the next.
    private var underlayRenderInFlight = false
    private var underlayDirty = false
    /// Under the eraser only the cut spot is rendered again and composited
    /// into the underlay image; a full render at the lift replaces it.
    private var patchInFlight = false
    private var patchDirty = CGRect.null
    /// A gesture cut legacy ink: the lift re-renders the whole underlay.
    private var underlayPatched = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = false
        contentMode = .redraw

        // No implicit animation when the image or the frame changes.
        underlayLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        underlayLayer.frame = bounds
        layer.addSublayer(underlayLayer)
        // Lifted legacy ink stays under our own, as on the page.
        liftedLegacyLayer.isHidden = true
        liftedLegacyLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                     "hidden": NSNull()]
        layer.addSublayer(liftedLegacyLayer)

        // The ring follows the Pencil with no animation; its z keeps it above
        // the drawing views, whatever order they join in.
        ringLayer.fillColor = nil
        ringLayer.lineWidth = 1
        ringLayer.lineDashPattern = [3, 3]
        ringLayer.isHidden = true
        ringLayer.zPosition = 1
        ringLayer.actions = ["position": NSNull(), "path": NSNull(), "hidden": NSNull(),
                             "strokeColor": NSNull()]
        layer.addSublayer(ringLayer)
        hoverRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hoverRecognizer.isEnabled = false
        addGestureRecognizer(hoverRecognizer)

        outlineLayer.fillColor = nil
        outlineLayer.lineWidth = 1
        outlineLayer.lineDashPattern = [4, 3]
        outlineLayer.strokeColor = accent.cgColor
        outlineLayer.isHidden = true
        outlineLayer.zPosition = 1
        outlineLayer.actions = ["position": NSNull(), "path": NSNull(), "hidden": NSNull(),
                                "strokeColor": NSNull()]
        layer.addSublayer(outlineLayer)
        // The finger moves or taps the selection; they join the page's
        // scroll view with the Pencil's recognizer.
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        selectionPan.allowedTouchTypes = direct
        selectionPan.maximumNumberOfTouches = 1
        selectionPan.delegate = self
        selectionPan.isEnabled = false
        selectionTap.allowedTouchTypes = direct
        selectionTap.cancelsTouchesInView = false
        selectionTap.delegate = self
        selectionTap.isEnabled = false
        addInteraction(editMenu)

        // The container and the live view join the hierarchy in
        // `applyResidency`; the tiles follow the ink, the live view the
        // stroke, so only the container follows the bounds.
        committedContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        committedContainer.backgroundColor = .clear
        committedContainer.isUserInteractionEnabled = false
        liveView.drawHandler = { [unowned self] rect, ctx in
            guard let live else { return }
            // The view sits at `liveFrame`: the context moves to page
            // coordinates and the dirty rect goes with it.
            let origin = liveView.frame.origin
            HitchLog.measure("liveView.draw \(Int(rect.width))×\(Int(rect.height)), \(livePolyline.count) puncte") {
                ctx.translateBy(x: -origin.x, y: -origin.y)
                InkRenderer.draw(livePolyline, inkType: live.inkType,
                                 color: InkRenderer.shownColor(live.color, on: paper),
                                 rect: rect.offsetBy(dx: origin.x, dy: origin.y), in: ctx)
            }
        }
        selectionView.drawHandler = { [unowned self] rect, ctx in
            let origin = liftOrigin
            let pageRect = rect.offsetBy(dx: origin.x, dy: origin.y)
            ctx.translateBy(x: -origin.x, y: -origin.y)
            let owned = document.owned
            for index in liftedOwned where index < owned.count && owned[index].bounds.intersects(pageRect) {
                InkRenderer.draw(owned[index], paper: paper,
                                 rect: pageRect.contains(owned[index].bounds) ? nil : pageRect, in: ctx)
            }
        }
        document.onChange = { [weak self] change in self?.documentChanged(change) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The surface covers the whole page, boxes included, so it lets touches
    /// fall through: a view can't tell the Pencil from a finger when it is
    /// hit. The recognizer on the scroll view sees the Pencil wherever it
    /// lands. Hover stays, for the Pencil's tool preview.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard event?.type == .hover else { return nil }
        return super.hitTest(point, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        underlayLayer.frame = bounds
        if bounds.width != tileLayout.width {
            // The selection's loop and images are for the old width.
            deselect()
            rebuildTiles()
        } else {
            // Only the height moved: the bottom row's tiles follow the edge
            // in place (`.redraw` repaints them), and a tile left outside
            // goes.
            for (index, tile) in tiles {
                let frame = cell(index).intersection(bounds)
                if frame.isEmpty {
                    tile.removeFromSuperview()
                    tiles[index] = nil
                } else if tile.frame != frame {
                    tile.frame = frame
                }
            }
            // Paper back after a shrink: the ink past the old edge gets its
            // tiles again.
            if bounds.height > tileLayout.height {
                let oldEdge = tileLayout.height
                for entry in document.owned where entry.bounds.maxY > oldEdge {
                    invalidate(entry.bounds, creating: true)
                }
            }
            // The prepared underlay is page-sized.
            if bounds.height != tileLayout.height, selection != nil { prepareLegacyImages() }
            tileLayout.height = bounds.height
        }
        if bounds != underlayBounds {
            HitchLog.note("layoutSubviews: bounds \(Int(bounds.width))×\(Int(bounds.height)), substratul se reface")
            refreshUnderlay()
        }
    }

    // MARK: Recognizer home

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // A sublayer does not take the screen's scale by itself.
        ringLayer.contentsScale = traitCollection.displayScale
        outlineLayer.contentsScale = traitCollection.displayScale
        applyScale()
        // iPhone has no Pencil: its scroll view never gets the recognizer.
        guard isPencilDevice, let page = pageScrollView else { return }
        updateRecognizer()
        for gesture in [recognizer, selectionPan, selectionTap] where gesture.view !== page {
            page.addGestureRecognizer(gesture)
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        deselect()
        for gesture in [recognizer, selectionPan, selectionTap] {
            gesture.view?.removeGestureRecognizer(gesture)
        }
        hoverLocation = nil
        refreshRing()
    }

    /// The scroll view holding the page: the ink and every box.
    private var pageScrollView: UIScrollView? {
        var next = superview
        while let candidate = next {
            if let scroll = candidate as? UIScrollView { return scroll }
            next = candidate.superview
        }
        return nil
    }

    private func updateRecognizer() {
        let enabled = isActive && isPencilDevice
        recognizer.isEnabled = enabled
        // Disabling cancels a gesture under way; a page that is no longer
        // active drops its half stroke, as before.
        if !enabled { dropGesture() }
        // The finger reaches the selection only where there can be one.
        let selecting = enabled && isResident && mode == .lasso
        selectionPan.isEnabled = selecting
        selectionTap.isEnabled = selecting
        // Hover is wanted in every drawing mode, so the ring is there as
        // soon as the eraser is picked.
        let hovering = isActive && isPencilDevice
        hoverRecognizer.isEnabled = hovering
        if !hovering { hoverLocation = nil }
        refreshRing()
    }

    // MARK: Residency

    /// Adds or drops the bitmap-backed views. Only leaving the hierarchy
    /// frees a backing store for good: a view that stays is redisplayed by
    /// CA on the next bounds change (`contentMode = .redraw`), which
    /// allocates it again. A tile just added draws in the CA commit that
    /// shows it, so no frame goes without the ink.
    private func applyResidency() {
        if !isResident { deselect() }
        UIView.performWithoutAnimation {
            // The polylines first: the tiles built below draw from them.
            document.keepsPolylines = isResident
            setResident(committedContainer, isResident, frame: bounds)
            if !isResident { removeTiles() }
            applyLiveResidency()
            if isResident {
                // The scale is set here, not in `applyScale`, or the latter
                // would request the underlay too and the refresh below again.
                // `applyScale` builds the tiles: none are laid out yet.
                underlayLayer.contentsScale = bitmapScale
                applyScale()
                refreshUnderlay()
            } else {
                underlayGeneration += 1
                underlayLayer.contents = nil
                hideLiftedLegacy()
                patchDirty = .null
                underlayPatched = false
            }
        }
        updateRecognizer()
    }

    /// One live store, on the active iPad page. Its frame is empty until a
    /// stroke starts: nothing shown, no store. The lifted selection's view
    /// likewise, until a drag lifts it; it goes under the live stroke.
    private func applyLiveResidency() {
        UIView.performWithoutAnimation {
            let resident = isResident && isActive && isPencilDevice
            setResident(selectionView, resident, frame: .zero)
            setResident(liveView, resident, frame: .zero)
            if resident {
                bringSubviewToFront(selectionView)
                bringSubviewToFront(liveView)
            }
        }
    }

    private func setResident(_ view: UIView, _ resident: Bool, frame: CGRect) {
        if resident {
            guard view.superview == nil else { return }
            view.frame = frame
            addSubview(view)
        } else {
            view.removeFromSuperview()
            view.layer.contents = nil
        }
    }

    // MARK: Scale

    private func applyScale() {
        guard isResident else { return }
        let scale = bitmapScale
        if liveView.contentScaleFactor != scale {
            liveView.contentScaleFactor = scale
            liveView.setNeedsDisplay()
        }
        if selectionView.contentScaleFactor != scale {
            selectionView.contentScaleFactor = scale
            selectionView.setNeedsDisplay()
        }
        // The tile side follows the scale, and the selection's pixel grid.
        if tileLayout.scale != scale {
            deselect()
            rebuildTiles()
        }
        if underlayLayer.contentsScale != scale {
            underlayLayer.contentsScale = scale
            refreshUnderlay()
        }
    }

    // MARK: Tiles

    /// The committed ink lives in tiles of `tilePixels` a side, one bitmap
    /// each, only where ink is: a stroke invalidates the tiles it crossed and
    /// each repaints just its dirty rect, whatever the page's height.
    private func cell(_ index: TileIndex) -> CGRect {
        let side = tileSide
        return CGRect(x: CGFloat(index.col) * side, y: CGFloat(index.row) * side, width: side, height: side)
    }

    /// The tile at `index`, made when `creating` and the cell meets the
    /// page. A new tile draws whole on its first commit.
    private func tile(at index: TileIndex, creating: Bool) -> DrawingView? {
        if let tile = tiles[index] { return tile }
        guard creating else { return nil }
        let frame = cell(index).intersection(bounds)
        guard !frame.isEmpty else { return nil }
        let tile = DrawingView(frame: frame)
        tile.drawHandler = { [unowned self, unowned tile] rect, ctx in
            // The tile's origin is whole pixels, so the page's ink lands on
            // the same pixels in every tile and in the live view.
            let origin = tile.frame.origin
            var drawn = 0
            HitchLog.measure("tile.draw (\(index.col),\(index.row)) \(Int(rect.width))×\(Int(rect.height)), \(drawn) linii") {
                ctx.translateBy(x: -origin.x, y: -origin.y)
                drawn = InkRenderer.draw(document.owned, paper: paper,
                                         rect: rect.offsetBy(dx: origin.x, dy: origin.y),
                                         skipping: liftedOwned, in: ctx)
            }
        }
        UIView.performWithoutAnimation { committedContainer.addSubview(tile) }
        tile.contentScaleFactor = bitmapScale
        // Whole on its first commit, whatever rect asked for it.
        tile.setNeedsDisplay()
        tiles[index] = tile
        return tile
    }

    /// Marks `pageRect` dirty in every tile it covers; `creating` makes the
    /// tiles that are not there yet (new ink), erased ink needs none.
    private func invalidate(_ pageRect: CGRect, creating: Bool) {
        let rect = pageRect.intersection(bounds)
        guard !rect.isEmpty else { return }
        // A rect ending on a tile edge does not reach the next tile.
        let side = tileSide
        let c0 = Int(floor(rect.minX / side)), r0 = Int(floor(rect.minY / side))
        let c1 = max(Int(ceil(rect.maxX / side)) - 1, c0), r1 = max(Int(ceil(rect.maxY / side)) - 1, r0)
        for row in r0...r1 {
            for col in c0...c1 {
                guard let tile = tile(at: TileIndex(col: col, row: row), creating: creating) else { continue }
                let origin = tile.frame.origin
                tile.setNeedsDisplay(rect.intersection(tile.frame).offsetBy(dx: -origin.x, dy: -origin.y))
            }
        }
    }

    /// Tiles from scratch, for the current bounds and scale: one where each
    /// owned stroke is, none elsewhere.
    private func rebuildTiles() {
        guard isResident else { return }
        removeTiles()
        tileLayout = (bounds.width, bounds.height, bitmapScale)
        for entry in document.owned {
            invalidate(entry.bounds, creating: true)
        }
    }

    private func removeTiles() {
        for tile in tiles.values { tile.removeFromSuperview() }
        tiles.removeAll()
        tileLayout = (0, 0, 0)
    }

    // MARK: Touches

    func strokeBegan(_ touch: UITouch, event: UIEvent?) {
        guard isActive, touch.type == .pencil else { return }
        // Ending the finger's drag here would hand the selection to the
        // Pencil while the finger still moves it.
        if case .lasso = mode, selectionPan.state == .began || selectionPan.state == .changed {
            ignoredPencil = touch
            return
        }
        onInkBegan()
        dropGesture()
        // Hover stops reporting at contact, and its last point is where the
        // touch landed: dropped, or the lift would show the ring back there.
        hoverLocation = nil
        switch mode {
        case .pen(let profile, let color, let width):
            live = LiveStroke(profile: profile, baseWidth: width, color: color)
            appendLive(touch, event: event)
        case .highlighter(let color, let width):
            live = LiveStroke(profile: .highlighter, baseWidth: width, color: color)
            appendLive(touch, event: event)
        case .eraser(let width):
            document.beginEraseGesture()
            let location = touch.preciseLocation(in: self)
            erasing = (location, width)
            erase(to: location)
        case .lasso:
            beginLasso(at: touch.preciseLocation(in: self))
        }
    }

    // A gesture finishes the way it started, whatever the mode is now.
    func strokeMoved(_ touch: UITouch, event: UIEvent?) {
        guard touch !== ignoredPencil else { return }
        if live != nil {
            appendLive(touch, event: event)
        } else if erasing != nil {
            erase(to: touch.preciseLocation(in: self))
        } else if loopPath != nil {
            extendLoop(to: touch.preciseLocation(in: self))
        } else if drag != nil {
            dragMoved(to: touch.preciseLocation(in: self))
        }
    }

    func strokeEnded(_ touch: UITouch, event: UIEvent?) {
        guard touch !== ignoredPencil else {
            ignoredPencil = nil
            return
        }
        if let live {
            appendLive(touch, event: event)
            // The committed stroke lands in the same CA commit as the live
            // one leaves: no frame goes without the line, none has two.
            if let stroke = live.stroke() {
                document.append(stroke)
            }
            clearLive()
        } else if erasing != nil {
            erase(to: touch.preciseLocation(in: self))
            erasing = nil
            refreshRing()
            finishUnderlayPatches()
        } else if loopPath != nil {
            finishLoop(at: touch.preciseLocation(in: self))
        } else if drag != nil {
            // A lift that moved nothing shows or hides the menu.
            if isLifted {
                drop()
            } else {
                drag = nil
                toggleMenu()
            }
        }
    }

    func strokeCancelled(_ touch: UITouch, event: UIEvent?) {
        guard touch !== ignoredPencil else {
            ignoredPencil = nil
            return
        }
        dropGesture()
    }

    private func dropGesture() {
        clearLive()
        erasing = nil
        // A loop not closed selects nothing; a drag ends where it is.
        if loopPath != nil {
            loopPath = nil
            outlineLayer.isHidden = true
        }
        drop()
        refreshRing()
        finishUnderlayPatches()
    }

    // MARK: Live stroke

    private func appendLive(_ touch: UITouch, event: UIEvent?) {
        guard let live else { return }
        HitchLog.measure("appendLive, \(livePolyline.count) puncte") { appendLiveStep(live, touch, event: event) }
    }

    private func appendLiveStep(_ live: LiveStroke, _ touch: UITouch, event: UIEvent?) {
        // A new sample reshapes only the last few B-spline spans (the pinned
        // end moves): redraw where they were and where they are now. A span
        // is four polyline points; six spans are plenty.
        let before = InkGeometry.bounds(of: Array(livePolyline.suffix(Self.changedPoints)))
        live.append(touch, event: event, in: self)
        livePolyline = live.path().map {
            InkGeometry.polyline(of: $0, inkType: live.inkType)
        } ?? []
        let after = InkGeometry.bounds(of: Array(livePolyline.suffix(Self.changedPoints)))
        let dirty = before.union(after)
        guard !dirty.isNull else { return }
        // The view covers the stroke, on the grid so it seldom moves, and
        // only grows: what it has drawn stays where it is. A frame change
        // repaints it whole (`.redraw`); otherwise just the changed tail.
        let wanted = Self.gridAligned(InkGeometry.bounds(of: livePolyline).insetBy(dx: -2, dy: -2))
            .intersection(bounds)
        guard !wanted.isEmpty else { return }
        liveFrame = liveFrame.union(wanted)
        if liveFrame != liveView.frame {
            UIView.performWithoutAnimation { liveView.frame = liveFrame }
            liveView.setNeedsDisplay()
        } else {
            let origin = liveView.frame.origin
            liveView.setNeedsDisplay(dirty.insetBy(dx: -2, dy: -2).offsetBy(dx: -origin.x, dy: -origin.y))
        }
    }

    /// Polyline points at the end of `livePolyline` the next sample can change.
    private static let changedPoints = 6 * Int(1 / InkGeometry.step) + 1

    /// `rect` grown outward to the live grid: whole points, so the live
    /// view's pixels sit on the tiles'.
    private static func gridAligned(_ rect: CGRect) -> CGRect {
        let g = liveGrid
        let minX = floor(rect.minX / g) * g, minY = floor(rect.minY / g) * g
        return CGRect(x: minX, y: minY, width: ceil(rect.maxX / g) * g - minX, height: ceil(rect.maxY / g) * g - minY)
    }

    private func clearLive() {
        guard live != nil else { return }
        live = nil
        livePolyline = []
        liveFrame = .null
        // An empty frame shows nothing and frees the store.
        UIView.performWithoutAnimation { liveView.frame = .zero }
    }

    // MARK: Eraser

    /// Erases what the eraser's disc covered on its way to `location`, the
    /// legacy strokes included: the ink under it goes, the rest of each
    /// stroke stays. At touch-down the way is a point, so the disc alone.
    private func erase(to location: CGPoint) {
        guard let (from, width) = erasing else { return }
        erasing = (location, width)
        refreshRing()
        document.erase(from: from, to: location, radius: width / 2)
    }

    @objc private func hoverChanged(_ gesture: UIHoverGestureRecognizer) {
        // A touch under way outranks the hover; it resumes after the lift.
        switch gesture.state {
        case .began, .changed:
            hoverLocation = live == nil && erasing == nil ? gesture.location(in: self) : nil
        default:
            hoverLocation = nil
        }
        refreshRing()
    }

    /// Shows the disc the eraser removes, under the touch while it erases
    /// and under the hover otherwise; hidden in every other case.
    private func refreshRing() {
        let shown: (CGPoint, CGFloat)?
        if let erasing {
            shown = (erasing.location, erasing.width)
        } else if case .eraser(let width) = mode, let hoverLocation {
            shown = (hoverLocation, width)
        } else {
            shown = nil
        }
        guard let (center, width) = shown else {
            ringLayer.isHidden = true
            return
        }
        if width != ringWidth {
            ringLayer.path = CGPath(ellipseIn: CGRect(x: -width / 2, y: -width / 2, width: width, height: width),
                                    transform: nil)
            ringWidth = width
        }
        ringLayer.position = center
        ringLayer.strokeColor = InkRenderer.shownColor(.black, on: paper).withAlphaComponent(0.4).cgColor
        ringLayer.isHidden = false
    }

    // MARK: Document

    private func documentChanged(_ change: InkDocument.Change) {
        // The selection is indices into the drawing as it was: a change it
        // did not make (undo, redo, paste, iCloud) ends it.
        if !editingSelection, selection != nil { clearSelection() }
        // A page out of reach keeps no bitmap to update; it redraws whole
        // when it comes back. The save still happens.
        if isResident {
            switch change {
            case .appended(_, let bounds):
                // Only our own strokes are appended one by one; a paste
                // arrives as `.replaced`.
                invalidate(bounds.insetBy(dx: -2, dy: -2), creating: true)
            case .removed(let bounds, let legacyChanged):
                invalidate(bounds.insetBy(dx: -2, dy: -2), creating: false)
                // While the eraser moves, only the cut spot is rendered
                // again; the whole page waits for the lift.
                if legacyChanged {
                    if erasing != nil { patchUnderlay(bounds) } else { refreshUnderlay() }
                }
            case .moved(let from, let to, let legacyChanged):
                invalidate(from.insetBy(dx: -2, dy: -2), creating: false)
                invalidate(to.insetBy(dx: -2, dy: -2), creating: true)
                if legacyChanged { refreshUnderlay() }
            case .added(let bounds, let legacyChanged):
                invalidate(bounds.insetBy(dx: -2, dy: -2), creating: true)
                if legacyChanged { refreshUnderlay() }
            case .replaced:
                rebuildTiles()
                refreshUnderlay()
            }
        }
        onDocumentChange?()
    }

    private func redrawAll() {
        guard isResident else { return }
        HitchLog.note("redrawAll, \(document.owned.count) linii, \(tiles.count) plăci")
        for tile in tiles.values { tile.setNeedsDisplay() }
        if live != nil { liveView.setNeedsDisplay() }
        refreshUnderlay()
    }

    /// PencilKit renders the legacy strokes off the main thread; a newer
    /// request makes an older result stale, and the old image stays until
    /// the newest lands.
    private func refreshUnderlay() {
        guard isResident else { return }
        underlayGeneration += 1
        if underlayRenderInFlight {
            underlayDirty = true
            return
        }
        let generation = underlayGeneration
        underlayBounds = bounds
        // Strokes a drag lifted are on their own layer meanwhile.
        var legacy = document.legacy
        if !liftedLegacy.isEmpty {
            legacy = legacy.enumerated().filter { !liftedLegacy.contains($0.offset) }.map(\.element)
        }
        guard !legacy.isEmpty, bounds.width > 0, bounds.height > 0 else {
            underlayLayer.contents = nil
            if liftedLegacy.isEmpty { hideLiftedLegacy() }
            return
        }
        let rect = bounds, paper = paper, scale = underlayLayer.contentsScale
        underlayRenderInFlight = true
        Task { @MainActor [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) {
                UnderlayImage(image: InkRenderer.underlayImage(strokes: legacy, bounds: rect, paper: paper, scale: scale)?.cgImage)
            }.value
            guard let self else { return }
            self.underlayRenderInFlight = false
            // A page gone out of reach bumped the generation too, so its
            // cleared contents stay cleared. A render begun before a gesture
            // started cutting lacks its cuts, and would cover the patches:
            // dropped, the lift's refresh follows anyway.
            if self.underlayGeneration == generation, !self.underlayPatched {
                self.underlayLayer.contents = rendered.image
                // A dropped legacy selection is in this image now: its own
                // layer goes in the same commit.
                if self.liftedLegacy.isEmpty { self.hideLiftedLegacy() }
            }
            if self.underlayDirty {
                self.underlayDirty = false
                self.refreshUnderlay()
            }
        }
    }

    /// A full-page render of the legacy ink takes tens of milliseconds, and
    /// the eraser asks for one per event: while it moves, only the rect it
    /// cut is rendered, and composited into a copy of the underlay image
    /// (PencilKit's image is transparent where ink was cut, so a patch laid
    /// over the old image would still show the ink). One patch at a time;
    /// the cuts made meanwhile accumulate and render together.
    private func patchUnderlay(_ rect: CGRect) {
        guard isResident else { return }
        patchDirty = patchDirty.union(rect)
        underlayPatched = true
        if !patchInFlight { startPatch() }
    }

    private func startPatch() {
        // The eraser's antialiasing reaches a little past the cut. Whole
        // points, so the patch's pixels sit on the underlay's and no seam
        // shows along its edge.
        let rect = patchDirty.insetBy(dx: -4, dy: -4).integral.intersection(bounds)
        patchDirty = .null
        guard !rect.isEmpty else { return }
        // No image to patch yet (the first render is still on its way): a
        // full render instead, asked for after the cut, so it has it and
        // may land as the first base.
        guard let base = underlayLayer.contents as! CGImage? else {
            underlayPatched = false
            refreshUnderlay()
            return
        }
        let legacy = document.legacy
        let paper = paper, scale = underlayLayer.contentsScale
        let pageBounds = bounds, baseImage = UnderlayImage(image: base)
        patchInFlight = true
        Task { @MainActor [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) {
                let patch = InkRenderer.underlayImage(strokes: legacy, bounds: rect, paper: paper, scale: scale)
                return UnderlayImage(image: InkRenderer.underlayImage(patching: baseImage.image!, with: patch,
                                                                      in: rect, bounds: pageBounds))
            }.value
            guard let self else { return }
            self.patchInFlight = false
            // Only over the very image it was composited from: a full
            // render that landed meanwhile has the cut or is followed by
            // one that does, and a cleared page stays cleared.
            if let image = rendered.image, self.underlayLayer.contents as! CGImage? === base {
                self.underlayLayer.contents = image
            }
            // After the lift the full render is on its way; nothing more
            // to patch.
            if !self.patchDirty.isNull, self.erasing != nil {
                self.startPatch()
            } else {
                self.patchDirty = .null
            }
        }
    }

    /// The lift after a gesture that cut legacy ink: the whole underlay is
    /// rendered again.
    private func finishUnderlayPatches() {
        guard underlayPatched else { return }
        underlayPatched = false
        refreshUnderlay()
    }

    /// `CGImage` is not Sendable; the renders cross to the main actor in this.
    private struct UnderlayImage: @unchecked Sendable {
        let image: CGImage?
    }

    // MARK: Lasso

    /// A finger drag of the selection is under way or ended just now: the
    /// page's long press to paste may end with the same lift, and must not.
    var recentlyMovedSelection: Bool {
        drag != nil || CACurrentMediaTime() - lastDropTime < 0.5
    }

    private var isLifted: Bool { !liftedOwned.isEmpty || !liftedLegacy.isEmpty }

    /// Movement before a touch on the selection lifts it, and between the
    /// points of a loop.
    private static let lassoSlop: CGFloat = 2

    /// The Pencil down: on the selection it may drag it; elsewhere it ends
    /// the selection and starts a loop.
    private func beginLasso(at location: CGPoint) {
        if let selection, selection.loop.contains(location, using: .winding) {
            drag = (location, .zero)
            return
        }
        deselect()
        let path = CGMutablePath()
        path.move(to: location)
        loopPath = path
        loopLast = location
        loopPointCount = 1
        outlineLayer.path = path.copy()
        outlineLayer.position = .zero
        outlineLayer.isHidden = false
    }

    private func extendLoop(to location: CGPoint) {
        guard let loopPath, hypot(location.x - loopLast.x, location.y - loopLast.y) >= Self.lassoSlop else { return }
        loopPath.addLine(to: location)
        loopLast = location
        loopPointCount += 1
        outlineLayer.path = loopPath.copy()
    }

    /// The lift closes the loop and selects what it encloses; a loop that
    /// takes nothing (a tap too) leaves no outline.
    private func finishLoop(at location: CGPoint) {
        extendLoop(to: location)
        guard let loopPath else { return }
        self.loopPath = nil
        loopPath.closeSubpath()
        let loop = loopPath.copy() ?? loopPath
        let indices = loopPointCount < 3 ? IndexSet() :
            HitchLog.measure("lasou: selecție, \(document.owned.count + document.legacy.count) linii") {
                document.strokes(inside: loop)
            }
        guard !indices.isEmpty else {
            outlineLayer.isHidden = true
            return
        }
        select(indices, loop: loop)
        presentMenu()
    }

    private func select(_ indices: IndexSet, loop: CGPath) {
        selection = (indices, loop, document.inkBounds(of: indices))
        outlineLayer.path = loop
        outlineLayer.position = .zero
        outlineLayer.isHidden = false
        prepareLegacyImages()
    }

    /// Ends the selection; a drag under way is dropped where it is first.
    private func deselect() {
        drop()
        clearSelection()
    }

    /// Forgets the selection, its outline and menu, and a loop being drawn;
    /// anything lifted goes back unmoved. For a document changed under the
    /// selection too, whose indices no longer apply.
    private func clearSelection() {
        if isLifted { returnLifted() }
        drag = nil
        selection = nil
        loopPath = nil
        prepareGeneration += 1
        preparedLegacy = nil
        outlineLayer.isHidden = true
        dismissMenu()
    }

    /// The selection follows the touch from where it landed: lifted out of
    /// the page after `lassoSlop`, then moved by whole device pixels and
    /// kept on the page. Only frames move; nothing is drawn again.
    private func dragMoved(to location: CGPoint) {
        guard var drag, let selection else { return }
        let dx = location.x - drag.start.x, dy = location.y - drag.start.y
        if !isLifted {
            guard hypot(dx, dy) >= Self.lassoSlop else { return }
            pickUp()
        }
        drag.offset = clampedOffset(CGVector(dx: dx, dy: dy), for: selection.bounds)
        self.drag = drag
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The legacy layer may still show the last drop, until its underlay
        // lands: only what this drag lifted moves.
        if !liftedOwned.isEmpty {
            UIView.performWithoutAnimation {
                selectionView.frame.origin = CGPoint(x: liftOrigin.x + drag.offset.dx, y: liftOrigin.y + drag.offset.dy)
            }
        }
        if !liftedLegacy.isEmpty {
            liftedLegacyLayer.frame.origin = CGPoint(x: liftedLegacyRect.minX + drag.offset.dx,
                                                     y: liftedLegacyRect.minY + drag.offset.dy)
        }
        outlineLayer.position = CGPoint(x: drag.offset.dx, y: drag.offset.dy)
        CATransaction.commit()
    }

    /// `offset` in whole device pixels, so the lifted bitmaps keep the
    /// tiles' pixel grid, and limited so `rect` stays on the page (or goes
    /// no further off it).
    private func clampedOffset(_ offset: CGVector, for rect: CGRect) -> CGVector {
        let s = bitmapScale
        func clamp(_ d: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            let lo = ceil(min(lo, 0) * s) / s, hi = floor(max(hi, 0) * s) / s
            return min(max((d * s).rounded() / s, lo), hi)
        }
        return CGVector(dx: clamp(offset.dx, -rect.minX, bounds.width - rect.maxX),
                        dy: clamp(offset.dy, -rect.minY, bounds.height - rect.maxY))
    }

    /// `rect` grown outward to whole device pixels.
    private func pixelAligned(_ rect: CGRect) -> CGRect {
        let s = bitmapScale
        let minX = floor(rect.minX * s) / s, minY = floor(rect.minY * s) / s
        return CGRect(x: minX, y: minY, width: ceil(rect.maxX * s) / s - minX, height: ceil(rect.maxY * s) / s - minY)
    }

    /// Takes the selection out of the page: the owned strokes into
    /// `selectionView`, drawn by the same renderer on the same pixel grid,
    /// the legacy ones into `liftedLegacyLayer` over an underlay without
    /// them. The tiles skip what was lifted. One CA commit, so no frame has
    /// the ink twice or not at all.
    private func pickUp() {
        guard let selection else { return }
        HitchLog.measure("lasou: ridicare, \(selection.indices.count) linii") {
            dismissMenu()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            let (ownedSet, legacySet) = document.partition(selection.indices)
            if !ownedSet.isEmpty {
                liftedOwned = ownedSet
                var rect = CGRect.null
                for index in ownedSet { rect = rect.union(document.owned[index].bounds) }
                rect = rect.insetBy(dx: -2, dy: -2)
                invalidate(rect, creating: false)
                let frame = pixelAligned(rect)
                liftOrigin = frame.origin
                UIView.performWithoutAnimation { selectionView.frame = frame }
                selectionView.setNeedsDisplay()
            }
            if !legacySet.isEmpty {
                // Rendered here only when the drag came before the images.
                let prepared = preparedLegacy ?? Self.renderLegacy(document.legacy, lifting: legacySet, bounds: bounds,
                                                                   paper: paper, scale: underlayLayer.contentsScale)
                preparedLegacy = prepared
                liftedLegacy = legacySet
                // A render on its way has the lifted strokes in it.
                underlayGeneration += 1
                underlayLayer.contents = prepared.underlay
                liftedLegacyRect = prepared.liftedRect
                liftedLegacyLayer.contentsScale = underlayLayer.contentsScale
                liftedLegacyLayer.frame = prepared.liftedRect
                liftedLegacyLayer.contents = prepared.lifted
                liftedLegacyLayer.isHidden = false
            }
        }
    }

    /// Puts a lifted selection down where it was let go: the document moves
    /// the strokes, the tiles draw them there and `selectionView` empties,
    /// in one CA commit. The lifted legacy image stays until the underlay
    /// that has them lands. Without a drag, nothing.
    private func drop() {
        guard let drag else { return }
        self.drag = nil
        guard isLifted, let selection else { return }
        let offset = drag.offset
        HitchLog.measure("lasou: lăsare, \(selection.indices.count) linii") {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if offset == .zero {
                returnLifted()
            } else {
                liftedOwned = []
                liftedLegacy = []
                editingSelection = true
                document.translate(selection.indices, by: offset)
                editingSelection = false
                UIView.performWithoutAnimation { selectionView.frame = .zero }
            }
            var shift = CGAffineTransform(translationX: offset.dx, y: offset.dy)
            let loop = selection.loop.copy(using: &shift) ?? selection.loop
            self.selection = (selection.indices, loop, selection.bounds.offsetBy(dx: offset.dx, dy: offset.dy))
            outlineLayer.path = loop
            outlineLayer.position = .zero
        }
        lastDropTime = CACurrentMediaTime()
        // The next drag lifts the legacy strokes from where they are now.
        if offset != .zero { prepareLegacyImages() }
    }

    /// The lifted strokes back into the page unmoved: the tiles draw them
    /// again, and the underlay is rendered with them (the lifted image
    /// stays until it lands).
    private func returnLifted() {
        let ownedSet = liftedOwned, hadLegacy = !liftedLegacy.isEmpty
        liftedOwned = []
        liftedLegacy = []
        let owned = document.owned
        var rect = CGRect.null
        for index in ownedSet where index < owned.count { rect = rect.union(owned[index].bounds) }
        if !rect.isNull { invalidate(rect.insetBy(dx: -2, dy: -2), creating: false) }
        UIView.performWithoutAnimation { selectionView.frame = .zero }
        if hadLegacy { refreshUnderlay() }
    }

    private func hideLiftedLegacy() {
        liftedLegacyLayer.isHidden = true
        liftedLegacyLayer.contents = nil
    }

    /// Renders, off the main thread, what a drag of the selection's legacy
    /// strokes shows: the underlay without them, and them alone.
    private func prepareLegacyImages() {
        prepareGeneration += 1
        preparedLegacy = nil
        guard isResident, let selection else { return }
        let legacySet = document.partition(selection.indices).legacy
        guard !legacySet.isEmpty else { return }
        let generation = prepareGeneration
        let legacy = document.legacy, rect = bounds, paper = paper, scale = underlayLayer.contentsScale
        Task { @MainActor [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) {
                InkSurfaceView.renderLegacy(legacy, lifting: legacySet, bounds: rect, paper: paper, scale: scale)
            }.value
            guard let self, self.prepareGeneration == generation else { return }
            self.preparedLegacy = prepared
        }
    }

    /// `legacy` without the strokes at `indices` over the page's `bounds`,
    /// and those strokes alone over their own rect, in whole points so its
    /// pixels sit on the underlay's.
    private nonisolated static func renderLegacy(_ legacy: [PKStroke], lifting indices: IndexSet, bounds: CGRect,
                                                 paper: PaperColor, scale: CGFloat) -> LiftedLegacy {
        var rest: [PKStroke] = [], lifted: [PKStroke] = []
        for (index, stroke) in legacy.enumerated() {
            if indices.contains(index) { lifted.append(stroke) } else { rest.append(stroke) }
        }
        let rect = PKDrawing(strokes: lifted).bounds.insetBy(dx: -2, dy: -2).integral
        let underlay = rest.isEmpty ? nil
            : InkRenderer.underlayImage(strokes: rest, bounds: bounds, paper: paper, scale: scale)?.cgImage
        return LiftedLegacy(underlay: underlay,
                            lifted: InkRenderer.underlayImage(strokes: lifted, bounds: rect, paper: paper,
                                                              scale: scale)?.cgImage,
                            liftedRect: rect)
    }

    /// `CGImage` is not Sendable; the prepared images cross in this.
    private struct LiftedLegacy: @unchecked Sendable {
        let underlay: CGImage?
        let lifted: CGImage?
        let liftedRect: CGRect
    }

    @objc private func selectionPanned(_ pan: UIPanGestureRecognizer) {
        let location = pan.location(in: self)
        switch pan.state {
        case .began:
            // The pan begins some points away from where the finger landed.
            let moved = pan.translation(in: self)
            drag = (CGPoint(x: location.x - moved.x, y: location.y - moved.y), .zero)
            dragMoved(to: location)
        case .changed:
            dragMoved(to: location)
        case .ended, .cancelled, .failed:
            drop()
        default:
            break
        }
    }

    @objc private func selectionTapped(_ tap: UITapGestureRecognizer) {
        guard let selection else { return }
        if selection.loop.contains(tap.location(in: self), using: .winding) {
            toggleMenu()
        } else {
            deselect()
        }
    }

    // MARK: Edit menu

    private func toggleMenu() {
        if menuVisible || CACurrentMediaTime() - lastMenuDismissal < 0.3 { dismissMenu() } else { presentMenu() }
    }

    /// Above the selection, pointing down at it.
    private func presentMenu() {
        guard let selection else { return }
        let configuration = UIEditMenuConfiguration(identifier: nil,
                                                    sourcePoint: CGPoint(x: selection.bounds.midX, y: selection.bounds.minY))
        configuration.preferredArrowDirection = .down
        editMenu.presentEditMenu(with: configuration)
    }

    private func dismissMenu() {
        guard menuVisible else { return }
        editMenu.dismissMenu()
    }

    /// The strokes as PencilKit data, for this app and others, and as a
    /// picture in their stored (white-paper) colours.
    private func copySelection() {
        guard let selection else { return }
        HitchLog.measure("lasou: copiere, \(selection.indices.count) linii") {
            let strokes = document.drawing.strokes
            let drawing = PKDrawing(strokes: selection.indices.map { strokes[$0] })
            var png: Data?
            let scale = traitCollection.displayScale
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                png = drawing.image(from: selection.bounds, scale: scale).pngData()
            }
            var item: [String: Any] = [PKAppleDrawingTypeIdentifier as String: drawing.dataRepresentation()]
            if let png { item[UTType.png.identifier] = png }
            UIPasteboard.general.setItems([item])
        }
    }

    private func cutSelection() {
        copySelection()
        deleteSelection()
    }

    private func deleteSelection() {
        guard let selection else { return }
        // The underlay without the selection is ready: shown now, not when
        // the render after the removal lands.
        if let prepared = preparedLegacy {
            underlayLayer.contents = prepared.underlay
        }
        editingSelection = true
        document.remove(selection.indices)
        editingSelection = false
        clearSelection()
    }

    /// The copies, a little down and right, become the selection.
    private func duplicateSelection() {
        guard let selection else { return }
        var offset = clampedOffset(CGVector(dx: 20, dy: 20), for: selection.bounds)
        // At the right or bottom edge the copy goes the other way on that
        // axis: never exactly on the original.
        if offset.dx == 0 { offset.dx = -20 }
        if offset.dy == 0 { offset.dy = -20 }
        offset = clampedOffset(offset, for: selection.bounds)
        editingSelection = true
        let copies = document.duplicate(selection.indices, offset: offset)
        editingSelection = false
        guard !copies.isEmpty else {
            clearSelection()
            return
        }
        var shift = CGAffineTransform(translationX: offset.dx, y: offset.dy)
        select(copies, loop: selection.loop.copy(using: &shift) ?? selection.loop)
    }

    /// A bitmap-backed layer: `draw(_:)` paints only the rect that was
    /// invalidated, the rest of the backing store stays.
    private final class DrawingView: UIView {
        var drawHandler: ((CGRect, CGContext) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            contentMode = .redraw
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func draw(_ rect: CGRect) {
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            drawHandler?(rect, ctx)
        }
    }
}

extension InkSurfaceView: UIGestureRecognizerDelegate {
    /// The finger's pan only on the selection; its tap whenever there is one
    /// (on it, the menu; elsewhere, deselect).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let selection, drag == nil else { return false }
        if gestureRecognizer === selectionPan {
            return selection.loop.contains(touch.location(in: self), using: .winding)
        }
        return gestureRecognizer === selectionTap
    }

    /// The page and the pager scroll only once the selection's pan failed.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === selectionPan, other is UIPanGestureRecognizer,
              let scroll = other.view as? UIScrollView else { return false }
        return isDescendant(of: scroll)
    }

    /// The tap only watches: the page's own taps (a box, a deselect) still
    /// happen.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === selectionTap
    }
}

extension InkSurfaceView: UIEditMenuInteractionDelegate {
    /// Only the selection's actions: the system's would act on nothing here.
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: [
            UIAction(title: "Taie") { [weak self] _ in self?.cutSelection() },
            UIAction(title: "Copiază") { [weak self] _ in self?.copySelection() },
            UIAction(title: "Duplică") { [weak self] _ in self?.duplicateSelection() },
            UIAction(title: "Șterge") { [weak self] _ in self?.deleteSelection() },
        ])
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        selection?.bounds ?? .null
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willPresentMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        menuVisible = true
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        menuVisible = false
        lastMenuDismissal = CACurrentMediaTime()
    }
}

// MARK: - SwiftUI wrapper

/// Loads a page's drawing into the surface, applies the current tool and
/// persists changes (debounced). On iPad the surface sits above the page's
/// text, checklists and photos, so the Pencil writes over them; the finger
/// goes through to whatever is underneath.
struct InkSurface: UIViewRepresentable {
    let page: JournalPage
    var proxy: CanvasProxy
    var isActive: Bool
    var paper: PaperColor = .white
    /// The notebook's colour: the lasso's outline.
    var accent: UIColor = .systemBlue
    /// iPad: the Pencil draws over the page's boxes. Off on iPhone, where the
    /// finger must always reach the page and nothing draws.
    var isPencilDevice = false
    /// The selected page and its neighbours; the others keep no bitmaps.
    var isResident: Bool
    var renderScale: CGFloat = 1
    var mode: InkSurfaceView.Mode
    /// Apple Pencil Pro squeeze.
    var onSqueeze: () -> Void = {}
    /// Apple Pencil double-tap.
    var onDoubleTap: () -> Void = {}
    /// Any tool starts on the page (pen, highlighter, eraser).
    var onInkBegan: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(page: page, proxy: proxy, onSqueeze: onSqueeze, onDoubleTap: onDoubleTap)
    }

    func makeUIView(context: Context) -> InkSurfaceView {
        let surface = InkSurfaceView()

        // Apple Pencil (Pro) interactions: squeeze / double-tap.
        let pencil = UIPencilInteraction()
        pencil.delegate = context.coordinator
        surface.addInteraction(pencil)

        context.coordinator.surface = surface
        if let drawing = try? PKDrawing(data: page.drawingData) {
            context.coordinator.show(drawing, on: surface)
        }
        context.coordinator.lastAppliedDrawingData = page.drawingData
        surface.onDocumentChange = { [weak coordinator = context.coordinator] in
            coordinator?.drawingDidChange()
        }
        applyInput(to: surface)

        if isActive { proxy.surface = surface }
        return surface
    }

    func updateUIView(_ surface: InkSurfaceView, context: Context) {
        HitchLog.note("updateUIView, activă \(isActive)")
        applyInput(to: surface)
        context.coordinator.onSqueeze = onSqueeze
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.applyRemoteDrawingIfNeeded(from: page.drawingData)
        if isActive { proxy.surface = surface }
    }

    private func applyInput(to surface: InkSurfaceView) {
        surface.mode = mode
        surface.paper = paper
        surface.accent = accent
        surface.isActive = isActive
        surface.isPencilDevice = isPencilDevice
        surface.isResident = isResident
        surface.renderScale = renderScale
        surface.onInkBegan = onInkBegan
    }

    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        let page: JournalPage
        let proxy: CanvasProxy
        var onSqueeze: () -> Void
        var onDoubleTap: () -> Void
        weak var surface: InkSurfaceView?
        var lastAppliedDrawingData = Data()
        private var saveTask: Task<Void, Never>?
        /// Ink changed since the last store: a flush with nothing pending
        /// would serialize the whole page just to find it equal.
        private var pendingSave = false
        private var isApplyingRemoteDrawing = false

        init(page: JournalPage,
             proxy: CanvasProxy,
             onSqueeze: @escaping () -> Void,
             onDoubleTap: @escaping () -> Void) {
            self.page = page
            self.proxy = proxy
            self.onSqueeze = onSqueeze
            self.onDoubleTap = onDoubleTap
        }

        func applyRemoteDrawingIfNeeded(from data: Data) {
            guard data != lastAppliedDrawingData,
                  saveTask == nil,
                  let surface,
                  let drawing = try? PKDrawing(data: data) else { return }
            show(drawing, on: surface)
            lastAppliedDrawingData = data
        }

        /// Puts ink on the surface that nobody drew here (the stored page, or
        /// a change from the other device). The document reports it as a
        /// change; saving that would send the same ink back to iCloud, and
        /// the two devices kept bouncing a page between them.
        func show(_ drawing: PKDrawing, on surface: InkSurfaceView) {
            isApplyingRemoteDrawing = true
            defer { isApplyingRemoteDrawing = false }
            surface.document.replace(with: drawing)
        }

        // MARK: UIPencilInteractionDelegate

        func pencilInteraction(_ interaction: UIPencilInteraction,
                               didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            if squeeze.phase == .ended {
                Task { @MainActor in self.onSqueeze() }
            }
        }

        func pencilInteraction(_ interaction: UIPencilInteraction,
                               didReceiveTap tap: UIPencilInteraction.Tap) {
            Task { @MainActor in self.onDoubleTap() }
        }

        // MARK: Save

        func drawingDidChange() {
            guard !isApplyingRemoteDrawing, let surface else { return }
            let size = surface.bounds.size
            pendingSave = true
            // Persist on demand by reading the *live* document — serializing
            // only when it actually runs (debounce or flush), not on every change.
            // The flush is synchronous: its callers rely on the data being
            // stored when it returns.
            proxy.flushPendingSave = { [weak self, weak surface] in
                guard let self, let surface, pendingSave else { return }
                let data = HitchLog.measure("flush: serializare") { surface.document.drawing.dataRepresentation() }
                store(data, size: size)
                saveTask?.cancel()
                saveTask = nil
            }
            saveTask?.cancel()
            saveTask = Task { @MainActor [weak self, weak surface] in
                // After a real pause, not between two words: each save sends the
                // page's whole ink to iCloud, and too many in a row get throttled.
                // Leaving the page or the app saves right away.
                try? await Task.sleep(for: .milliseconds(1500))
                if Task.isCancelled { return }
                guard let self, let surface else { return }
                // Serializing a full page takes tens of milliseconds, at every
                // pause of writing: off the main thread. A change made meanwhile
                // cancelled this task, so the stale data is dropped here and the
                // new debounce serializes again.
                let drawing = surface.document.drawing
                let data = await Task.detached(priority: .utility) { drawing.dataRepresentation() }.value
                if Task.isCancelled { return }
                store(data, size: size)
                saveTask = nil
            }
        }

        /// Writes the ink to the page, unless it is the same as stored
        /// (nothing to save or send) or the page is gone meanwhile.
        private func store(_ data: Data, size: CGSize) {
            pendingSave = false
            guard page.modelContext != nil, data != lastAppliedDrawingData else { return }
            HitchLog.measure("store, \(data.count / 1024) KB") { storeStep(data, size: size) }
        }

        private func storeStep(_ data: Data, size: CGSize) {
            page.drawingData = data
            if size.width > 0, size.height > 0 {
                page.canvasWidth = Double(size.width)
                page.canvasHeight = Double(size.height)
            }
            page.updatedAt = .now
            lastAppliedDrawingData = data
            try? page.modelContext?.save()
            SyncLog.saved("cerneală", bytes: data.count)
        }
    }
}
