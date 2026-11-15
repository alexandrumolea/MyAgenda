import AppKit
import CoreImage

// Two original, procedurally painted "photos" for the demo photo page:
// a misty mountain lake at dawn and a cabin in the hills.

let W = 1600, H = 1200
let cs = CGColorSpaceCreateDeviceRGB()

func rgb(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func mix(_ a: Int, _ b: Int, _ t: CGFloat) -> CGColor {
    func c(_ h: Int, _ s: Int) -> CGFloat { CGFloat(h >> s & 255) / 255 }
    return CGColor(red: c(a, 16) + (c(b, 16) - c(a, 16)) * t, green: c(a, 8) + (c(b, 8) - c(a, 8)) * t,
                   blue: c(a, 0) + (c(b, 0) - c(a, 0)) * t, alpha: 1)
}
func ridge(_ x: CGFloat, seed: CGFloat, amp: CGFloat, freq: CGFloat) -> CGFloat {
    var y: CGFloat = 0, a = amp, f = freq
    for o in 0..<5 { y += a * sin(x * f + seed * CGFloat(o + 1) * 1.7) ; a *= 0.48; f *= 2.1 }
    return y
}
func context() -> CGContext {
    CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func vgrad(_ ctx: CGContext, _ colors: [CGColor], _ locs: [CGFloat], from y0: CGFloat, to y1: CGFloat) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func layer(_ ctx: CGContext, base: CGFloat, amp: CGFloat, freq: CGFloat, seed: CGFloat, color: CGColor) {
    let p = CGMutablePath(); p.move(to: CGPoint(x: 0, y: 0))
    var x: CGFloat = 0
    while x <= CGFloat(W) { p.addLine(to: CGPoint(x: x, y: base + ridge(x, seed: seed, amp: amp, freq: freq))); x += 4 }
    p.addLine(to: CGPoint(x: CGFloat(W), y: 0)); p.closeSubpath()
    ctx.addPath(p); ctx.setFillColor(color); ctx.fillPath()
}
func mist(_ ctx: CGContext, at y: CGFloat, height: CGFloat, alpha: CGFloat, tint: Int = 0xFFFFFF) {
    vgrad(ctx, [rgb(tint, 0), rgb(tint, alpha), rgb(tint, 0)], [0, 0.5, 1], from: y - height / 2, to: y + height / 2)
}
func pines(_ ctx: CGContext, baseY: CGFloat, from x0: CGFloat, to x1: CGFloat, color: CGColor, seed: Int, scale: CGFloat) {
    var r = UInt32(seed)
    func rnd() -> CGFloat { r = r &* 1664525 &+ 1013904223; return CGFloat(r >> 8) / CGFloat(1 << 24) }
    var x = x0
    ctx.setFillColor(color)
    while x < x1 {
        let h = (60 + rnd() * 90) * scale, w = h * (0.28 + rnd() * 0.08)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x - w / 2, y: baseY)); p.addLine(to: CGPoint(x: x, y: baseY + h)); p.addLine(to: CGPoint(x: x + w / 2, y: baseY))
        p.closeSubpath(); ctx.addPath(p); ctx.fillPath()
        x += w * (0.45 + rnd() * 0.6)
    }
}
func finish(_ image: CGImage, blur: Double, grain: Double, path: String) {
    let ci = CIImage(cgImage: image)
    var out = ci.applyingGaussianBlur(sigma: blur).cropped(to: ci.extent)
    let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: ci.extent)
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
    _ = noise
    // Grain: luminance noise around mid-grey, soft-light blended.
    let grey = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: ci.extent)
        .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0, "inputContrast": grain])
    out = grey.applyingFilter("CISoftLightBlendMode", parameters: ["inputBackgroundImage": out])
    out = out.applyingFilter("CIVignette", parameters: ["inputIntensity": 0.55, "inputRadius": 2.2])
    let ctx = CIContext()
    try! ctx.writeJPEGRepresentation(of: out, to: URL(fileURLWithPath: path), colorSpace: cs,
                                     options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.88])
}

