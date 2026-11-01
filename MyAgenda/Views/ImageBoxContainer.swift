//
//  ImageBoxContainer.swift
//  MyAgenda
//
//  Renders a photo on the page. Tap selects it; selected, it can be moved,
//  resized (proportionally), copied, deleted and cropped. Selection lives in
//  the page, so a tap anywhere else clears it. `scale` is how much the page is
//  shrunk on screen (iPhone): finger distances are divided by it and the
//  controls counter-scaled, so they keep their real size.
//

import SwiftUI

struct ImageBoxContainer: View {
    let box: ImageBox
    let pageSize: CGSize
    var scale: CGFloat = 1
    var isSelected: Bool
    var onSelect: (Bool) -> Void
    var onMove: (Double, Double) -> Void
    var onResize: (Double) -> Void
    var onDelete: () -> Void
    var onCrop: (CGRect) -> Void
    var onCropModeChange: (Bool) -> Void

    @GestureState private var dragOffset: CGSize = .zero
    @State private var resizeDelta: CGFloat = 0
    /// Crop being edited (unit coordinates over the original); nil = not cropping.
    @State private var cropDraft: CGRect?
    /// Draft when the current crop drag started.
    @State private var cropStart: CGRect?

    private static let imageCache = NSCache<NSString, UIImage>()

    private var originalImage: UIImage? {
        let key = box.id.uuidString as NSString
        if let cached = Self.imageCache.object(forKey: key) { return cached }
        guard let img = UIImage(data: box.imageData) else { return nil }
        Self.imageCache.setObject(img, forKey: key)
        return img
    }

    private var visibleImage: UIImage? {
        guard let originalImage else { return nil }
        let crop = box.cropRect
        let key = "\(box.id.uuidString)-\(crop.minX)-\(crop.minY)-\(crop.width)-\(crop.height)" as NSString
        if let cached = Self.imageCache.object(forKey: key) { return cached }
        let part = ImageBox.cropped(originalImage, to: crop)
        Self.imageCache.setObject(part, forKey: key)
        return part
    }

    var body: some View {
        let baseX = box.x * pageSize.width
        // Anchor Y to the page WIDTH (a stable unit) so boxes don't slide down
        // when the page grows taller on scroll.
        let baseY = box.y * pageSize.width

        Group {
            if let draft = cropDraft {
                cropEditor(draft: draft, baseX: baseX, baseY: baseY)
            } else {
                photo(baseX: baseX, baseY: baseY)
            }
        }
        .onChange(of: isSelected) { _, selected in
            if !selected && cropDraft != nil { endCrop() }
        }
    }

    // MARK: - Photo

