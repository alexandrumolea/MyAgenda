//
//  ToolbarDock.swift
//  MyAgenda
//
//  The pen toolbar's layer: at the bottom, or on the side it was moved to
//  (iPad). It is hidden while text or a checklist is being edited (the editing
//  bar above the keyboard takes over), so it never has to travel with the
//  keyboard: UIKit keeps it on the bottom safe area and nothing moves it.
//  Following the keyboard threw it up and down on the way out.
//

import SwiftUI
import UIKit

/// The on-screen shapes of the docked controls, reported by the content, so
/// touches anywhere else fall through to the page (Pencil included).
final class DockHitRegions {
    var rects: [String: CGRect] = [:]
    func contains(_ point: CGPoint, except skipped: String? = nil) -> Bool {
        rects.contains { $0.key != skipped && $0.value.contains(point) }
    }
}

extension View {
    /// Reports this view's frame as a touchable region of the dock.
    func dockHitRegion(_ id: String, in regions: DockHitRegions) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ToolbarDockSpace.name)) } action: {
            regions.rects[id] = $0
        }
        .onDisappear { regions.rects[id] = nil }
    }
}

enum ToolbarDockSpace { nonisolated static let name = "toolbarDock" }

/// Where the pen toolbar is docked (iPad). Never the top: that's the bar row.
enum ToolbarEdge: String { case bottom, left, right }

/// Hold-to-move state, shared by the dock's long press (UIKit) and the layer
/// that draws the bar. iPad only.
@Observable
final class ToolbarMove {
    var isLifted = false
    /// Where the finger has taken the bar since the lift.
    var translation: CGSize = .zero
    /// Bumped on every release; the layer snaps the bar then.
    var releaseCount = 0
    /// Where the bar's centre was let go, in the layer's coordinates. Nil
    /// when the hold was cancelled.
    var releaseLocation: CGPoint?
    /// The edge in effect, written by the layer.
    var edge: ToolbarEdge = .bottom
    /// Sides: how far the current swipe has taken the bar, along x (the
    /// dock's pan; see ToolbarDockView).
    var hideDrag: CGFloat = 0
    /// Bumped when that swipe ends; the layer hides the bar or springs it back.
    var hideReleaseCount = 0
    /// Where the swipe would have ended, by its speed. Nil when cancelled.
    @ObservationIgnored var hideFlick: CGFloat?
    /// The current touch lifted or swiped the bar: the button under it and
    /// the hide-drag must not act on it.
    @ObservationIgnored var didLift = false
    /// False while the window is too small for the side docks.
    @ObservationIgnored var isEnabled = true
}

/// Hosts `content` in UIKit, from the top of the screen down to the bottom
/// safe area. Place it full screen (ignoring safe areas): it handles them
/// itself. Only the regions the content reports take touches; everything else
/// falls through.
struct ToolbarDock<Content: View>: UIViewRepresentable {
    var regions: DockHitRegions
    /// iPad: holding the bar lifts it (see ToolbarMove). Nil: it stays put.
    var move: ToolbarMove?
    /// iPad: a touch outside the open squeeze bar closes it.
    var squeeze: SqueezeBarState?
    var content: Content

    init(regions: DockHitRegions, move: ToolbarMove? = nil, squeeze: SqueezeBarState? = nil,
         @ViewBuilder content: () -> Content) {
        self.regions = regions
        self.move = move
        self.squeeze = squeeze
        self.content = content()
    }

