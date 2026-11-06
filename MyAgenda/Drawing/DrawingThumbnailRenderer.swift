//
//  DrawingThumbnailRenderer.swift
//  MyAgenda
//
//  Renders a small page preview (photos, ink, text, checklists) in the page's
//  own coordinate space, showing the top of the page. The cache key is a
//  fingerprint of what is actually on the page, so a thumbnail is rendered once
//  per version of the page: an edit always refreshes it, and an unchanged page
//  never renders again, not even after a relaunch (thumbnails are also kept on
//  disk, one per page).
//

import SwiftUI
import PencilKit
import CryptoKit

enum DrawingThumbnailRenderer {
    // NSCache is thread-safe, so it's fine to touch from the off-main render path.
    private nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()

    /// Bump when the drawing code changes, so old thumbnails are redone.
    private static let renderVersion = 6

    /// Hash of each page's drawing, so megabytes of ink are only re-hashed
    /// after the page changes.
    private static var drawingHashes: [UUID: (stamp: Date, size: Int, hash: String)] = [:]

    struct Snapshot: Sendable {
        var key: String
        var drawingData: Data
        var canvasWidth: Double
        var canvasHeight: Double
        var images: [ImageSnapshot]
        var texts: [TextSnapshot]
        var checklists: [ChecklistSnapshot]
        var paper: PaperColor
        var size: CGSize
    }

    struct ImageSnapshot: Sendable {
        var imageData: Data
        var x: Double
        var y: Double
        var widthFraction: Double
        var aspectRatio: Double
        var crop: CGRect
    }

    struct TextSnapshot: Sendable {
        var rtfData: Data
        var backgroundHex: String
        var x: Double
        var y: Double
        var widthFraction: Double
    }

    struct ChecklistSnapshot: Sendable {
        var items: [(text: String, checked: Bool)]
        var backgroundHex: String
        var x: Double
        var y: Double
        var widthFraction: Double
    }

