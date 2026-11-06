//
//  ToolbarDock.swift
//  MyAgenda
//
//  The pen toolbar's bottom layer. It is hidden while text or a checklist is
//  being edited (the editing bar above the keyboard takes over), so it never
//  has to travel with the keyboard: UIKit keeps it on the bottom safe area and
//  nothing moves it. Following the keyboard threw it up and down on the way out.
//

import SwiftUI
import UIKit

/// The on-screen shapes of the docked controls, reported by the content, so
/// touches anywhere else fall through to the page (Pencil included).
final class DockHitRegions {
    var rects: [String: CGRect] = [:]
    func contains(_ point: CGPoint) -> Bool { rects.values.contains { $0.contains(point) } }
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

/// Hosts `content` in UIKit, its bottom pinned to the safe area.
/// Place it full screen (ignoring safe areas): it handles them itself. Only
/// the regions the content reports take touches; everything else falls
/// through.
struct ToolbarDock<Content: View>: UIViewRepresentable {
    var regions: DockHitRegions
    var content: Content

    init(regions: DockHitRegions, @ViewBuilder content: () -> Content) {
        self.regions = regions
        self.content = content()
    }

    func makeCoordinator() -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.sizingOptions = [.intrinsicContentSize]
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
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosted.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor)
        ])
        return container
    }

    func updateUIView(_ container: ToolbarDockView, context: Context) {
        context.coordinator.rootView = content
        container.regions = regions
    }
}

/// The view behind ToolbarDock: only the reported regions take touches.
final class ToolbarDockView: UIView {
    weak var hosted: UIView?
    weak var host: UIViewController?
    var regions: DockHitRegions?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hosted, let regions,
              regions.contains(convert(point, to: hosted)) else { return nil }
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
    /// iPad: width of the open tags panel, kept clear on the left.
    var leadingInset: CGFloat = 0
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
    /// How far it can still slide to the right edge, measured at rest.
    @State private var slack: CGFloat = .infinity
    /// Tags each hide, so an older completion can't finish a newer one early.
    @State private var hideID = 0

    /// Gap between the bar and the keyboard / home indicator.
    private static let gap: CGFloat = 8

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            ZStack(alignment: .bottom) {
                if !gone && showsToolbar {
                    PenToolbar(pen: pen, proxy: proxy, showsDrawingTools: !isPhone,
                               compact: leadingInset > 0,
                               onAddText: onAddText, onAddChecklist: onAddChecklist,
                               onAddPhoto: onAddPhoto, onAddPage: onAddPage, onTimer: onTimer)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .glassEffectTransition(.identity)
                        // Ensure Pencil taps on the bar don't fall through to the canvas.
                        .contentShape(.capsule)
                        .dockHitRegion("toolbar", in: regions)
                        .padding(.bottom, Self.gap)
                        // Room left to the edge, so releasing a clamped drag never
                        // moves the capsule back to the left.
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            guard let dock = proxy.bounds(of: .named(ToolbarDockSpace.name)) else { return .infinity }
                            return dock.maxX - proxy.frame(in: .named(ToolbarDockSpace.name)).maxX
                        } action: {
                            if dragX == 0 && !docked { slack = $0 }
                        }
                        // Offset, alignment and scale change in one transaction, so
                        // the net position is a single curve from wherever the
                        // capsule was released into the handle.
                        .scaleEffect(docked ? 0.08 : 1, anchor: .trailing)
                        .offset(x: docked ? 48 : dragX)
                        .gesture(
                            DragGesture()
                                .onChanged { dragX = min(max(0, $0.translation.width), slack) }  // rightward only
                                .onEnded { value in
                                    if value.translation.width > 90 {
                                        hide()
                                    } else {
                                        withAnimation(NotebookPagesView.liquid) { dragX = 0 }
                                    }
                                }
                        )
                        .frame(maxWidth: .infinity, alignment: docked ? .trailing : .center)
                        // Only for `showsToolbar` (iPhone): hiding is animated by hand.
                        .transition(NotebookPagesView.drain)
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
                if docked {
                    reopenHandle
                        .dockHitRegion("handle", in: regions)
                        .padding(.bottom, Self.gap + 8)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.scale(scale: 0.4, anchor: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            // Shifted inside the hosted content, so the hit regions move with it.
            .padding(.leading, leadingInset)
            // The host doesn't inherit the outer transaction.
            .animation(.snappy(duration: 0.28), value: leadingInset)
        }
        // Fixed height, so the hosting view never resizes mid-flow and clips
        // the pills while they drain or pour.
        .frame(height: 96, alignment: .bottom)
        .coordinateSpace(.named(ToolbarDockSpace.name))
        .animation(NotebookPagesView.liquid, value: showsToolbar)
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

    /// Small tab on the right edge that pulls the toolbar back (Apple Notes style).
    private var reopenHandle: some View {
        Button { toolbarHidden = false } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 30, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .glassEffectTransition(.identity)
    }
}