    func makeCoordinator() -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.sizingOptions = []
        return host
    }

    func makeUIView(context: Context) -> ToolbarDockView {
        let container = ToolbarDockView()
        container.backgroundColor = .clear
        let hosted: UIView = context.coordinator.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosted)
        container.hosted = hosted
        container.host = context.coordinator
        container.regions = regions
        container.move = move
        container.squeeze = squeeze
        NSLayoutConstraint.activate([
            hosted.topAnchor.constraint(equalTo: container.topAnchor),
            hosted.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosted.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor)
        ])
        if move != nil {
            // Finger only: the Pencil never moves the bar. Taking the touches
            // once it lifts keeps the held button from firing.
            let press = UILongPressGestureRecognizer(target: container, action: #selector(ToolbarDockView.handleLift(_:)))
            press.minimumPressDuration = 0.4
            press.allowableMovement = 10
            press.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            press.cancelsTouchesInView = true
            press.delegate = container
            container.addGestureRecognizer(press)
            container.liftPress = press
            // Sides: a swipe toward the edge hides the bar. Short and across
            // it, the swipe stays on the button it started on, and SwiftUI's
            // drag lost to that button; taking the touches keeps it from firing.
            let pan = DockSwipeRecognizer(target: container, action: #selector(ToolbarDockView.handleHide(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = true
            pan.delegate = container
            container.addGestureRecognizer(pan)
            container.hidePan = pan
        }
        return container
    }

    func updateUIView(_ container: ToolbarDockView, context: Context) {
        context.coordinator.rootView = content
        container.regions = regions
        container.move = move
        container.squeeze = squeeze
    }
}

