// Draws the app icon and writes an .iconset plus a 1024px PNG.
//
//     swift make-icon.swift <output-directory>
//
// The artwork is the page's own favicon — the inline SVG in index.html, `/·/`
// in Rosé Pine gold and foam on the base tint. That favicon is a full-bleed
// 32×32 tile with rx=7; a macOS icon wants the same shape inset inside a larger
// canvas, so the tile is drawn at 824/1024 of the canvas with the standard
// margin. The corner radius works out to almost exactly the favicon's own
// proportion, which is why this reads as the same mark rather than a redraw.
//
// Redrawing the shapes in Core Graphics rather than rasterising the SVG keeps
// this dependency-free: no librsvg, no headless browser, nothing to install.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Rosé Pine Moon, matching the favicon.
let base = CGColor(red: 0x23 / 255, green: 0x21 / 255, blue: 0x36 / 255, alpha: 1)
let gold = CGColor(red: 0xf6 / 255, green: 0xc1 / 255, blue: 0x77 / 255, alpha: 1)
let foam = CGColor(red: 0x9c / 255, green: 0xcf / 255, blue: 0xd8 / 255, alpha: 1)

/// Renders the icon at `size` points square.
func drawIcon(size: CGFloat) -> CGImage? {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil,
                                  width: Int(size), height: Int(size),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // Work in the SVG's coordinates: 32 units square, y downwards, inset into
    // the canvas the way macOS icons are.
    let tile = size * 824 / 1024
    let margin = (size - tile) / 2
    context.translateBy(x: margin, y: margin + tile)
    context.scaleBy(x: tile / 32, y: -tile / 32)

    context.setShouldAntialias(true)

    // The tile.
    let tilePath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 32, height: 32),
                          cornerWidth: 7, cornerHeight: 7, transform: nil)
    context.addPath(tilePath)
    context.setFillColor(base)
    context.fillPath()

    // The two slashes.
    context.setStrokeColor(gold)
    context.setLineWidth(3)
    context.setLineCap(.round)
    for (x1, x2) in [(13.0, 8.0), (25.0, 20.0)] {
        context.move(to: CGPoint(x: x1, y: 7))
        context.addLine(to: CGPoint(x: x2, y: 25))
        context.strokePath()
    }

    // The dot between them.
    context.setFillColor(foam)
    context.addEllipse(in: CGRect(x: 16.5 - 2.3, y: 16 - 2.3, width: 4.6, height: 4.6))
    context.fillPath()

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "cannot encode \(url.path)"])
    }
}

// MARK: - Main

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <output-directory>\n".utf8))
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)

do {
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    // The set iconutil expects.
    let variants: [(name: String, pixels: CGFloat)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    var cache: [CGFloat: CGImage] = [:]
    for variant in variants {
        let image: CGImage
        if let cached = cache[variant.pixels] {
            image = cached
        } else {
            guard let drawn = drawIcon(size: variant.pixels) else {
                throw NSError(domain: "make-icon", code: 3,
                              userInfo: [NSLocalizedDescriptionKey:
                                            "cannot render at \(Int(variant.pixels))px"])
            }
            cache[variant.pixels] = drawn
            image = drawn
        }
        try write(image, to: iconset.appendingPathComponent("\(variant.name).png"))
    }

    // Kept alongside for anything that wants the plain artwork, including an
    // Xcode asset catalog if the app is ever rebuilt as an Xcode project.
    if let largest = cache[1024] {
        try write(largest, to: outputDirectory.appendingPathComponent("icon-1024.png"))
    }
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
