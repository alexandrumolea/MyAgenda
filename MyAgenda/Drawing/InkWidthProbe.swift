//
//  InkWidthProbe.swift
//  MyAgenda
//
//  Debug builds only. Measures, on the real screen, how much thicker PencilKit
//  draws a committed gel stroke than the engine's preview drew it, and logs
//  the difference. The commit size comes from a law measured on the simulator;
//  this tells whether the iPad renders the same way.
//

#if DEBUG
import UIKit

enum InkWidthProbe {
    /// Only the latest stroke is measured: a newer commit could land in the
    /// same rect before the older one is read back.
    private static var generation = 0
    /// PencilKit may not have drawn the previous stroke yet; caught in only
    /// one of the two captures, it would count as part of this one. Only a
    /// stroke written after a pause is measured.
    private static var lastCommit: CFAbsoluteTime = 0
    private static let pause: CFAbsoluteTime = 0.3
    /// What the pen engine did with its copy since the last commit: repeated
    /// on the report lines, so they tell the whole story on their own.
    private static var notes: [String] = []

    /// Prints `line` and keeps it for the measurement under way.
    static func note(_ line: String) {
        print("🖊️ " + line)
        notes.append(line)
    }

    /// Call just before the stroke reaches the canvas. `drawPreview` draws the
    /// stroke as the engine shows it, `drawSpline` along PencilKit's own curve,
    /// both in canvas coordinates.
    static func measure(on canvas: UIView, rect: CGRect, length: CGFloat, width: CGFloat,
                        drawPreview: (CGContext) -> Void, drawSpline: (CGContext) -> Void) {
        let now = CFAbsoluteTimeGetCurrent()
        defer { lastCommit = now }
        // Any commit ends a measurement still running: its ink would land in it.
        generation += 1
        notes.removeAll()
        let mine = generation
        let rect = rect.insetBy(dx: -4, dy: -4).intersection(canvas.bounds).integral
        guard now - lastCommit > pause, length > 20,
              !rect.isNull, rect.width > 0, rect.height > 0 else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = canvas.traitCollection.displayScale
        format.opaque = false
        format.preferredRange = .standard
        let before = snapshot(canvas, rect: rect, format: format)
        let captureTime = CFAbsoluteTimeGetCurrent() - now
        // What the screen shows: the page with every layer, the engine's
        // live line and its lingering copy included. At the lift it still
        // shows the live line.
        let page = pageView(of: canvas)
        let atLift = screen(page, canvas: canvas, rect: rect, format: format)
        let previewed = UIGraphicsImageRenderer(bounds: rect, format: format).image { context in
            before.draw(in: rect)
            drawPreview(context.cgContext)
        }
        let splined = UIGraphicsImageRenderer(bounds: rect, format: format).image { context in
            before.draw(in: rect)
            drawSpline(context.cgContext)
        }
        // Every frame PencilKit shows in the first 100 ms, then the settled
        // stroke: whatever it draws between the lift and its final copy.
        let sampler = FrameSampler(start: now, until: 0.1) { [weak canvas, weak page] in
            guard let canvas, mine == generation else { return nil }
            return Frame(canvas: snapshot(canvas, rect: rect, format: format),
                         screen: screen(page, canvas: canvas, rect: rect, format: format))
        }
        sampler.run { [weak canvas, weak page] frames in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard let canvas, mine == generation else { return }
                let after = snapshot(canvas, rect: rect, format: format)
                let settled = screen(page, canvas: canvas, rect: rect, format: format)
                report(before: before, previewed: previewed, splined: splined, after: after,
                       frames: frames, length: length, width: width, scale: format.scale,
                       captureTime: captureTime)
                reportScreen(atLift: atLift, frames: frames, settled: settled,
                             length: length, scale: format.scale)
            }
        }
    }

    struct Frame {
        var time: CFAbsoluteTime = 0
        var canvas: UIImage
        var screen: UIImage?
    }

    /// The page's scroll view: the canvas, the engine and the boxes.
    private static func pageView(of canvas: UIView) -> UIView? {
        var next = canvas.superview
        while let view = next {
            if view is UIScrollView { return view }
            next = view.superview
        }
        return nil
    }

    private static func screen(_ page: UIView?, canvas: UIView, rect: CGRect,
                               format: UIGraphicsImageRendererFormat) -> UIImage? {
        guard let page else { return nil }
        let frame = page.convert(page.bounds, to: canvas)
        return UIGraphicsImageRenderer(bounds: rect, format: format).image { _ in
            _ = page.drawHierarchy(in: frame, afterScreenUpdates: false)
        }
    }

    /// How much more ink the screen shows on each frame than at the lift,
    /// in points of line width: positive is bolder. The page is opaque here,
    /// so plain luminance works; on dark paper the ink is the lighter side.
    private static func reportScreen(atLift: UIImage?, frames: [Frame], settled: UIImage?,
                                     length: CGFloat, scale: CGFloat) {
        guard let atLift, let base = pixels(atLift) else {
            print("🖊️ Pe ecran: captura paginii nu merge")
            return
        }
        var light = 0.0, dark = 1.0, sum = 0.0
        for i in stride(from: 0, to: base.count, by: 4) {
            let l = luminance(base, at: i)
            light = max(light, l); dark = min(dark, l); sum += l
        }
        let contrast = light - dark
        guard contrast > 0.15 else { return }
        // The paper is most of the rect: the ink is on the other side of the mean.
        let inkIsDark = sum / Double(base.count / 4) > (light + dark) / 2
        let perPoint = Double(length * scale * scale)
        func bolder(_ image: UIImage?) -> String {
            guard let image, let shown = pixels(image), shown.count == base.count else { return "?" }
            var change = 0.0
            for i in stride(from: 0, to: base.count, by: 4) {
                let delta = luminance(base, at: i) - luminance(shown, at: i)
                change += inkIsDark ? delta : -delta
            }
            return String(format: "%+.2f", change / contrast / perPoint)
        }
        let line = frames.map { String(format: "%.0f ms ", $0.time * 1000) + bolder($0.screen) }
        print("🖊️ Pe ecran (pt mai gros decât la ridicare): " + line.joined(separator: " · ")
              + " · final " + bolder(settled) + " || " + notes.joined(separator: " | "))
    }

    private static func luminance(_ p: [UInt8], at i: Int) -> Double {
        (0.299 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.114 * Double(p[i + 2])) / 255
    }

    /// Captures the canvas once per displayed frame, from the lift on.
    private final class FrameSampler: NSObject {
        private let start: CFAbsoluteTime
        private let until: CFAbsoluteTime
        private let capture: () -> Frame?
        private var frames: [Frame] = []
        private var done: ([Frame]) -> Void = { _ in }
        private var link: CADisplayLink?

        init(start: CFAbsoluteTime, until: CFAbsoluteTime, capture: @escaping () -> Frame?) {
            self.start = start
            self.until = until
            self.capture = capture
        }

        /// The display link keeps the sampler alive until it stops.
        func run(done: @escaping ([Frame]) -> Void) {
            self.done = done
            let link = CADisplayLink(target: self, selector: #selector(tick))
            // Each capture takes a few milliseconds of the main thread: at
            // 60 Hz it leaves PencilKit's own frames alone.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func tick() {
            let time = CFAbsoluteTimeGetCurrent() - start
            guard var frame = capture() else { return stop(report: false) }
            frame.time = time
            frames.append(frame)
            if time > until { stop(report: true) }
        }

        private func stop(report: Bool) {
            link?.invalidate()
            link = nil
            if report { done(frames) }
        }
    }

    private static func snapshot(_ canvas: UIView, rect: CGRect,
                                 format: UIGraphicsImageRendererFormat) -> UIImage {
        UIGraphicsImageRenderer(bounds: rect, format: format).image { _ in
            _ = canvas.drawHierarchy(in: canvas.bounds, afterScreenUpdates: false)
        }
    }

    /// Ink area over length is the line's width. Both strokes are counted
    /// against the same background and at the same threshold, half the
    /// preview's full contrast, so the paper, the ink color and older strokes
    /// underneath cancel out. The "mass" adds up every pixel's share of that
    /// contrast instead: the same width with darker soft edges weighs more,
    /// and reads as a bolder line.
    private static func report(before: UIImage, previewed: UIImage, splined: UIImage, after: UIImage,
                               frames: [Frame],
                               length: CGFloat, width: CGFloat, scale: CGFloat,
                               captureTime: CFAbsoluteTime) {
        guard let base = pixels(before), let mine = pixels(previewed), let theirs = pixels(after),
              let spline = pixels(splined),
              base.count == mine.count, base.count == theirs.count, base.count == spline.count
        else { return }
        var contrast = 0
        for i in stride(from: 0, to: base.count, by: 4) { contrast = max(contrast, difference(base, mine, at: i)) }
        guard contrast > 40 else {
            print("🖊️ Grosime: cerneala e prea deschisă pentru măsurătoare")
            return
        }
        let threshold = contrast / 2
        var previewArea = 0, pencilKitArea = 0
        var previewMass = 0, pencilKitMass = 0
        // Pixels inked by only one of the two lines: how far apart their
        // shapes are, whatever their widths.
        var previewMismatch = 0, splineMismatch = 0
        for i in stride(from: 0, to: base.count, by: 4) {
            let previewed = difference(base, mine, at: i)
            let drawn = difference(base, theirs, at: i)
            if previewed > threshold { previewArea += 1 }
            if drawn > threshold { pencilKitArea += 1 }
            previewMass += min(previewed, contrast)
            pencilKitMass += min(drawn, contrast)
            let splineInked = difference(base, spline, at: i) > threshold
            if (previewed > threshold) != (drawn > threshold) { previewMismatch += 1 }
            if splineInked != (drawn > threshold) { splineMismatch += 1 }
        }
        guard pencilKitArea > 0 else {
            print("🖊️ Grosime: linia PencilKit nu se vede în captură || " + notes.joined(separator: " | "))
            return
        }
        let perPoint = length * scale * scale
        let preview = CGFloat(previewArea) / perPoint
        let pencilKit = CGFloat(pencilKitArea) / perPoint
        let massPerPoint = perPoint * CGFloat(contrast)
        let previewWeight = CGFloat(previewMass) / massPerPoint
        let pencilKitWeight = CGFloat(pencilKitMass) / massPerPoint
        print(String(format: "🖊️ Grosime %.1f pt: previzualizare %.2f pt, PencilKit %.2f pt, diferență %+.2f pt | masă %.2f → %.2f pt, %+.2f pt (captură %.0f ms)",
                     width, preview, pencilKit, pencilKit - preview,
                     previewWeight, pencilKitWeight, pencilKitWeight - previewWeight, captureTime * 1000))
        print(String(format: "🖊️ Formă: nepotrivire previzualizare %.2f pt, curbă PencilKit %.2f pt",
                     CGFloat(previewMismatch) / perPoint, CGFloat(splineMismatch) / perPoint))

        // Per frame: the new stroke's width and mass, and how many pixels
        // changed away from it (older ink redrawn differently, for instance).
        var line: [String] = []
        // The settled stroke's pixels, once for every frame.
        var stroke = [Bool](repeating: false, count: base.count / 4)
        for i in stride(from: 0, to: base.count, by: 4) { stroke[i / 4] = difference(base, theirs, at: i) >= 8 }
        for frame in frames {
            guard let shown = pixels(frame.canvas), shown.count == base.count else { continue }
            var area = 0, mass = 0, elsewhere = 0
            for i in stride(from: 0, to: base.count, by: 4) {
                let changed = difference(base, shown, at: i)
                if !stroke[i / 4] {
                    if changed > threshold { elsewhere += 1 }
                    continue
                }
                if changed > threshold { area += 1 }
                mass += min(changed, contrast)
            }
            line.append(String(format: "%.0f ms %.2f/%.2f", frame.time * 1000,
                               CGFloat(area) / perPoint, CGFloat(mass) / massPerPoint)
                        + (elsewhere > 0 ? " +\(elsewhere) px" : ""))
        }
        print("🖊️ Cadre PencilKit (lățime/masă pt): " + line.joined(separator: " · "))
    }

    private static func difference(_ a: [UInt8], _ b: [UInt8], at i: Int) -> Int {
        max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])),
            abs(Int(a[i + 2]) - Int(b[i + 2])), abs(Int(a[i + 3]) - Int(b[i + 3])))
    }

    /// RGBA, 8 bits per channel, premultiplied: transparent canvas pixels
    /// compare by their alpha.
    private static func pixels(_ image: UIImage) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? data : nil
    }
}
#endif