    private func photo(baseX: CGFloat, baseY: CGFloat) -> some View {
        let maxW = max(60, pageSize.width * (1 - box.x) - 4)
        let width = min(max(60, box.widthFraction * pageSize.width + resizeDelta), maxW)
        let height = width * CGFloat(box.aspectRatio)

        return image
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2 / scale)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected { resizeHandle.offset(x: 12 / scale, y: 12 / scale) }
            }
            .overlay(alignment: .topTrailing) {
                if isSelected { deleteButton.offset(x: 8 / scale, y: -8 / scale) }
            }
            .overlay(alignment: .topLeading) {
                if isSelected { copyButton.offset(x: -8 / scale, y: -8 / scale) }
            }
            .overlay(alignment: .bottomLeading) {
                if isSelected { cropButton.offset(x: -8 / scale, y: 8 / scale) }
            }
            .offset(x: baseX + dragOffset.width, y: baseY + dragOffset.height)
            // Move only when selected (tap to select first).
            .modifier(MoveModifier(enabled: isSelected,
                                   gesture: moveGesture(baseX: baseX, baseY: baseY)))
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) { onSelect(!isSelected) }
            }
    }

    @ViewBuilder private var image: some View {
        if let visibleImage {
            Image(uiImage: visibleImage).resizable().scaledToFill()
        } else {
            Color.gray.opacity(0.2)
        }
    }

    private func control(_ system: String, tint: Color, background: Color,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(background))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(1 / scale)
    }

    private var deleteButton: some View {
        control("xmark", tint: .white, background: .red) { onDelete() }
    }

    private var copyButton: some View {
        control("doc.on.doc.fill", tint: .white, background: .accentColor) {
            if let visibleImage { UIPasteboard.general.image = visibleImage }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private var cropButton: some View {
        control("crop", tint: .white, background: .accentColor) {
            cropDraft = box.cropRect
            onCropModeChange(true)
        }
    }

    private func moveGesture(baseX: CGFloat, baseY: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($dragOffset) { value, state, _ in
                state = CGSize(width: value.translation.width / scale,
                               height: value.translation.height / scale)
            }
            .onEnded { value in
                let nx = (baseX + value.translation.width / scale) / pageSize.width
                let ny = (baseY + value.translation.height / scale) / pageSize.width
                let maxY = Double((pageSize.height - 20) / pageSize.width)
                onMove(min(max(Double(nx), 0), 0.97), min(max(Double(ny), 0), maxY))
                withAnimation(.snappy(duration: 0.2)) { onSelect(false) }
            }
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
            .font(.system(size: 26))
            .foregroundStyle(Color.accentColor)
            .background(Circle().fill(.white))
            .scaleEffect(1 / scale)
            .gesture(
                // Global space so the growing handle doesn't feed back into the
                // gesture. @State (not @GestureState) so the commit + reset happen
                // atomically → keeps the exact size, no flicker.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in resizeDelta = value.translation.width / scale }
                    .onEnded { value in
                        let base = box.widthFraction * pageSize.width
                        let maxFraction = max(0.1, 1 - box.x - 0.02)
                        let fraction = (base + value.translation.width / scale) / pageSize.width
                        onResize(min(max(Double(fraction), 0.05), maxFraction))
                        resizeDelta = 0
                        onSelect(false)
                    }
            )
    }

    // MARK: - Crop

    /// The whole original in place, the part outside the crop dimmed. Drag the
    /// frame to move it, a corner to resize it.
    private func cropEditor(draft: CGRect, baseX: CGFloat, baseY: CGFloat) -> some View {
        let fullWidth = CGFloat(box.originalWidthFraction) * pageSize.width
        let fullHeight = fullWidth * CGFloat(box.originalAspectRatio)
        let originX = baseX - box.cropX * fullWidth
        let originY = baseY - box.cropY * fullHeight
        let frame = CGRect(x: draft.minX * fullWidth, y: draft.minY * fullHeight,
                           width: draft.width * fullWidth, height: draft.height * fullHeight)

        return ZStack(alignment: .topLeading) {
            if let originalImage {
                Image(uiImage: originalImage).resizable()
                    .frame(width: fullWidth, height: fullHeight)
            }
            // Dim: everything except the crop frame.
            Path { path in
                path.addRect(CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight))
                path.addRect(frame)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(.white, lineWidth: 2 / scale)
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .gesture(cropGesture(fullWidth: fullWidth, fullHeight: fullHeight) { start, dx, dy in
                    CGRect(x: min(max(start.minX + dx, 0), 1 - start.width),
                           y: min(max(start.minY + dy, 0), 1 - start.height),
                           width: start.width, height: start.height)
                })

            cropCorner(at: CGPoint(x: frame.minX, y: frame.minY), fullWidth: fullWidth, fullHeight: fullHeight) { start, dx, dy in
                Self.rect(left: start.minX + dx, top: start.minY + dy, right: start.maxX, bottom: start.maxY,
                          anchoredRight: true, anchoredBottom: true)
            }
            cropCorner(at: CGPoint(x: frame.maxX, y: frame.minY), fullWidth: fullWidth, fullHeight: fullHeight) { start, dx, dy in
                Self.rect(left: start.minX, top: start.minY + dy, right: start.maxX + dx, bottom: start.maxY,
                          anchoredRight: false, anchoredBottom: true)
            }
            cropCorner(at: CGPoint(x: frame.minX, y: frame.maxY), fullWidth: fullWidth, fullHeight: fullHeight) { start, dx, dy in
                Self.rect(left: start.minX + dx, top: start.minY, right: start.maxX, bottom: start.maxY + dy,
                          anchoredRight: true, anchoredBottom: false)
            }
            cropCorner(at: CGPoint(x: frame.maxX, y: frame.maxY), fullWidth: fullWidth, fullHeight: fullHeight) { start, dx, dy in
                Self.rect(left: start.minX, top: start.minY, right: start.maxX + dx, bottom: start.maxY + dy,
                          anchoredRight: false, anchoredBottom: false)
            }
        }
        .frame(width: fullWidth, height: fullHeight, alignment: .topLeading)
        .overlay(alignment: .top) { cropActions.offset(y: -52 / scale) }
        .offset(x: originX, y: originY)
    }

    private static let minimumCrop: CGFloat = 0.1

    /// A crop rectangle from dragged edges, kept inside the photo and never
    /// smaller than the minimum (the anchored sides stay put).
    private static func rect(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat,
                             anchoredRight: Bool, anchoredBottom: Bool) -> CGRect {
        var l = max(left, 0), t = max(top, 0), r = min(right, 1), b = min(bottom, 1)
        if r - l < minimumCrop {
            if anchoredRight { l = r - minimumCrop } else { r = l + minimumCrop }
        }
        if b - t < minimumCrop {
            if anchoredBottom { t = b - minimumCrop } else { b = t + minimumCrop }
        }
        return CGRect(x: l, y: t, width: r - l, height: b - t)
    }

    private func cropGesture(fullWidth: CGFloat, fullHeight: CGFloat,
                             update: @escaping (CGRect, CGFloat, CGFloat) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard let draft = cropDraft else { return }
                let start = cropStart ?? draft
                cropStart = start
                cropDraft = update(start,
                                   value.translation.width / scale / fullWidth,
                                   value.translation.height / scale / fullHeight)
            }
            .onEnded { _ in cropStart = nil }
    }

    private func cropCorner(at point: CGPoint, fullWidth: CGFloat, fullHeight: CGFloat,
                            update: @escaping (CGRect, CGFloat, CGFloat) -> CGRect) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .frame(width: 18, height: 18)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .scaleEffect(1 / scale)
            .gesture(cropGesture(fullWidth: fullWidth, fullHeight: fullHeight, update: update))
            .position(point)
    }

    /// Cancel / reset / apply, in a glass capsule above the photo.
    private var cropActions: some View {
        HStack(spacing: 4) {
            cropAction("xmark") { endCrop() }
            cropAction("arrow.counterclockwise") {
                cropDraft = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
            cropAction("checkmark") {
                if let cropDraft { onCrop(cropDraft) }
                endCrop()
            }
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: .capsule)
        .scaleEffect(1 / scale)
    }

    private func cropAction(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func endCrop() {
        cropDraft = nil
        cropStart = nil
        onCropModeChange(false)
    }
}

/// Applies the move gesture only when interactive.
private struct MoveModifier<G: Gesture>: ViewModifier {
    let enabled: Bool
    let gesture: G
    func body(content: Content) -> some View {
        if enabled { content.gesture(gesture) } else { content }
    }
}
