// Renders Packaging/AppIcon.png with CoreGraphics: a glowing planet inside a tilted orbit ring, on a
// deep-space squircle. Run via Scripts/make-icon.sh, which scales it into an .iconset and packs it.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("could not create bitmap context")
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

// macOS icons leave a margin around the rounded square.
let inset = 100.0
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Soft drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x000000, 0.45))
ctx.addPath(squircle)
ctx.setFillColor(rgb(0x0b0c1e))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x24205a), rgb(0x0d0e24)], [0, 1]),
                       start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

func glow(_ color: UInt32, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ a: CGFloat) {
    let c = CGPoint(x: x, y: y)
    ctx.drawRadialGradient(gradient([rgb(color, a), rgb(color, 0)], [0, 1]), startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
}
glow(0x7aa2f7, 300, 760, 520, 0.55)
glow(0xbb9af7, 780, 260, 480, 0.5)
glow(0xff79c6, 820, 820, 300, 0.25)

// Stars.
var seed: UInt64 = 42
func random() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat((seed >> 33) % 10_000) / 10_000
}
for _ in 0..<70 {
    let s = 2 + random() * 4
    ctx.setFillColor(rgb(0xffffff, 0.15 + random() * 0.45))
    ctx.fillEllipse(in: CGRect(x: tile.minX + random() * tile.width, y: tile.minY + random() * tile.height, width: s, height: s))
}

let centre = CGPoint(x: 512, y: 500)
let tilt = 0.42
let ringA = 345.0, ringB = 128.0

/// A point on the ring, `angle` radians around it (0 = right end, negative = front).
func onRing(_ angle: Double) -> CGPoint {
    let x = ringA * cos(angle), y = ringB * sin(angle)
    return CGPoint(x: centre.x + x * cos(tilt) - y * sin(tilt), y: centre.y + x * sin(tilt) + y * cos(tilt))
}

// Half of the ring: the back half is drawn before the planet, the front half after.
func ring(front: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: centre.x, y: centre.y)
    ctx.rotate(by: tilt)
    let rect = CGRect(x: -ringA, y: -ringB, width: ringA * 2, height: ringB * 2)
    // The halves overlap by a pixel so no seam shows where they meet.
    ctx.addRect(front ? CGRect(x: -420, y: -220, width: 840, height: 221) : CGRect(x: -420, y: -1, width: 840, height: 221))
    ctx.clip()
    ctx.setLineWidth(24)
    ctx.addEllipse(in: rect)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xffffff), rgb(0xff8ad8), rgb(0x7dcfff)], [0, 0.5, 1]),
                           start: CGPoint(x: -ringA, y: 0), end: CGPoint(x: ringA, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
ring(front: false)

// The planet: a lit sphere with a glow.
glow(0x7aa2f7, centre.x, centre.y, 330, 0.65)
ctx.saveGState()
let planet = CGRect(x: centre.x - 190, y: centre.y - 190, width: 380, height: 380)
ctx.addEllipse(in: planet)
ctx.clip()
ctx.drawRadialGradient(gradient([rgb(0xa9c4ff), rgb(0x6b7cf7), rgb(0x7b3fd6), rgb(0x2a1b6e)], [0, 0.35, 0.75, 1]),
                       startCenter: CGPoint(x: centre.x - 70, y: centre.y + 80), startRadius: 0,
                       endCenter: centre, endRadius: 200, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// A band of cloud for depth.
ctx.setFillColor(rgb(0xffffff, 0.12))
ctx.fillEllipse(in: CGRect(x: centre.x - 220, y: centre.y - 40, width: 440, height: 60))
ctx.restoreGState()

ring(front: true)

// A small moon riding the front of the ring.
let moon = onRing(-0.55)
glow(0xffffff, moon.x, moon.y, 70, 0.7)
ctx.setFillColor(rgb(0xffffff))
ctx.fillEllipse(in: CGRect(x: moon.x - 26, y: moon.y - 26, width: 52, height: 52))

// Glass sheen across the top.
ctx.drawLinearGradient(gradient([rgb(0xffffff, 0.16), rgb(0xffffff, 0)], [0, 1]),
                       start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY + 80), options: [])
ctx.restoreGState()

// A thin edge highlight.
ctx.addPath(squircle)
ctx.setStrokeColor(rgb(0xffffff, 0.18))
ctx.setLineWidth(3)
ctx.strokePath()

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Packaging/AppIcon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out.path)") }
print("wrote \(out.path)")