/// The view behind ToolbarDock: only the reported regions take touches.
final class ToolbarDockView: UIView, UIGestureRecognizerDelegate {
    weak var hosted: UIView?
    weak var host: UIViewController?
    var regions: DockHitRegions?
    var move: ToolbarMove?
    var squeeze: SqueezeBarState?
    weak var liftPress: UILongPressGestureRecognizer?
    weak var hidePan: DockSwipeRecognizer?
    /// Where the finger lifted the bar; nil when nothing is lifted.
    private var liftStart: CGPoint?
    /// From the bar's centre to the finger, at the lift: the snap goes by
    /// where the bar is, not where it was held.
    private var grab: CGSize = .zero
    private var lastSize: CGSize = .zero

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // A new touch: an earlier lift no longer blocks the buttons. Not a
        // second finger mid-lift or mid-swipe, though: the first one still
        // must not act.
        if event?.type == .touches, liftStart == nil, !isActive(hidePan) { move?.didLift = false }
        guard let hosted, let regions else { return nil }
        let p = convert(point, to: hosted)
        // The squeeze bar counts only while open: it is still fading out
        // after it closed.
        let onSqueezeBar = squeeze?.isOpen == true
            && regions.rects[SqueezeBarState.region]?.contains(p) == true
        // A touch anywhere else closes it and goes on as usual. Touches only:
        // the hovering Pencil hit-tests too.
        if event?.type == .touches, squeeze?.isOpen == true, !onSqueezeBar { squeeze?.close() }
        guard onSqueezeBar || regions.contains(p, except: SqueezeBarState.region) else { return nil }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    /// The hosting controller must sit in the view-controller tree, or the
    /// toolbar's popovers (ink, eraser) have nothing to present from.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, let host, host.parent == nil else { return }
        var responder: UIResponder? = next
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let parent = responder as? UIViewController else { return }
        parent.addChild(host)
        host.didMove(toParent: parent)
    }

    /// Rotation or a resize mid-lift or mid-swipe: the docks moved under the
    /// finger, so the gesture is cancelled and the bar goes back.
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            for recognizer in [liftPress, hidePan] as [UIGestureRecognizer?] where isActive(recognizer) {
                recognizer?.isEnabled = false
                recognizer?.isEnabled = true
            }
        }
        lastSize = bounds.size
    }

    private func isActive(_ recognizer: UIGestureRecognizer?) -> Bool {
        recognizer?.state == .began || recognizer?.state == .changed
    }

    @objc func handleLift(_ press: UILongPressGestureRecognizer) {
        guard let move, let hosted else { return }
        let p = press.location(in: hosted)
        switch press.state {
        case .began:
            move.didLift = true
            move.isLifted = true
            liftStart = p
            let bar = regions?.rects["toolbar"]
            grab = bar.map { CGSize(width: p.x - $0.midX, height: p.y - $0.midY) } ?? .zero
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            guard let start = liftStart else { return }
            move.translation = CGSize(width: p.x - start.x, height: p.y - start.y)
        case .ended:
            guard liftStart != nil else { return }
            liftStart = nil
            move.releaseLocation = CGPoint(x: p.x - grab.width, y: p.y - grab.height)
            move.releaseCount += 1
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .cancelled, .failed:
            guard liftStart != nil else { return }
            liftStart = nil
            move.releaseLocation = nil
            move.releaseCount += 1
        default:
            break
        }
    }

    /// The layer applies the swipe, with the same reach and thresholds as
    /// the bottom's SwiftUI drag.
    @objc func handleHide(_ pan: DockSwipeRecognizer) {
        guard let move, let hosted else { return }
        switch pan.state {
        case .began, .changed:
            move.didLift = true
            move.hideDrag = pan.location(in: self).x - pan.start.x
        case .ended:
            // Where a scroll view would coast to from this speed.
            let rate = UIScrollView.DecelerationRate.normal.rawValue
            move.hideFlick = move.hideDrag + pan.velocity(in: hosted).x / 1000 * rate / (1 - rate)
            move.hideReleaseCount += 1
        case .cancelled:
            move.hideFlick = nil
            move.hideReleaseCount += 1
        default:
            break
        }
    }

    /// Only a hold or a swipe on the bar itself acts (not on the reopen handle,
    /// nor on the open squeeze bar where it covers a side bar).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let hosted, let bar = regions?.rects["toolbar"] else { return false }
        let p = touch.location(in: hosted)
        if squeeze?.isOpen == true, regions?.rects[SqueezeBarState.region]?.contains(p) == true { return false }
        return bar.contains(p)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === liftPress {
            return move?.isEnabled == true && !isActive(hidePan)
        }
        guard gestureRecognizer === hidePan, let hidePan, let move else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        // Sides only, never mid-lift, and only across the bar toward its
        // edge: moving along it, or away from the edge, never hides it.
        guard move.edge != .bottom, liftStart == nil else { return false }
        let p = hidePan.location(in: self)
        let d = CGPoint(x: p.x - hidePan.start.x, y: p.y - hidePan.start.y)
        let towardEdge = move.edge == .left ? d.x < 0 : d.x > 0
        return towardEdge && abs(d.x) > abs(d.y)
    }

    /// SwiftUI's own recognizers (the buttons, the glass press) kept the hold
    /// and the swipe from ever starting on a button. Once one starts, the
    /// guards in the actions keep that button from firing.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === liftPress || gestureRecognizer === hidePan
    }
}

/// The dock's swipe. It waits for 10 pt of movement, as SwiftUI's drag and
/// the hold's allowance do (UIKit's pan started after 2 pt), so a tap that
/// wobbles still reaches its button.
final class DockSwipeRecognizer: UIPanGestureRecognizer {
    /// Where the finger touched down, in the dock's coordinates. The pan's
    /// own translation counts only from where it began.
    private(set) var start: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // The first finger only: a second one must not move the start.
        if let touch = touches.first, state == .possible, numberOfTouches == 0 {
            start = touch.location(in: view)
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let p = touches.first?.location(in: view),
           hypot(p.x - start.x, p.y - start.y) < 10 { return }
        super.touchesMoved(touches, with: event)
    }
}

