import AppKit

// Builds the demo pages' ink as JSON: page key → strokes in page points
// (834 × 1210, the iPad 11" portrait canvas). Also writes a PNG preview.

struct OutStroke: Codable { var kind: String; var color: String; var width: Double; var points: [[Double]] }

let blue = "#0088FF", black = "#1C1C1E", red = "#FF383C", green = "#34C759", yellow = "#FFCC00", purple = "#CB30E0", orange = "#FF8D28"
let hand = "BradleyHandITCTT-Bold"

final class Page {
    var strokes: [OutStroke] = []
    var seed = 7
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 24, color: String = black, width: Double = 3.4, slant: CGFloat = 0.04) {
        seed += 13
        for c in Hand.strokes(s, font: hand, size: size, at: CGPoint(x: x, y: y), slant: slant, seed: seed) {
            strokes.append(OutStroke(kind: "pen", color: color, width: width * 0.62, points: c.map { [Double($0.x), Double($0.y)] }))
        }
    }
    func line(_ pts: [CGPoint], color: String = black, width: Double = 3.4) {
        strokes.append(OutStroke(kind: "pen", color: color, width: width * 0.66, points: Hand.chaikin(Hand.chaikin(pts)).map { [Double($0.x), Double($0.y)] }))
    }
    func marker(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat, color: String = yellow, width: Double = 22) {
        var pts: [[Double]] = []
        var x = x0
        while x <= x1 { pts.append([Double(x), Double(y + 1.2 * sin(x / 40))]); x += 6 }
        strokes.append(OutStroke(kind: "marker", color: color, width: width, points: pts))
    }
    /// A hand-drawn loop (slightly open, overshooting) around a centre.
    func loop(_ cx: CGFloat, _ cy: CGFloat, rx: CGFloat, ry: CGFloat, color: String = red, width: Double = 3.4) {
        var pts: [CGPoint] = []
        for i in 0...44 {
            let t = CGFloat(i) / 40 * 2 * .pi - 0.6
            let wob = 1 + 0.04 * sin(t * 3)
            pts.append(CGPoint(x: cx + rx * wob * cos(t), y: cy + ry * wob * sin(t) + CGFloat(i) * 0.15))
        }
        line(pts, color: color, width: width)
    }
    func box(_ r: CGRect, color: String = black) {
        let k: CGFloat = 10
        line([CGPoint(x: r.minX + k, y: r.minY + 1), CGPoint(x: r.maxX - k, y: r.minY), CGPoint(x: r.maxX, y: r.minY + k),
              CGPoint(x: r.maxX + 1, y: r.maxY - k), CGPoint(x: r.maxX - k, y: r.maxY), CGPoint(x: r.minX + k, y: r.maxY + 1),
              CGPoint(x: r.minX, y: r.maxY - k), CGPoint(x: r.minX - 1, y: r.minY + k), CGPoint(x: r.minX + k + 4, y: r.minY)], color: color)
    }
    func arrow(_ a: CGPoint, _ b: CGPoint, color: String = black, bend: CGFloat = 8) {
        let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - bend)
        line([a, m, b], color: color)
        let ang = atan2(b.y - m.y, b.x - m.x)
        let l: CGFloat = 13
        line([CGPoint(x: b.x - l * cos(ang - 0.5), y: b.y - l * sin(ang - 0.5)), b,
              CGPoint(x: b.x - l * cos(ang + 0.5), y: b.y - l * sin(ang + 0.5))], color: color)
    }
    func check(_ x: CGFloat, _ y: CGFloat, color: String = green) {
        line([CGPoint(x: x, y: y), CGPoint(x: x + 7, y: y + 9), CGPoint(x: x + 24, y: y - 14)], color: color, width: 3.8)
    }
    func strike(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat, color: String = black) {
        line([CGPoint(x: x0, y: y + 2), CGPoint(x: (x0 + x1) / 2, y: y - 1), CGPoint(x: x1, y: y + 1)], color: color, width: 2.6)
    }
    func mountains(_ ox: CGFloat, _ oy: CGFloat, s: CGFloat = 1, color: String = black) {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        line([p(0, 120), p(70, 30), p(100, 62), p(150, 0), p(250, 120)], color: color)
        line([p(132, 22), p(150, 34), p(160, 24), p(170, 36)], color: color, width: 2.6)
        loop(ox + 215 * s, oy + 8 * s, rx: 17 * s, ry: 17 * s, color: orange, width: 3)
        line([p(10, 132), p(90, 128), p(170, 133), p(240, 129)], color: color, width: 2.6)
        // pines
        for (x, h) in [(40.0, 36.0), (62.0, 46.0), (196.0, 40.0)] {
            line([p(x, 120), p(x, 120 - h)], color: green, width: 2.6)
            line([p(x - 11, 112 - h * 0.3), p(x, 120 - h), p(x + 11, 112 - h * 0.3)], color: green, width: 2.6)
            line([p(x - 13, 120 - h * 0.15), p(x, 120 - h * 0.7), p(x + 13, 120 - h * 0.15)], color: green, width: 2.6)
        }
    }
}