    /// Identifies what the page looks like right now.
    static func key(for page: JournalPage, size: CGSize) -> String {
        var hash = SHA256()
        func add(_ text: String) { hash.update(data: Data(text.utf8)) }

        add("v\(renderVersion)|\(drawingHash(of: page))|\(page.canvasWidth)x\(page.canvasHeight)|\(page.paper.rawValue)")
        for box in (page.imageBoxes ?? []).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            add("i\(box.id)|\(box.x)|\(box.y)|\(box.widthFraction)|\(box.aspectRatio)|\(box.cropRect)")
        }
        for box in (page.textBoxes ?? []).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            add("t\(box.x)|\(box.y)|\(box.widthFraction)|\(box.backgroundColorRaw)")
            hash.update(data: box.rtfData)
        }
        for box in (page.checklistBoxes ?? []).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            add("c\(box.x)|\(box.y)|\(box.widthFraction)|\(box.backgroundColorRaw)")
            hash.update(data: box.itemsData)
        }
        let digest = hash.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(page.id.uuidString)-\(digest)-\(Int(size.width))x\(Int(size.height))"
    }

    private static func drawingHash(of page: JournalPage) -> String {
        if let known = drawingHashes[page.id], known.stamp == page.updatedAt,
           known.size == page.drawingData.count {
            return known.hash
        }
        let digest = SHA256.hash(data: page.drawingData).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
        drawingHashes[page.id] = (page.updatedAt, page.drawingData.count, digest)
        return digest
    }

    static func thumbnail(for page: JournalPage, size: CGSize) -> UIImage {
        thumbnail(for: snapshot(for: page, size: size))
    }

    static func snapshot(for page: JournalPage, size: CGSize) -> Snapshot {
        Snapshot(
            key: key(for: page, size: size),
            drawingData: page.drawingData,
            canvasWidth: page.canvasWidth,
            canvasHeight: page.canvasHeight,
            images: (page.imageBoxes ?? []).map {
                ImageSnapshot(
                    imageData: $0.imageData,
                    x: $0.x,
                    y: $0.y,
                    widthFraction: $0.widthFraction,
                    aspectRatio: $0.aspectRatio,
                    crop: $0.cropRect
                )
            },
            texts: (page.textBoxes ?? []).map {
                TextSnapshot(
                    rtfData: $0.rtfData,
                    backgroundHex: $0.backgroundColorRaw,
                    x: $0.x,
                    y: $0.y,
                    widthFraction: $0.widthFraction
                )
            },
            checklists: (page.checklistBoxes ?? []).map {
                ChecklistSnapshot(
                    items: $0.items.map { ($0.text, $0.checked) },
                    backgroundHex: $0.backgroundColorRaw,
                    x: $0.x,
                    y: $0.y,
                    widthFraction: $0.widthFraction
                )
            },
            paper: page.paper,
            size: size
        )
    }

    nonisolated static func thumbnail(for snapshot: Snapshot) -> UIImage {
        let key = snapshot.key as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = render(snapshot)
        cache.setObject(image, forKey: key)
        store(image, key: snapshot.key)
        return image
    }

    /// The thumbnail for `key` if it was already rendered: from memory, else
    /// from disk.
    nonisolated static func cachedThumbnail(forKey key: String) -> UIImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let data = try? Data(contentsOf: fileURL(forKey: key)),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    // MARK: Disk

    private nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PageThumbnails", isDirectory: true)
    }

    private nonisolated static func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("jpg")
    }

    /// Writes the thumbnail and drops the page's older versions.
    private nonisolated static func store(_ image: UIImage, key: String) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let pagePrefix = String(key.prefix(36))
        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(pagePrefix) {
            try? manager.removeItem(at: file)
        }
        try? data.write(to: fileURL(forKey: key), options: .atomic)
    }

    // MARK: Rendering

    nonisolated private static func render(_ snapshot: Snapshot) -> UIImage {
        let size = snapshot.size
        let drawing = try? PKDrawing(data: snapshot.drawingData)

        // Page coordinate space. Fall back to the drawing bounds or a default.
        var pageW = CGFloat(snapshot.canvasWidth)
        var pageH = CGFloat(snapshot.canvasHeight)
        if pageW <= 0 || pageH <= 0 {
            if let b = drawing?.bounds, b.width > 0, b.height > 0 {
                pageW = max(b.maxX, 1); pageH = max(b.maxY, 1)
            } else {
                pageW = 820; pageH = 1100
            }
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            // Render in the paper's appearance, not the system's: PencilKit
            // adapts ink to it, so black ink stays black on light paper and
            // turns white on dark paper, as on the page.
            let paper = snapshot.paper
            UITraitCollection(userInterfaceStyle: paper.interfaceStyle).performAsCurrent {
                paper.uiColor.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))

                let scale = size.width / pageW
                let visibleHeight = size.height / scale

                ctx.cgContext.saveGState()
                ctx.cgContext.scaleBy(x: scale, y: scale)

                for box in snapshot.images {
                    guard let original = UIImage(data: box.imageData) else { continue }
                    let ui = ImageBox.cropped(original, to: box.crop)
                    // y is a fraction of the page WIDTH, like on the page itself.
                    let by = CGFloat(box.y) * pageW
                    guard by < visibleHeight else { continue }
                    let bw = CGFloat(box.widthFraction) * pageW
                    let bh = bw * CGFloat(box.aspectRatio)
                    ui.draw(in: CGRect(x: CGFloat(box.x) * pageW, y: by, width: bw, height: bh))
                }

                for box in snapshot.texts {
                    guard let stored = TextBoxView.attributedString(from: box.rtfData),
                          stored.length > 0 else { continue }
                    let attributed = paper.shown(stored)
                    let bx = CGFloat(box.x) * pageW + 6      // the text view's inset
                    let by = CGFloat(box.y) * pageW + 6
                    guard by < visibleHeight else { continue }
                    // Never past the page's right edge, as on the page itself.
                    let bw = max(min(CGFloat(box.widthFraction) * pageW, pageW * (1 - CGFloat(box.x)) - 6) - 12, 40)
                    let rect = CGRect(x: bx, y: by, width: bw, height: visibleHeight - by)
                    if !box.backgroundHex.isEmpty, let tint = Color(hex: box.backgroundHex) {
                        let used = attributed.boundingRect(with: CGSize(width: bw, height: .greatestFiniteMagnitude),
                                                           options: [.usesLineFragmentOrigin], context: nil)
                        UIColor(tint).withAlphaComponent(0.22).setFill()
                        UIBezierPath(roundedRect: CGRect(x: bx - 6, y: by - 6, width: bw + 12, height: used.height + 12),
                                     cornerRadius: 8).fill()
                    }
                    attributed.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
                }

                for box in snapshot.checklists {
                    draw(box, paper: paper, pageWidth: pageW, visibleHeight: visibleHeight, in: ctx.cgContext)
                }

                // Ink last, over text and checklists, as on the page.
                if let drawing, !drawing.bounds.isNull,
                   drawing.bounds.width > 0, drawing.bounds.height > 0 {
                    let bounds = drawing.bounds
                    let strokeImage = drawing.image(from: bounds, scale: 1)
                    strokeImage.draw(in: bounds)
                }

                ctx.cgContext.restoreGState()
            }
        }
    }

    /// Same look as on the page: circles, text, optional tinted background.
    nonisolated private static func draw(_ box: ChecklistSnapshot, paper: PaperColor, pageWidth: CGFloat,
                                         visibleHeight: CGFloat, in context: CGContext) {
        let fontSize: CGFloat = 19
        let rowHeight = ceil(fontSize * 1.2) + 6
        let padding: CGFloat = 10
        let originX = CGFloat(box.x) * pageWidth
        let originY = CGFloat(box.y) * pageWidth
        guard originY < visibleHeight, !box.items.isEmpty else { return }
        let width = max(CGFloat(box.widthFraction) * pageWidth, 80)
        let height = CGFloat(box.items.count) * rowHeight + padding * 2

        if !box.backgroundHex.isEmpty, let hex = Color(hex: box.backgroundHex) {
            UIColor(hex).withAlphaComponent(0.22).setFill()
            UIBezierPath(roundedRect: CGRect(x: originX, y: originY, width: width, height: height),
                         cornerRadius: 10).fill()
        }

        let font = UIFont.systemFont(ofSize: fontSize)
        for (index, item) in box.items.enumerated() {
            let y = originY + padding + CGFloat(index) * rowHeight
            let color: UIColor = item.checked ? .systemGreen : paper.shown(.black)
            let circle = CGRect(x: originX + padding, y: y + 2, width: fontSize - 2, height: fontSize - 2)
            if item.checked {
                color.setFill()
                context.fillEllipse(in: circle)
            } else {
                UIColor.gray.setStroke()
                context.setLineWidth(1)
                context.strokeEllipse(in: circle)
            }
            let text = NSAttributedString(string: item.text, attributes: [.font: font, .foregroundColor: color])
            text.draw(with: CGRect(x: circle.maxX + 8, y: y, width: width - padding * 2 - fontSize - 8, height: rowHeight),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
    }
}
