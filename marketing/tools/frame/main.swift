import AppKit

// Frames raw simulator screenshots as App Store marketing screenshots:
// headline + subline on a soft background, the screenshot in a device bezel.

struct Shot { var raw: String; var out: String; var title: String; var sub: String; var dark = false; var duo: String? = nil }

let raw = CommandLine.arguments[1], outDir = CommandLine.arguments[2]

let iphone: [Shot] = [
    Shot(raw: "iphone-01-page", out: "iphone-01", title: "Your handwriting,\nin your pocket", sub: "Pages from your iPad, synced through iCloud."),
    Shot(raw: "ipad-01-page", out: "iphone-02", title: "iPad and iPhone,\nalways in step", sub: "iCloud keeps every page the same on both.", duo: "iphone-01-page"),
    Shot(raw: "iphone-11-typing", out: "iphone-03", title: "Write by hand,\ncontinue in text", sub: "On the go, type your notes right under your handwriting."),
    Shot(raw: "iphone-07-minimal", out: "iphone-04", title: "Just you,\nyour pen\nand a quiet clock", sub: "Fewer distractions. More room to create."),
    Shot(raw: "iphone-08-thread", out: "iphone-05", title: "Follow the thread", sub: "Tag each kind of meeting, then read them in order."),
    Shot(raw: "iphone-09-meetingtags", out: "iphone-06", title: "A tag for every\nkind of meeting", sub: "1:1s, reviews, syncs, clients. Sorted later."),
    Shot(raw: "iphone-10-photos", out: "iphone-07", title: "Photos among\nyour notes", sub: "Place a photo anywhere on the page."),
    Shot(raw: "iphone-05-cabin", out: "iphone-08", title: "Lists you can\ntick off", sub: "Checklists live right on the page."),
    Shot(raw: "iphone-03-calendar", out: "iphone-09", title: "Any day,\none tap away", sub: "The calendar marks the days you wrote."),
    Shot(raw: "iphone-06-dark", out: "iphone-10", title: "Paper for\nevery hour", sub: "White, yellow or dark.", dark: true),
]
let ipad: [Shot] = [
    Shot(raw: "ipad-01-page", out: "ipad-01", title: "Your agenda, in your own hand", sub: "A gel pen that writes as smoothly as paper."),
    Shot(raw: "ipad-01-page", out: "ipad-02", title: "iPad and iPhone, always in step", sub: "Write on iPad, read and add notes on iPhone. iCloud keeps them in sync.", duo: "iphone-01-page"),
    Shot(raw: "ipad-08-minimal", out: "ipad-03", title: "Just you, your pen and a quiet clock", sub: "Fewer distractions than ever. More room to create."),
    Shot(raw: "ipad-09-grid", out: "ipad-04", title: "Many pages at once", sub: "See a whole stretch of days at a glance."),
    Shot(raw: "ipad-02-spread", out: "ipad-05", title: "Leaf through it like a paper agenda", sub: "Turn the iPad sideways for an open two-page spread."),
    Shot(raw: "ipad-10-thread", out: "ipad-06", title: "Follow the thread", sub: "Tag each kind of meeting, then read them in order."),
    Shot(raw: "ipad-11-photos", out: "ipad-07", title: "Photos among your notes", sub: "Place a photo anywhere on the page, next to your writing."),
    Shot(raw: "ipad-06-squeeze", out: "ipad-08", title: "Tools right where you write", sub: "Squeeze Apple Pencil Pro to bring them to the tip."),
    Shot(raw: "ipad-05-dark", out: "ipad-09", title: "Paper for every hour", sub: "White, yellow or dark, page by page.", dark: true),
]

func color(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

/// One device: bezel, rim, screenshot and (iPhone) the Dynamic Island.
func drawDevice(_ ctx: CGContext, _ cg: CGImage, screen: CGRect, phone: Bool, dark: Bool) {
    let scale = screen.width / CGFloat(cg.width)
    let bezel = screen.width * (phone ? 0.028 : 0.023)
    let device = screen.insetBy(dx: -bezel, dy: -bezel)
    let screenRadius = (phone ? 165 : 50) * scale
    let deviceRadius = screenRadius + bezel
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 70, color: color(0x0A1630, dark ? 0.6 : 0.28))
    ctx.addPath(CGPath(roundedRect: device, cornerWidth: deviceRadius, cornerHeight: deviceRadius, transform: nil))
    ctx.setFillColor(color(0x1C1C1E)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: device.insetBy(dx: 2, dy: 2), cornerWidth: deviceRadius - 2, cornerHeight: deviceRadius - 2, transform: nil))
    ctx.setStrokeColor(color(0x5A5D66)); ctx.setLineWidth(4); ctx.strokePath()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: screen)
    ctx.restoreGState()
    if phone {
        let iw = 126 * 3 * scale, ih = 37 * 3 * scale
        let island = CGRect(x: screen.midX - iw / 2, y: screen.maxY - 11 * 3 * scale - ih, width: iw, height: ih)
        ctx.addPath(CGPath(roundedRect: island, cornerWidth: ih / 2, cornerHeight: ih / 2, transform: nil))
        ctx.setFillColor(color(0x000000)); ctx.fillPath()
    }
}