var pages: [String: [OutStroke]] = [:]

// Today: plan the week.
do {
    let p = Page()
    p.marker(54, 400, 178)
    p.text("Sunday · plan the week", 56, 190, size: 38, color: blue, width: 3.8)
    p.text("1. Call Maria about the launch", 64, 268)
    p.text("Fri 10:00", 476, 268)
    p.loop(530, 259, rx: 70, ry: 26)
    p.text("2. Send the Q1 budget draft", 64, 322)
    p.text("3. Book the train to Cluj", 64, 376)
    p.strike(60, 352, 368)
    p.check(370, 372)
    p.text("4. Pick up the film photos", 64, 430)
    p.text("Groceries", 64, 520, size: 28, color: blue)
    p.text("Weekend", 520, 520, size: 28, color: blue)
    p.mountains(500, 560, s: 1)
    p.text("cabin trip in 3 weeks!", 500, 750, size: 22)
    p.text("Ideas", 64, 900, size: 28, color: blue)
    p.text("– a weekly page for the habit tracker", 64, 950, size: 22)
    p.text("– ask Ana for the sourdough starter", 64, 996, size: 22)
    pages["today"] = p.strokes
}

// Yesterday: cabin trip, yellow paper.
do {
    let p = Page(); p.seed = 40
    p.text("Cabin trip", 56, 190, size: 44, color: black, width: 4)
    p.marker(56, 290, 182, color: orange, width: 20)
    p.text("Dec 4 – 7 · Apuseni", 60, 246, size: 24, color: blue)
    p.mountains(440, 120, s: 1.4)
    p.text("Packing", 64, 420, size: 28, color: blue)
    p.text("Route", 470, 420, size: 28, color: blue)
    p.line([CGPoint(x: 480, y: 470), CGPoint(x: 540, y: 520), CGPoint(x: 600, y: 490), CGPoint(x: 680, y: 560), CGPoint(x: 740, y: 540)], color: red, width: 3)
    p.loop(480, 470, rx: 9, ry: 9, color: black, width: 3)
    p.loop(740, 540, rx: 9, ry: 9, color: black, width: 3)
    p.text("Cluj", 450, 506, size: 20)
    p.text("cabin", 712, 588, size: 20)
    p.text("Remember: the road closes at 18:00", 64, 760, size: 23)
    p.marker(300, 520, 752, width: 20)
    pages["cabin"] = p.strokes
}

// Design review.
do {
    let p = Page(); p.seed = 90
    p.text("Design review", 56, 190, size: 40, width: 3.8)
    p.text("v2", 330, 190, size: 40, color: red, width: 3.8)
    p.text("– Simpler toolbar, fewer icons", 64, 270)
    p.text("– Paper: white, yellow, dark", 64, 322)
    p.text("– Test on the small iPad", 64, 374)
    p.text("Decision: ship the gel pen", 64, 450, size: 28, color: blue)
    p.marker(60, 380, 440, width: 22)
    for (i, label) in ["Idea", "Sketch", "Ship"].enumerated() {
        let x = 70 + CGFloat(i) * 250
        p.box(CGRect(x: x, y: 560, width: 160, height: 80))
        p.text(label, x + 40, 612, size: 26)
        if i < 2 { p.arrow(CGPoint(x: x + 172, y: 600), CGPoint(x: x + 238, y: 600)) }
    }
    p.text("Next review: Thursday", 64, 860, size: 22, color: purple)
    pages["review"] = p.strokes
}

