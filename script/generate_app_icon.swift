// Draws the Coincide app icon as an .iconset from vector geometry, so the repository
// holds no binary icon. Usage: swift script/generate_app_icon.swift <output.iconset>
// The build script converts the result with iconutil and caches it by this file's hash.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 2, arguments[1].hasSuffix(".iconset") else {
    FileHandle.standardError.write(Data("usage: generate_app_icon.swift <output.iconset>\n".utf8)); exit(2)
}
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// All geometry is in a 1024-point canvas with a y-up origin at the bottom left.
func draw(_ context: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Body on Apple's macOS icon grid: 824-point rounded square with a soft drop shadow.
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
    context.addPath(body); context.setFillColor(color(0x161A2B)); context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(body); context.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x2A2F4F), color(0x111426)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // A quiet top sheen.
    let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])

    // Two rings that coincide; their shared lens is the bright center.
    let radius: CGFloat = 214, offset: CGFloat = 122, center = CGPoint(x: 512, y: 512)
    let left = CGRect(x: center.x - offset - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let right = CGRect(x: center.x + offset - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    context.saveGState()
    context.addEllipse(in: left); context.clip()
    context.addEllipse(in: right); context.clip()
    let lens = CGGradient(colorsSpace: space, colors: [color(0xF4F7FF), color(0xBFD3FF)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(lens, start: CGPoint(x: 512, y: 726), end: CGPoint(x: 512, y: 298), options: [])
    context.restoreGState()

    context.setLineWidth(54)
    context.setStrokeColor(color(0x7C9CFF)); context.strokeEllipse(in: left.insetBy(dx: 27, dy: 27))
    context.setStrokeColor(color(0x5EE6CF)); context.strokeEllipse(in: right.insetBy(dx: 27, dy: 27))
    context.restoreGState()

    // A hairline edge keeps the body legible on dark backgrounds.
    context.addPath(body); context.setStrokeColor(color(0xFFFFFF, 0.08)); context.setLineWidth(4); context.strokePath()
}

let renditions: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for rendition in renditions {
    let size = rendition.pixels
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write(Data("Could not create a \(size)-pixel icon context.\n".utf8)); exit(1)
    }
    context.interpolationQuality = .high; context.setShouldAntialias(true)
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(context)
    let url = output.appendingPathComponent(rendition.name + ".png")
    guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("Could not encode \(url.lastPathComponent).\n".utf8)); exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { FileHandle.standardError.write(Data("Could not write \(url.path).\n".utf8)); exit(1) }
}
