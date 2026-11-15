//
//  SqueezeToolBar.swift
//  MyAgenda
//
//  iPad, Apple Pencil Pro: squeezing opens a small glass capsule just above
//  the tip with the drawing tools and Add Photo, so the hand never travels to
//  the main toolbar. It lives in the toolbar's dock (see ToolbarDock), which
//  closes it on any touch outside it.
//

import SwiftUI

/// Whether the squeeze bar is open, and where the Pencil hovered when it was
/// squeezed. Shared by the page (squeeze), the dock (touches) and the bar.
@Observable
final class SqueezeBarState {
    var isOpen = false
    /// In the dock's coordinates (the window's); nil when the Pencil wasn't
    /// hovering.
    var hover: CGPoint?

    func toggle(at point: CGPoint?) {
        if isOpen {
            close()
        } else {
            hover = point
            isOpen = true
        }
    }

    func close() {
        if isOpen { isOpen = false }
    }

    /// The bar's hit region in the dock.
    static let region = "squeezeBar"
}

struct SqueezeToolBar: View {
    let state: SqueezeBarState
    let pen: PenSettings
    let regions: DockHitRegions
    let containerSize: CGSize
    /// Kept clear: the top safe area, the open tags panel on the left.
    let bounds: EdgeInsets
    var onAddPhoto: () -> Void

    /// Until measured, about the bar's size.
    @State private var size = CGSize(width: 260, height: 54)
    /// The slot under the hovering Pencil; nil when it hovers elsewhere.
    @State private var hovered: Int?
    /// Clears `hovered` a moment after the hover ends.
    @State private var hoverEnd: Task<Void, Never>?

    private static let margin: CGFloat = 12
    /// From the Pencil's tip to the bar's edge.
    private static let gap: CGFloat = 20
    /// One slot per button, edge to edge, so a tap in a gap still reaches
    /// the nearest one; the ends add `inset`.
    private static let slot: CGFloat = 48
    private static let inset: CGFloat = 10
    /// How far past its slot's edge the Pencil may drift before the circle
    /// moves on: the hover point shakes by a point or two, and on a hard edge
    /// the circle flickered between two slots.
    private static let hold: CGFloat = 8
    private static let tools: [(kind: PenSettings.ToolKind, system: String, label: String)] = [
        (.pen, "applepencil.tip", "Pen"),
        (.highlighter, "highlighter", "Highlighter"),
        (.eraser, "eraser.fill", "Eraser"),
        (.lasso, "lasso", "Lasso")
    ]
    private static var photoSlot: Int { tools.count }

    /// The circled slot: the one under the Pencil, else the current tool.
    private var lit: Int? { hovered ?? Self.tools.firstIndex { $0.kind == pen.tool } }

    var body: some View {
        ZStack {
            if state.isOpen {
                capsule
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        // Local: the parent's withAnimation never reaches the hosting controller.
        // Inside the position, so a new spot is taken at once, not flown to.
        .animation(.snappy(duration: 0.2), value: state.isOpen)
        // From the container, which never leaves: a capsule still fading out
        // would drop the region of the one that just opened. The dock counts
        // it only while open.
        .dockHitRegion(SqueezeBarState.region, in: regions)
        .position(center)
        .onChange(of: state.isOpen) {
            hoverEnd?.cancel()
            hovered = nil
        }
    }

    private var capsule: some View {
        HStack(spacing: 0) {
            ForEach(Self.tools.indices, id: \.self) { index in
                toolButton(index)
            }
            Button {
                pick(Self.photoSlot)
            } label: {
                slotLabel(Self.photoSlot) {
                    ToolIcon(system: "photo", isSelected: lit == Self.photoSlot, fill: false)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add Photo")
        }
        // One circle that slides to the lit slot, under the icons.
        .background(alignment: .leading) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 36, height: 36)
                .offset(x: Self.inset + Self.slot * CGFloat(lit ?? 0) + (Self.slot - 36) / 2)
                .opacity(lit == nil ? 0 : 1)
        }
        // The icons' colours follow the circle on the same curve. No bounce:
        // a spring that overshoots read as the circle wobbling.
        .animation(.smooth(duration: 0.28), value: lit)
        .glassEffect(.regular.interactive(), in: .capsule)
        // Pencil taps between the buttons stay on the bar, as on the main one.
        .contentShape(.capsule)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                hoverEnd?.cancel()
                // The circled slot stays until the Pencil is `hold` past its
                // edge; the tap goes to it (see `pick`), not to the button
                // under the tip.
                if let current = hovered {
                    let start = Self.inset + Self.slot * CGFloat(current)
                    if p.x > start - Self.hold && p.x < start + Self.slot + Self.hold { return }
                }
                let index = Int((p.x - Self.inset) / Self.slot)
                hovered = min(max(index, 0), Self.photoSlot)
            case .ended:
                // Hover ends as the tip touches down: cleared at once, the
                // circle would slide back before the tap lands.
                hoverEnd?.cancel()
                hoverEnd = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { return }
                    hovered = nil
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
    }

    /// A slot's label: the whole slot takes the tap, the ends' insets too.
    private func slotLabel(_ index: Int, @ViewBuilder icon: () -> some View) -> some View {
        icon()
            .frame(width: Self.slot, height: 54)
            .padding(.leading, index == 0 ? Self.inset : 0)
            .padding(.trailing, index == Self.photoSlot ? Self.inset : 0)
            .contentShape(Rectangle())
    }

    private func toolButton(_ index: Int) -> some View {
        let tool = Self.tools[index]
        let isSelected = pen.tool == tool.kind
        let showsDot = tool.kind == .pen || tool.kind == .highlighter
        return Button {
            pick(index)
        } label: {
            slotLabel(index) {
                ToolIcon(system: tool.system, isSelected: lit == index,
                         dot: showsDot ? pen.color(for: tool.kind) : nil, fill: false)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.label)
        // The real tool, not the one the Pencil hovers over.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A tap on slot `index`. With the Pencil it picks the circled slot, which
    /// near an edge can be the neighbour of the button under the tip: what the
    /// circle shows is what the tap chooses. A finger has no hover, so its
    /// own button.
    private func pick(_ index: Int) {
        let chosen = hovered ?? index
        state.close()
        if chosen == Self.photoSlot {
            onAddPhoto()
        } else if pen.tool != Self.tools[chosen].kind {
            pen.tool = Self.tools[chosen].kind
        }
    }

    /// Just above the tip, or below it when there is no room; kept inside the
    /// bounds. Without a hover point, the middle of the screen.
    private var center: CGPoint {
        let m = Self.margin, g = Self.gap
        let w = size.width, h = size.height
        let minX = bounds.leading + m, maxX = containerSize.width - bounds.trailing - m
        let minY = bounds.top + m, maxY = containerSize.height - bounds.bottom - m
        guard let p = state.hover else {
            return CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        }
        var y = p.y - g - h / 2
        if y - h / 2 < minY { y = p.y + g + h / 2 }
        return CGPoint(x: clamp(p.x, minX + w / 2, maxX - w / 2),
                       y: clamp(y, minY + h / 2, maxY - h / 2))
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), high)
    }
}
