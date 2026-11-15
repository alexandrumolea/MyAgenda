import AppKit
// Contact sheet: all framed shots of one device in a row.
let files = Array(CommandLine.arguments.dropFirst(2)); let out = CommandLine.arguments[1]
let imgs = files.map { NSImage(contentsOfFile: $0)! }
let cellH: CGFloat = 900, pad: CGFloat = 30
let widths = imgs.map { $0.size.width / $0.size.height * cellH }
let W = Int(widths.reduce(0, +) + pad * CGFloat(imgs.count + 1)), H = Int(cellH + pad * 2)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(white: 0.85, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
var x = pad
for (i, im) in imgs.enumerated() { im.draw(in: NSRect(x: x, y: pad, width: widths[i], height: cellH)); x += widths[i] + pad }
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