// Week goals.
do {
    let p = Page(); p.seed = 130
    p.text("Week goals", 56, 190, size: 40, color: green, width: 3.8)
    let goals = ["Run three times", "In bed before 23:00", "Call grandma", "Finish the budget", "Read 50 pages"]
    for (i, g) in goals.enumerated() {
        let y = 280 + CGFloat(i) * 62
        p.box(CGRect(x: 66, y: y - 26, width: 28, height: 28))
        if i < 3 { p.check(70, y - 10) }
        p.text(g, 116, y)
    }
    p.text("Mon Tue Wed Thu Fri Sat Sun", 64, 700, size: 22, color: blue)
    for i in 0..<5 { p.loop(84 + CGFloat(i) * 56, 740, rx: 12, ry: 12, color: green, width: 3) }
    pages["goals"] = p.strokes
}

// Evening notes (dark paper; black ink shows light there).
do {
    let p = Page(); p.seed = 170
    p.text("Evening notes", 56, 190, size: 40, width: 3.8)
    p.text("A quiet, good day.", 64, 270)
    p.text("Finished the new toolbar and", 64, 322)
    p.text("walked home through the park.", 64, 374)
    p.text("Grateful for:", 64, 450, size: 28, color: orange)
    p.text("– coffee with Ana", 80, 504)
    p.text("– the first snow", 80, 556)
    p.text("– a page that feels like paper", 80, 608)
    pages["evening"] = p.strokes
}

// Tomorrow.
do {
    let p = Page(); p.seed = 210
    p.text("Monday", 56, 190, size: 40, color: blue, width: 3.8)
    p.text("9:30  Stand-up", 64, 270)
    p.text("12:00  Lunch with the design team", 64, 322)
    p.text("16:00  Dentist", 64, 374)
    p.loop(150, 366, rx: 90, ry: 24)
    pages["monday"] = p.strokes
}

// Budget.
do {
    let p = Page(); p.seed = 250
    p.text("November budget", 56, 190, size: 38, width: 3.8)
    let rows = [("Rent", "1,200"), ("Food", "420"), ("Travel", "260"), ("Books", "45")]
    for (i, r) in rows.enumerated() {
        let y = 280 + CGFloat(i) * 56
        p.text(r.0, 70, y); p.text(r.1, 330, y)
    }
    p.line([CGPoint(x: 64, y: 498), CGPoint(x: 420, y: 496)], width: 2.8)
    p.text("Total", 70, 546, color: blue); p.text("1,925", 320, 546, color: blue)
    for (i, h) in [140.0, 50, 30, 8].enumerated() {
        let x = 520 + CGFloat(i) * 60
        p.box(CGRect(x: x, y: 520 - h * 1.6, width: 36, height: h * 1.6), color: [blue, green, orange, purple][i])
    }
    pages["budget"] = p.strokes
}

// Small notes for earlier days and other notebooks.
func short(_ key: String, _ title: String, _ lines: [String], color: String = black, seed: Int) {
    let p = Page(); p.seed = seed
    p.text(title, 56, 190, size: 36, color: color, width: 3.8)
    for (i, l) in lines.enumerated() { p.text(l, 64, 270 + CGFloat(i) * 54) }
    pages[key] = p.strokes
}
short("nov2", "Monday", ["Gym 7:00", "Pay the electricity bill"], color: blue, seed: 300)
short("nov4", "Ideas", ["Squeeze for quick tools", "Paper that turns dark at night"], color: orange, seed: 320)
short("nov6", "Friday", ["Movie night", "Order new notebooks"], color: blue, seed: 340)
short("work1", "Sprint 47", ["Ship the overview spread", "Fix the eraser edge", "Write the release notes"], color: green, seed: 380)
short("journal1", "Morning pages", ["Slept well. Cold and bright", "outside. Writing more by hand", "this month."], color: purple, seed: 400)