/// Pen toolbar and its reopen handle. They share a container so their glass
/// blends: the capsule glides to the edge and drains into the handle in one
/// motion; showing pours it back out and glides it to the centre. The flow is
/// driven by local state, because `withAnimation` in the parent never reaches
/// the hosting controller.
struct BottomToolbarLayer: View {
    let pen: PenSettings
    let proxy: CanvasProxy
    let regions: DockHitRegions
    let isPhone: Bool
    /// False on iPhone while a text box is being edited.
    let showsToolbar: Bool
    /// The persisted truth; the states below stage the animation around it.
    @Binding var toolbarHidden: Bool
    /// iPad, hidden from the menu: no handle either. Left on while the bar
    /// shows again, so the handle doesn't flash as it pours back.
    @Binding var handleless: Bool
    /// iPad: width of the open tags panel, kept clear on the left.
    var leadingInset: CGFloat = 0
    /// iPad: hold-to-move (see ToolbarMove). Nil on iPhone: always the bottom.
    var move: ToolbarMove? = nil
    /// From the top of the screen to below the top bar row; the side docks
    /// stay under it.
    var topReserve: CGFloat = 0
    /// iPad: the bar the Pencil Pro's squeeze opens. Nil on iPhone.
    var squeezeBar: SqueezeBarState? = nil
    /// The screen's safe area: the host itself sees none.
    var safeArea = EdgeInsets()
    var onAddText: () -> Void
    var onAddChecklist: () -> Void
    var onAddPhoto: () -> Void
    var onAddPage: () -> Void
    var onTimer: () -> Void

    /// The capsule is drawn as a droplet inside the handle (and on its way
    /// there or back).
    @State private var docked = UserDefaults.standard.bool(forKey: "penToolbarHidden")
    /// The capsule is out of the hierarchy. Implies `docked`.
    @State private var gone = UserDefaults.standard.bool(forKey: "penToolbarHidden")
    @State private var dragX: CGFloat = 0
    /// How far it can still slide to the docked edge, measured at rest.
    @State private var slack: CGFloat = .infinity
    /// Tags each hide, so an older completion can't finish a newer one early.
    @State private var hideID = 0
    /// iPad: the dock picked by moving the bar. Kept when the window is too
    /// small for the sides, so it comes back once there is room.
    @AppStorage("penToolbarEdge") private var savedEdge: ToolbarEdge = .bottom
    @State private var containerSize: CGSize = .zero

    /// Gap between the bar and the home indicator, or the side it is docked on.
    private static let gap: CGFloat = 8
    /// Sides: how far a drag toward the edge moves the bar, as far as it
    /// drains (it already sits against the edge, so it has no slack).
    private static let sideReach: CGFloat = 48
    /// `drain` mirrored, for the left dock.
    private static let drainLeading = AnyTransition.asymmetric(
        insertion: .scale(scale: 0.2, anchor: .leading)
            .combined(with: .offset(x: -48))
            .combined(with: .opacity),
        removal: .scale(scale: 0.08, anchor: .leading)
            .combined(with: .offset(x: -48))
    )

    /// Room for the vertical bar (about 560 pt) below the top row.
    private var sidesFit: Bool {
        containerSize.width >= 500 && containerSize.height - topReserve - Self.gap >= 600
    }

    private var edge: ToolbarEdge { isPhone || !sidesFit ? .bottom : savedEdge }

    /// The edge the capsule glides to and drains into when hidden.
    private var hideAnchor: UnitPoint { edge == .left ? .leading : .trailing }

