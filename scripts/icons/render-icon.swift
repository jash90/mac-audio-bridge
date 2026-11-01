// Renders the Mac Audio Bridge app icon as a 1024×1024 PNG.
// Usage: swift scripts/icons/render-icon.swift <ios|macos> <output.png>
// iOS: full-bleed square (the system applies the mask).
// macOS: rounded "squircle" tile on the 1024 grid (824 pt tile, 100 pt margin) with a soft shadow.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3, ["ios", "macos"].contains(args[1]) else {
    FileHandle.standardError.write(Data("usage: render-icon.swift <ios|macos> <output.png>\n".utf8))
    exit(2)
}
let platform = args[1]
let outputURL = URL(fileURLWithPath: args[2])

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    // iOS icons must be opaque; macOS icons keep alpha around the tile.
    space: colorSpace,
    bitmapInfo: (platform == "ios" ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue
) else { fatalError("cannot create context") }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// Tile geometry.
let tile: CGRect = platform == "ios"
    ? CGRect(x: 0, y: 0, width: size, height: size)
    : CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath: CGPath = platform == "ios"
    ? CGPath(rect: tile, transform: nil)
    : CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// macOS drop shadow under the tile.
if platform == "macos" {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x2A1E9E))
    ctx.fillPath()
    ctx.restoreGState()
}

// Background: diagonal indigo → cyan gradient.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(0x3A22D6), color(0x2F6BEA), color(0x14C3E8)] as CFArray,
    locations: [0, 0.55, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: tile.minX, y: tile.maxY),
    end: CGPoint(x: tile.maxX, y: tile.minY),
    options: []
)
// Soft top highlight for depth.
let highlight = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    highlight,
    startCenter: CGPoint(x: tile.midX, y: tile.maxY), startRadius: 0,
    endCenter: CGPoint(x: tile.midX, y: tile.maxY), endRadius: tile.width * 0.75,
    options: []
)

// Mark, in tile-relative units.
let w = tile.width
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + x * w, y: tile.minY + y * w) }
let white = color(0xFFFFFF)

ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.012), blur: w * 0.03, color: color(0x0A0A40, 0.30))

// Phone outline.
let phone = CGRect(x: tile.minX + 0.50 * w, y: tile.minY + 0.21 * w, width: 0.30 * w, height: 0.58 * w)
ctx.addPath(CGPath(roundedRect: phone, cornerWidth: 0.075 * w, cornerHeight: 0.075 * w, transform: nil))
ctx.setStrokeColor(white)
ctx.setLineWidth(0.042 * w)
ctx.strokePath()

// Waveform bars inside the phone.
let barHeights: [CGFloat] = [0.10, 0.22, 0.32, 0.18, 0.08]
let barWidth = 0.027 * w
let barGap = 0.018 * w
let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * barGap
var barX = phone.midX - totalWidth / 2
ctx.setFillColor(white)
for h in barHeights {
    let height = h * w
    let bar = CGRect(x: barX, y: phone.midY - height / 2, width: barWidth, height: height)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    ctx.fillPath()
    barX += barWidth + barGap
}

// Sound waves travelling toward the phone.
let waveCenter = p(0.16, 0.50)
ctx.setLineCap(.round)
ctx.setLineWidth(0.048 * w)
for (radius, alpha) in [(0.13, 1.0), (0.235, 0.78)] as [(CGFloat, CGFloat)] {
    ctx.setStrokeColor(color(0xFFFFFF, alpha))
    ctx.addArc(center: waveCenter, radius: radius * w,
               startAngle: -.pi * 0.27, endAngle: .pi * 0.27, clockwise: false)
    ctx.strokePath()
}
ctx.setFillColor(white)
ctx.fillEllipse(in: CGRect(x: waveCenter.x - 0.038 * w, y: waveCenter.y - 0.038 * w, width: 0.076 * w, height: 0.076 * w))
ctx.restoreGState()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("cannot create image") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("cannot write png") }
print("wrote \(outputURL.path)")
