import AppKit
import CoreText

// Turns text set in a handwriting font into centre-line strokes:
// render big, Zhang–Suen thin, trace pixel chains, simplify, smooth.
struct Hand {
    static let scale: CGFloat = 8   // render scale over page points

    struct Stroke: Codable { var points: [[Double]] }

    /// Strokes for `text` with its baseline-left at `origin` (page points, y down).
    static func strokes(_ text: String, font fontName: String, size: CGFloat, at origin: CGPoint,
                        slant: CGFloat = 0, seed: Int = 1) -> [[CGPoint]] {
        let font = CTFontCreateWithName(fontName as CFString, size * scale, nil)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let pad = Int(size * scale * 0.3)
        let w = Int(bounds.width) + pad * 2, h = Int(bounds.height) + pad * 2
        guard w > 0, h > 0 else { return [] }
        var px = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setShouldAntialias(true)
            ctx.textPosition = CGPoint(x: CGFloat(pad) - bounds.minX, y: CGFloat(pad) - bounds.minY)
            // white text on black
            let white = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
            CTLineDraw(CTLineCreateWithAttributedString(white), ctx)
        }
        // Bitmap rows go bottom-up in CG; convert to top-down bools.
        var img = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w { img[y * w + x] = px[y * w + x] > 110 } }
        // Close tiny holes then thin.
        thin(&img, w, h)
        var chains = trace(img, w, h)
        let minLen = size * scale * 0.08
        _ = minLen
        // Back to page coordinates: baseline in bitmap (top-down) is at h - pad + bounds.minY
        let baseY = CGFloat(h) - CGFloat(pad) + bounds.minY
        let ox = CGFloat(pad) - bounds.minX
        var rng = seed
        func rnd() -> CGFloat { rng = (rng &* 1103515245 &+ 12345) & 0x7fffffff; return CGFloat(rng % 1000) / 1000 - 0.5 }
        let wobbleA = rnd() * 0.8, wobbleF = 0.004 + abs(rnd()) * 0.004
        return chains.map { chain in
            let simple = rdp(chain, eps: 0.9)
            let smooth = chaikin(chaikin(simple))
            return smooth.map { p -> CGPoint in
                let x = (p.x - ox) / scale, y = (p.y - baseY) / scale
                // slant + a slow baseline wobble so it reads as written, not set
                let xs = x - y * slant
                return CGPoint(x: origin.x + xs, y: origin.y + y + wobbleA * sin(xs * wobbleF * 6.28 * 3))
            }
        }
    }

    static func length(_ c: [CGPoint]) -> CGFloat {
        zip(c, c.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    static func thin(_ img: inout [Bool], _ w: Int, _ h: Int) {
        func at(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && img[y * w + x] }
        var changed = true
        while changed {
            changed = false
            for step in 0..<2 {
                var del: [Int] = []
                for y in 1..<(h - 1) { for x in 1..<(w - 1) where img[y * w + x] {
                    let p = [at(x, y-1), at(x+1, y-1), at(x+1, y), at(x+1, y+1), at(x, y+1), at(x-1, y+1), at(x-1, y), at(x-1, y-1)]
                    let b = p.filter { $0 }.count
                    guard b >= 2, b <= 6 else { continue }
                    var a = 0
                    for i in 0..<8 where !p[i] && p[(i + 1) % 8] { a += 1 }
                    guard a == 1 else { continue }
                    if step == 0 {
                        if p[0] && p[2] && p[4] { continue }
                        if p[2] && p[4] && p[6] { continue }
                    } else {
                        if p[0] && p[2] && p[6] { continue }
                        if p[0] && p[4] && p[6] { continue }
                    }
                    del.append(y * w + x)
                }}
                if !del.isEmpty { changed = true; for i in del { img[i] = false } }
            }
        }
    }

    static let dirs = [(0,-1),(1,-1),(1,0),(1,1),(0,1),(-1,1),(-1,0),(-1,-1)]

    static func trace(_ img: [Bool], _ w: Int, _ h: Int) -> [[CGPoint]] {
        func on(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && img[y * w + x] }
        func nbrs(_ x: Int, _ y: Int) -> [(Int, Int)] { dirs.compactMap { on(x + $0.0, y + $0.1) ? (x + $0.0, y + $0.1) : nil } }
        var deg = [Int](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w where img[y * w + x] { deg[y * w + x] = nbrs(x, y).count } }
        var usedEdge = Set<Int64>()
        func key(_ a: Int, _ b: Int) -> Int64 { let (l, m) = a < b ? (a, b) : (b, a); return Int64(l) << 32 | Int64(m) }
        var chains: [[CGPoint]] = []
        func walk(from s: (Int, Int), via n: (Int, Int)) {
            var chain = [CGPoint(x: s.0, y: s.1)]
            var prev = s, cur = n
            usedEdge.insert(key(s.1 * w + s.0, n.1 * w + n.0))
            while true {
                chain.append(CGPoint(x: cur.0, y: cur.1))
                if deg[cur.1 * w + cur.0] != 2 { break }
                let next = nbrs(cur.0, cur.1).first { ($0.0 != prev.0 || $0.1 != prev.1) && !usedEdge.contains(key(cur.1 * w + cur.0, $0.1 * w + $0.0)) }
                guard let nx = next else { break }
                usedEdge.insert(key(cur.1 * w + cur.0, nx.1 * w + nx.0))
                prev = cur; cur = nx
            }
            chains.append(chain)
        }
        // From endpoints and junctions first.
        for pass in 0..<2 {
            for y in 0..<h { for x in 0..<w where img[y * w + x] {
                let d = deg[y * w + x]
                if pass == 0 && d == 2 { continue }
                for n in nbrs(x, y) where !usedEdge.contains(key(y * w + x, n.1 * w + n.0)) {
                    walk(from: (x, y), via: n)
                }
            }}
        }
        // Dots (the i's, colons) thin down to a lone pixel.
        for y in 0..<h { for x in 0..<w where img[y * w + x] && deg[y * w + x] == 0 {
            chains.append([CGPoint(x: x, y: y), CGPoint(x: CGFloat(x) + 4, y: CGFloat(y) + 2)])
        }}
        // Join chains that meet end-to-end at the same pixel with a smooth turn.
        return joinChains(chains)
    }

    static func joinChains(_ input: [[CGPoint]]) -> [[CGPoint]] {
        var chains = input.filter { $0.count >= 2 }
        func dir(_ c: [CGPoint], atEnd: Bool) -> CGVector {
            let k = min(6, c.count - 1)
            let a = atEnd ? c[c.count - 1 - k] : c[k], b = atEnd ? c[c.count - 1] : c[0]
            let l = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            return CGVector(dx: (b.x - a.x) / l, dy: (b.y - a.y) / l)   // pointing outward
        }
        var merged = true
        while merged {
            merged = false
            outer: for i in chains.indices {
                for j in chains.indices where j != i {
                    for (ei, ej) in [(true, false), (true, true), (false, false), (false, true)] {
                        let pi = ei ? chains[i].last! : chains[i].first!
                        let pj = ej ? chains[j].last! : chains[j].first!
                        guard hypot(pi.x - pj.x, pi.y - pj.y) < 2.5 else { continue }
                        let di = dir(chains[i], atEnd: ei), dj = dir(chains[j], atEnd: ej)
                        // continue straight-ish: outward directions opposite
                        guard di.dx * dj.dx + di.dy * dj.dy < -0.6 else { continue }
                        var a = ei ? chains[i] : Array(chains[i].reversed())
                        let b = ej ? Array(chains[j].reversed()) : chains[j]
                        a.append(contentsOf: b.dropFirst())
                        chains[i] = a
                        chains.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return chains
    }

    static func rdp(_ pts: [CGPoint], eps: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        let a = pts.first!, b = pts.last!
        var maxD: CGFloat = 0, idx = 0
        let len = max(hypot(b.x - a.x, b.y - a.y), 0.0001)
        for i in 1..<(pts.count - 1) {
            let p = pts[i]
            let d = len < 0.001 ? hypot(p.x - a.x, p.y - a.y)
                : abs((b.y - a.y) * p.x - (b.x - a.x) * p.y + b.x * a.y - b.y * a.x) / len
            if d > maxD { maxD = d; idx = i }
        }
        if maxD > eps {
            return Array(rdp(Array(pts[0...idx]), eps: eps).dropLast()) + rdp(Array(pts[idx...]), eps: eps)
        }
        return [a, b]
    }

    static func chaikin(_ p: [CGPoint]) -> [CGPoint] {
        guard p.count > 2 else { return p }
        var out = [p[0]]
        for i in 0..<(p.count - 1) {
            let a = p[i], b = p[i + 1]
            out.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
            out.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
        }
        out.append(p[p.count - 1])
        return out
    }
}