// 1. Lake at dawn.
do {
    let ctx = context()
    let horizon: CGFloat = 430
    vgrad(ctx, [rgb(0xF7C9A2), rgb(0xE9C3C2), rgb(0x9DB8DC), rgb(0x6E93C8)], [0, 0.25, 0.65, 1], from: horizon, to: CGFloat(H))
    let sun = CGPoint(x: 1040, y: 640)
    let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFF4DE, 1), rgb(0xFFE2B8, 0.55), rgb(0xFFD6A8, 0)] as CFArray, locations: [0, 0.25, 1])!
    ctx.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 520, options: [])
    let layers: [(CGFloat, CGFloat, CGFloat, Int)] = [(640, 90, 0.004, 0xB7B3CF), (590, 80, 0.006, 0x9796B8), (540, 70, 0.008, 0x726F98), (490, 55, 0.011, 0x4D5577), (450, 35, 0.016, 0x2E3B4E)]
    for (i, l) in layers.enumerated() {
        layer(ctx, base: l.0, amp: l.1, freq: l.2, seed: CGFloat(i) * 2.3 + 0.7, color: rgb(l.3))
        mist(ctx, at: l.0 - 30, height: 140, alpha: 0.38 - CGFloat(i) * 0.04, tint: 0xFBE6D6)
    }
    pines(ctx, baseY: horizon, from: 0, to: 520, color: rgb(0x1F2A32), seed: 3, scale: 1)
    pines(ctx, baseY: horizon, from: 1180, to: 1600, color: rgb(0x1F2A32), seed: 9, scale: 1.2)
    // Lake: the scene above, mirrored and darkened, with soft ripples.
    let above = ctx.makeImage()!.cropping(to: CGRect(x: 0, y: 0, width: W, height: H - Int(horizon)))!
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: CGFloat(W), height: horizon))
    ctx.translateBy(x: 0, y: horizon); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(above, in: CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H) - horizon))
    ctx.restoreGState()
    vgrad(ctx, [rgb(0x23324A, 0.55), rgb(0x23324A, 0.15)], [0, 1], from: 0, to: horizon)
    for i in 0..<70 {
        let y = CGFloat(i) * horizon / 70
        ctx.setFillColor(rgb(0xFFFFFF, 0.05 + 0.04 * CGFloat(i % 3)))
        ctx.fill(CGRect(x: CGFloat((i * 397) % 900), y: y, width: 300 + CGFloat((i * 131) % 500), height: 2))
    }
    mist(ctx, at: horizon + 10, height: 190, alpha: 0.32, tint: 0xFDEBDC)
    finish(ctx.makeImage()!, blur: 1.4, grain: 0.06, path: CommandLine.arguments[1] + "/photo-lake.jpg")
}

// 2. Cabin in the hills, late afternoon.
do {
    let ctx = context()
    vgrad(ctx, [rgb(0xF4E3C0), rgb(0xB9D3E8), rgb(0x7FAAD6)], [0, 0.45, 1], from: 560, to: CGFloat(H))
    let sun = CGPoint(x: 380, y: 760)
    let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFF6E0, 0.95), rgb(0xFFE7B8, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 420, options: [])
    layer(ctx, base: 700, amp: 70, freq: 0.005, seed: 1.1, color: rgb(0xA9B8C9))
    mist(ctx, at: 660, height: 120, alpha: 0.35)
    layer(ctx, base: 620, amp: 60, freq: 0.007, seed: 2.9, color: rgb(0x7F9A8A))
    layer(ctx, base: 520, amp: 50, freq: 0.006, seed: 4.2, color: rgb(0x5E8360))
    pines(ctx, baseY: 500, from: 980, to: 1600, color: rgb(0x2F4A36), seed: 5, scale: 1.4)
    layer(ctx, base: 360, amp: 40, freq: 0.004, seed: 6.4, color: rgb(0x6F9A55))
    vgrad(ctx, [rgb(0x4E7A3C, 0.0), rgb(0x3F6831, 0.7)], [0, 1], from: 360, to: 0)
    // Cabin.
    let cx: CGFloat = 640, cy: CGFloat = 400
    ctx.setFillColor(rgb(0x5A3B2A)); ctx.fill(CGRect(x: cx, y: cy, width: 220, height: 130))
    let roof = CGMutablePath(); roof.move(to: CGPoint(x: cx - 26, y: cy + 124)); roof.addLine(to: CGPoint(x: cx + 110, y: cy + 230))
    roof.addLine(to: CGPoint(x: cx + 246, y: cy + 124)); roof.closeSubpath()
    ctx.addPath(roof); ctx.setFillColor(rgb(0x2E2522)); ctx.fillPath()
    ctx.setFillColor(rgb(0xFFD58A)); ctx.fill(CGRect(x: cx + 34, y: cy + 50, width: 42, height: 40))
    ctx.setFillColor(rgb(0x3A2A20)); ctx.fill(CGRect(x: cx + 130, y: cy, width: 46, height: 82))
    ctx.setFillColor(rgb(0x3A3433)); ctx.fill(CGRect(x: cx + 170, y: cy + 180, width: 22, height: 60))
    pines(ctx, baseY: 380, from: 0, to: 420, color: rgb(0x28402E), seed: 11, scale: 1.8)
    finish(ctx.makeImage()!, blur: 1.2, grain: 0.06, path: CommandLine.arguments[1] + "/photo-cabin.jpg")
}