    private var stackAlignment: Alignment {
        switch edge {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    private var barGapEdge: Edge.Set {
        switch edge {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    private var barAlignment: Alignment {
        switch edge {
        case .bottom: docked ? .trailing : .center
        case .left: .leading
        case .right: .trailing
        }
    }

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            ZStack(alignment: stackAlignment) {
                if !gone && showsToolbar {
                    PenToolbar(pen: pen, proxy: proxy, showsDrawingTools: !isPhone,
                               compact: edge == .bottom && leadingInset > 0,
                               edge: edge, move: move,
                               onAddText: onAddText, onAddChecklist: onAddChecklist,
                               onAddPhoto: onAddPhoto, onAddPage: onAddPage, onTimer: onTimer)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .glassEffectTransition(.identity)
                        // Ensure Pencil taps on the bar don't fall through to the canvas.
                        .contentShape(.capsule)
                        .dockHitRegion("toolbar", in: regions)
                        // Held: follows the finger, slightly raised.
                        .offset(move?.translation ?? .zero)
                        .animation(.snappy(duration: 0.2)) {
                            $0.scaleEffect(move?.isLifted == true ? 1.06 : 1)
                        }
                        .padding(barGapEdge, Self.gap)
                        // Room left to the trailing edge (bottom), so releasing a
                        // clamped drag never moves the capsule back away from it.
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            guard let dock = proxy.bounds(of: .named(ToolbarDockSpace.name)) else { return .infinity }
                            return dock.maxX - proxy.frame(in: .named(ToolbarDockSpace.name)).maxX
                        } action: {
                            if dragX == 0 && !docked { slack = $0 }
                        }
                        // Offset, alignment and scale change in one transaction, so
                        // the net position is a single curve from wherever the
                        // capsule was released into the handle.
                        .scaleEffect(docked ? 0.08 : 1, anchor: hideAnchor)
                        .offset(x: docked ? (edge == .left ? -48 : 48) : dragX)
                        // Bottom only: on the sides the dock's pan hides it, since
                        // there the buttons won over this drag.
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    // The hold lifted the bar: that touch moves it instead.
                                    guard move?.didLift != true else { return }
                                    followHide(value.translation.width)
                                }
                                .onEnded { value in
                                    guard move?.didLift != true else { return }
                                    endHide(value.translation.width, flick: value.predictedEndTranslation.width)
                                },
                            including: edge == .bottom ? .all : .subviews
                        )
                        .frame(maxWidth: .infinity, alignment: barAlignment)
                        // Only for `showsToolbar` (iPhone): hiding is animated by hand.
                        .transition(edge == .left ? Self.drainLeading : NotebookPagesView.drain)
                        // Inserted inside the handle (see onChange): pour it out —
                        // unless it was hidden again meanwhile (iPhone, while the
                        // toolbar was off for editing), then it just leaves.
                        .onAppear {
                            dragX = 0
                            guard docked else { return }
                            if toolbarHidden {
                                gone = true
                            } else {
                                withAnimation(NotebookPagesView.liquid) { docked = false }
                            }
                        }
                        // A drag cut short (call, backgrounding) never gets onEnded.
                        .onDisappear { dragX = 0 }
                }
                if docked && !handleless {
                    reopenHandle
                        .dockHitRegion("handle", in: regions)
                        .padding(.bottom, edge == .bottom ? Self.gap + 8 : 0)
                        .frame(maxWidth: .infinity, alignment: edge == .left ? .leading : .trailing)
                        .transition(.scale(scale: 0.4, anchor: hideAnchor).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: stackAlignment)
            // Sides: centred in the height below the top row.
            .padding(.top, edge == .bottom ? 0 : topReserve)
            .padding(.bottom, edge == .bottom ? 0 : Self.gap)
            // Shifted inside the hosted content, so the hit regions move with it.
            .padding(.leading, leadingInset)
            // The host doesn't inherit the outer transaction.
            .animation(.snappy(duration: 0.28), value: leadingInset)
        }
        // Until the size is known the sides don't fit, so the first frame
        // would draw the bar at the bottom before it jumps to its side.
        .opacity(containerSize == .zero ? 0 : 1)
        // Fills the dock, so the hosting view never resizes mid-flow and clips
        // the pills while they drain or pour. Only the hit regions take touches.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Outside the container, so its glass never blends with the main bar's;
        // there whether or not the main bar is shown.
        .overlay {
            if !isPhone, let squeezeBar {
                // No bottom inset: the host already ends above the home indicator.
                SqueezeToolBar(state: squeezeBar, pen: pen, regions: regions, containerSize: containerSize,
                               bounds: EdgeInsets(top: safeArea.top, leading: max(safeArea.leading, leadingInset),
                                                  bottom: 0, trailing: safeArea.trailing),
                               onAddPhoto: onAddPhoto)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }
        .coordinateSpace(.named(ToolbarDockSpace.name))
        .animation(NotebookPagesView.liquid, value: showsToolbar)
        .onChange(of: edge, initial: true) { _, edge in move?.edge = edge }
        .onChange(of: sidesFit, initial: true) { _, fits in move?.isEnabled = fits }
        // Rotation or a resize: the bar would no longer sit by the Pencil.
        .onChange(of: containerSize) { squeezeBar?.close() }
        // Released: snaps to the nearest dock (never the top). Cancelled: back
        // to the dock it came from.
        .onChange(of: move?.releaseCount) {
            guard let move else { return }
            let target = move.releaseLocation.flatMap { p -> ToolbarEdge? in
                let distances: [(ToolbarEdge, CGFloat)] = [
                    (.left, p.x - leadingInset),
                    (.right, containerSize.width - p.x),
                    (.bottom, containerSize.height - p.y)
                ]
                return distances.min { $0.1 < $1.1 }?.0
            }
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                if let target { savedEdge = target }
                move.translation = .zero
                move.isLifted = false
            }
        }
        // Sides: the dock's swipe (see ToolbarDockView).
        .onChange(of: move?.hideDrag) { _, x in
            if let x, edge != .bottom { followHide(x) }
        }
        .onChange(of: move?.hideReleaseCount) {
            guard let move else { return }
            // A cancelled swipe springs back on any edge: a resize can bring
            // the bar to the bottom before the cancel lands.
            if let flick = move.hideFlick, edge != .bottom {
                endHide(move.hideDrag, flick: flick)
            } else {
                withAnimation(NotebookPagesView.liquid) { dragX = 0 }
            }
        }
        .onChange(of: toolbarHidden) { _, hidden in
            if hidden {
                if !gone && !docked { hide() }
            } else if gone {
                // Appears inside the handle, without animation; onAppear pours it out.
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { gone = false }
            } else {
                withAnimation(NotebookPagesView.liquid) { docked = false }
            }
        }
    }

    /// A hide-drag moves the bar toward the docked edge only.
    private func followHide(_ x: CGFloat) {
        let reach = edge == .bottom ? slack : Self.sideReach
        dragX = edge == .left ? min(max(-reach, x), 0) : min(max(0, x), reach)
    }

    /// Releasing a hide-drag hides the bar, or springs it back.
    private func endHide(_ x: CGFloat, flick: CGFloat) {
        // Sides: the bar is too close to the edge for the finger to travel
        // 90 pt, so a short drag or a flick toward it is enough.
        let hides = switch edge {
        case .bottom: x > 90
        case .left: x < -30 || flick < -90
        case .right: x > 30 || flick > 90
        }
        if hides {
            // A swipe always docks into the handle.
            handleless = false
            hide()
        } else {
            withAnimation(NotebookPagesView.liquid) { dragX = 0 }
        }
    }

    /// Glides the capsule to the edge and drains it into the handle; it leaves
    /// the hierarchy only once it is already invisible there.
    private func hide() {
        // Persisted up front, so a tap on the handle mid-flow reads as "show".
        toolbarHidden = true
        hideID += 1
        let id = hideID
        withAnimation(NotebookPagesView.liquid) {
            dragX = 0
            docked = true
        } completion: {
            // Showing interrupted the hide, or a newer hide is still draining.
            guard docked, id == hideID else { return }
            gone = true
        }
    }

    /// Small tab on the docked edge that pulls the toolbar back (Apple Notes style).
    private var reopenHandle: some View {
        Button { toolbarHidden = false } label: {
            Image(systemName: edge == .left ? "chevron.right" : "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 30, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Tools")
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .glassEffectTransition(.identity)
    }
}