/// A generic sync badge: a white disc with a blue cloud and two turning arrows.
func drawSyncBadge(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 40, color: color(0x0A1630, 0.25))
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    // Cloud: three lobes on a rounded base.
    let u = r * 0.5
    let cloud = CGMutablePath()
    cloud.addRoundedRect(in: CGRect(x: c.x - 1.25 * u, y: c.y - 0.75 * u, width: 2.5 * u, height: 0.95 * u), cornerWidth: 0.47 * u, cornerHeight: 0.47 * u)
    cloud.addEllipse(in: CGRect(x: c.x - 1.0 * u, y: c.y - 0.55 * u, width: 1.1 * u, height: 1.1 * u))
    cloud.addEllipse(in: CGRect(x: c.x - 0.35 * u, y: c.y - 0.5 * u, width: 1.45 * u, height: 1.45 * u))
    ctx.addPath(cloud); ctx.setFillColor(color(0x0A84FF)); ctx.fillPath()
    // Two arrows turning around the cloud's centre.
    let ac = CGPoint(x: c.x, y: c.y - 0.08 * u), ar = 0.42 * u
    ctx.setStrokeColor(color(0xFFFFFF)); ctx.setLineWidth(0.13 * u); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    for (start, end) in [(CGFloat.pi * 0.15, CGFloat.pi * 0.85), (CGFloat.pi * 1.15, CGFloat.pi * 1.85)] {
        ctx.addArc(center: ac, radius: ar, startAngle: start, endAngle: end, clockwise: false); ctx.strokePath()
        let tip = CGPoint(x: ac.x + ar * cos(end), y: ac.y + ar * sin(end))
        let t = CGVector(dx: -sin(end), dy: cos(end))          // direction of travel
        let n = CGVector(dx: cos(end), dy: sin(end))
        let l = 0.2 * u
        ctx.move(to: CGPoint(x: tip.x - t.dx * l + n.dx * l * 0.8, y: tip.y - t.dy * l + n.dy * l * 0.8))
        ctx.addLine(to: tip)
        ctx.addLine(to: CGPoint(x: tip.x - t.dx * l - n.dx * l * 0.8, y: tip.y - t.dy * l - n.dy * l * 0.8))
        ctx.strokePath()
    }
}