// Meeting series: one tag per kind of meeting; the red "Next" line of each
// page is picked up by the next one, so a filtered tag reads as a thread.
func meeting(_ key: String, _ title: String, _ lines: [String], next: String, color: String, seed: Int, done: Set<Int> = []) {
    let p = Page(); p.seed = seed
    p.text(title, 56, 196, size: 48, color: color, width: 4.2)
    p.line([CGPoint(x: 58, y: 222), CGPoint(x: 300, y: 219), CGPoint(x: 470, y: 223)], color: color, width: 3)
    for (i, l) in lines.enumerated() {
        let y = 300 + CGFloat(i) * 70
        p.text(l, 64, y, size: 30, width: 3.6)
        if done.contains(i) { p.check(600, y - 4) }
    }
    let y = 300 + CGFloat(lines.count) * 70 + 40
    p.text("→ Next: " + next, 64, y, size: 32, color: red, width: 3.8)
    p.loop(330, y - 10, rx: 290, ry: 34, color: red, width: 2.8)
    pages[key] = p.strokes
}
meeting("m1a", "1:1 · Maria", ["– Goal: launch on Dec 1", "– Store page copy needed", "– Pricing: free + Pro?", "– Beta: 20 people"], next: "share the beta plan", color: purple, seed: 500)
meeting("m1b", "1:1 · Maria", ["– Beta plan approved", "– 20 testers by Friday", "– Pricing: keep it simple", "– Ana joins for icons"], next: "first feedback", color: purple, seed: 510, done: [0])
meeting("m1c", "1:1 · Maria", ["– 18 testers in, 2 pending", "– Top ask: export to PDF", "– iPad mini crash fixed", "– Mood: good!"], next: "estimate PDF export", color: purple, seed: 520, done: [2])
meeting("nov9", "1:1 · Maria", ["– PDF export: about 3 days", "– Launch moves to Friday", "– Screenshots ready", "– Press list: 12 names"], next: "call Fri 10:00", color: purple, seed: 530, done: [2])
meeting("dr1", "Design review v1", ["– Too many toolbar icons", "– Try a dark paper", "– Bigger date strip"], next: "v2 sketches", color: black, seed: 540)
meeting("dr2", "Design review", ["– v2 sketches feel calmer", "– Dark paper looks great", "– Date strip: done"], next: "test the gel pen", color: black, seed: 550, done: [2])
meeting("ws1", "Weekly sync", ["– Sprint 45 done", "– Blocked: new icons", "– Hiring: 2 interviews"], next: "ask Ana for icons", color: green, seed: 560, done: [0])
meeting("ws2", "Weekly sync", ["– Icons: first drafts in", "– Beta build is out", "– Hiring: offer sent"], next: "triage beta bugs", color: green, seed: 570, done: [1])
meeting("ws3", "Weekly sync", ["– 12 bugs fixed, 3 left", "– Release notes drafted", "– New hire starts Dec 1"], next: "freeze on Thursday", color: green, seed: 580, done: [0])
meeting("cn1", "Client · Nova", ["– Wants a shared calendar", "– Budget agreed", "– Launch in Q1"], next: "send the proposal", color: orange, seed: 590)
meeting("cn2", "Client · Nova", ["– Proposal accepted", "– Kick-off on Dec 2", "– Two designers on their side"], next: "plan the kick-off", color: orange, seed: 600, done: [0])

// Photo page: handwriting around two photos (boxes placed by the seeder).
do {
    let p = Page(); p.seed = 620
    p.text("Last weekend · Apuseni", 56, 190, size: 38, color: blue, width: 3.8)
    p.text("6:40 am", 572, 300, size: 24)
    p.text("fog on the lake", 572, 350, size: 22)
    p.text("–2°C, so quiet", 572, 398, size: 22)
    p.arrow(CGPoint(x: 600, y: 430), CGPoint(x: 540, y: 500), bend: -10)
    p.text("Our cabin", 64, 720, size: 30, color: blue)
    p.text("wood stove", 70, 780, size: 22); p.check(200, 774)
    p.text("no signal at all", 70, 830, size: 22)
    p.text("best sleep in months", 70, 880, size: 22)
    p.arrow(CGPoint(x: 250, y: 910), CGPoint(x: 318, y: 850), bend: 14)
    p.marker(60, 380, 1052, width: 22)
    p.text("Book it again for March!", 64, 1062, size: 26, color: red)
    pages["photos"] = p.strokes
}

for k in pages.keys { pages[k] = pages[k]!.map { var s = $0; s.points = s.points.map { [$0[0], $0[1] - 60] }; return s } }
let enc = JSONEncoder()
try! enc.encode(pages).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

// Preview of the hero page.
let W = 834, H = 1210
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
ctx.setLineCap(.round); ctx.setLineJoin(.round)
for key in [CommandLine.arguments[3]] {
    for s in pages[key]! {
        let c = NSColor(hex: s.color)
        ctx.setStrokeColor(s.kind == "marker" ? c.withAlphaComponent(0.4).cgColor : c.cgColor)
        ctx.setLineWidth(s.width)
        ctx.beginPath(); ctx.move(to: CGPoint(x: s.points[0][0], y: s.points[0][1]))
        for q in s.points.dropFirst() { ctx.addLine(to: CGPoint(x: q[0], y: q[1])) }
        ctx.strokePath()
    }
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))

extension NSColor {
    convenience init(hex: String) {
        let v = Int(hex.dropFirst(), radix: 16)!
        self.init(red: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}