func render(_ s: Shot, W: Int, H: Int, phone: Bool) {
    guard let img = NSImage(contentsOfFile: "\(raw)/\(s.raw).png"),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("missing", s.raw); return }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    let w = CGFloat(W), h = CGFloat(H)

    // Background: a soft vertical wash (light), or deep ink (dark).
    let top = s.dark ? color(0x1A1D24) : color(0xF4F7FC)
    let bottom = s.dark ? color(0x0B0C10) : color(0xDDE8F8)
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
    // A faint accent glow behind the device.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0x0A84FF, s.dark ? 0.22 : 0.16), color(0x0A84FF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: w / 2, y: h * 0.42), startRadius: 0,
                           endCenter: CGPoint(x: w / 2, y: h * 0.42), endRadius: w * 0.75, options: [])

    // Text (AppKit draws in flipped-up coordinates; use NSString drawing with y from bottom).
    let titleSize: CGFloat = phone ? 104 : 112
    let subSize: CGFloat = phone ? 46 : 50
    let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineHeightMultiple = 0.95
    let titleAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: titleSize, weight: .bold),
        .foregroundColor: NSColor(cgColor: s.dark ? color(0xF5F6F8) : color(0x111317))!,
        .paragraphStyle: para, .kern: -titleSize * 0.02]
    let subPara = NSMutableParagraphStyle(); subPara.alignment = .center
    let subAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: subSize, weight: .regular),
        .foregroundColor: NSColor(cgColor: s.dark ? color(0xA4ABB8) : color(0x5B6474))!,
        .paragraphStyle: subPara]
    let title = NSAttributedString(string: s.title, attributes: titleAttr)
    let sub = NSAttributedString(string: s.sub, attributes: subAttr)
    let textW = w - (phone ? 160 : 240)
    let tb = title.boundingRect(with: CGSize(width: textW, height: 1000), options: [.usesLineFragmentOrigin])
    let sb = sub.boundingRect(with: CGSize(width: textW, height: 400), options: [.usesLineFragmentOrigin])
    // A landscape screenshot is width-bound: centre header + device as one block.
    let isLandscape = cg.width > cg.height
    var topMargin: CGFloat = 150
    if isLandscape {
        let devH = CGFloat(cg.height) * ((w - 100 - 68) / CGFloat(cg.width)) + 68
        topMargin = max(150, (h - (tb.height + 34 + sb.height + 120 + devH)) / 2)
    }
    title.draw(with: CGRect(x: (w - textW) / 2, y: h - topMargin - tb.height, width: textW, height: tb.height), options: [.usesLineFragmentOrigin])
    let subTop = topMargin + tb.height + (phone ? 30 : 34)
    sub.draw(with: CGRect(x: (w - textW) / 2, y: h - subTop - sb.height, width: textW, height: sb.height), options: [.usesLineFragmentOrigin])
    let headerBottom = subTop + sb.height

    if let duo = s.duo, let pimg = NSImage(contentsOfFile: "\(raw)/\(duo).png"),
       let pcg = pimg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        // iPad behind on the left, iPhone in front on the right, the sync badge between them.
        let areaTop = h - headerBottom - (phone ? 110 : 120), areaBottom: CGFloat = phone ? 120 : 130
        let areaH = areaTop - areaBottom
        let iw0 = CGFloat(cg.width), ih0 = CGFloat(cg.height)
        let padH = min(areaH * (phone ? 0.80 : 0.97), (w * (phone ? 0.86 : 0.70)) * ih0 / iw0)
        let pad = CGRect(x: w * (phone ? 0.04 : 0.08), y: areaTop - padH, width: padH * iw0 / ih0, height: padH)
        let phH = phone ? areaH * 0.62 : padH * 0.74
        let pw0 = CGFloat(pcg.width), ph0 = CGFloat(pcg.height)
        let phW = phH * pw0 / ph0
        let ph = CGRect(x: w - w * (phone ? 0.05 : 0.07) - phW, y: areaBottom, width: phW, height: phH)
        drawDevice(ctx, cg, screen: pad, phone: false, dark: s.dark)
        drawDevice(ctx, pcg, screen: ph, phone: true, dark: s.dark)
        let r = w * (phone ? 0.085 : 0.06)
        let badge = phone ? CGPoint(x: ph.minX - r * 0.2, y: ph.minY + ph.height * 0.30)
                          : CGPoint(x: ph.midX, y: min(ph.maxY + r + 70, areaTop - r))
        drawSyncBadge(ctx, center: badge, radius: r)
        NSGraphicsContext.restoreGraphicsState()
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(s.out).png"))
        print(s.out, W, H, "duo")
        return
    }

    // Device.
    let sw = CGFloat(cg.width), sh = CGFloat(cg.height)
    let landscape = sw > sh
    let bezel: CGFloat = phone ? 26 : 34
    let gap: CGFloat = phone ? 90 : 100
    let bottomMargin: CGFloat = phone ? 120 : 130
    let availH = h - headerBottom - gap - bottomMargin - bezel * 2
    let availW = w - (landscape ? 100 : (phone ? 300 : 360)) - bezel * 2
    let scale = landscape ? availW / sw : min(availH / sh, availW / sw)
    let dw = sw * scale, dh = sh * scale
    let screenY = landscape ? h - headerBottom - 120 - bezel - dh : bottomMargin + bezel + (availH - dh) / 2
    let screen = CGRect(x: (w - dw) / 2, y: screenY, width: dw, height: dh)
    let device = screen.insetBy(dx: -bezel, dy: -bezel)
    let screenRadius = (phone ? 165 : 50) * scale * (phone ? 1 : 1.0) + (phone ? 0 : 0)
    let deviceRadius = screenRadius + bezel

    // Shadow + body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 70, color: color(0x0A1630, s.dark ? 0.6 : 0.28))
    ctx.addPath(CGPath(roundedRect: device, cornerWidth: deviceRadius, cornerHeight: deviceRadius, transform: nil))
    ctx.setFillColor(color(0x1C1C1E)); ctx.fillPath()
    ctx.restoreGState()
    // Rim highlight.
    ctx.addPath(CGPath(roundedRect: device.insetBy(dx: 2, dy: 2), cornerWidth: deviceRadius - 2, cornerHeight: deviceRadius - 2, transform: nil))
    ctx.setStrokeColor(color(0x5A5D66)); ctx.setLineWidth(4); ctx.strokePath()
    // Screen.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: screen)
    ctx.restoreGState()
    // Dynamic Island, the same on every iPhone frame.
    if phone {
        let iw = 126 * 3 * scale, ih = 37 * 3 * scale
        let island = CGRect(x: screen.midX - iw / 2, y: screen.maxY - 11 * 3 * scale - ih, width: iw, height: ih)
        ctx.addPath(CGPath(roundedRect: island, cornerWidth: ih / 2, cornerHeight: ih / 2, transform: nil))
        ctx.setFillColor(color(0x000000)); ctx.fillPath()
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(s.out).png"))
    print(s.out, W, H)
}

for s in iphone { render(s, W: 1320, H: 2868, phone: true) }
for s in ipad { render(s, W: 2064, H: 2752, phone: false) }
