#!/usr/bin/env swift
// Draws the WhiteShot app icon and writes the AppIcon.appiconset.
//
//     swift scripts/make_icon.swift
//
// The icon is generated from code so it stays reproducible and easy to tweak: a pearl-white tile
// with four blue viewfinder corners and a centre dot.

import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "WhiteShot/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let scale = size / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let ctx = graphics.cgContext
    ctx.scaleBy(x: scale, y: scale)

    // macOS icon grid: 824 pt tile centred in a 1024 pt canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Soft shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Pearl gradient body.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let body = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1).cgColor,
        NSColor(srgbRed: 0.90, green: 0.92, blue: 0.95, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(body, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Faint top highlight.
    let highlight = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.9).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(highlight, startCenter: CGPoint(x: 400, y: 880), startRadius: 0, endCenter: CGPoint(x: 400, y: 880), endRadius: 520, options: [])
    ctx.restoreGState()

    // Hairline edge.
    ctx.addPath(tilePath)
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()

    // Viewfinder corners, drawn as one path and filled with a blue gradient.
    let inset: CGFloat = 215, arm: CGFloat = 120, thickness: CGFloat = 60
    let minX = tile.minX + inset, maxX = tile.maxX - inset, minY = tile.minY + inset, maxY = tile.maxY - inset
    let brackets = CGMutablePath()
    for (cx, cy, dx, dy) in [(minX, minY, 1.0, 1.0), (maxX, minY, -1.0, 1.0), (minX, maxY, 1.0, -1.0), (maxX, maxY, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        brackets.move(to: CGPoint(x: cx + dx * arm, y: cy))
        brackets.addLine(to: CGPoint(x: cx, y: cy))
        brackets.addLine(to: CGPoint(x: cx, y: cy + dy * arm))
    }
    let strokedBrackets = brackets.copy(strokingWithWidth: thickness, lineCap: .round, lineJoin: .round, miterLimit: 1)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 14, color: NSColor(srgbRed: 0.1, green: 0.25, blue: 0.7, alpha: 0.35).cgColor)
    ctx.addPath(strokedBrackets)
    ctx.clip()
    let blue = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.36, green: 0.66, blue: 1.0, alpha: 1).cgColor,
        NSColor(srgbRed: 0.10, green: 0.38, blue: 0.96, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(blue, start: CGPoint(x: 512, y: maxY + 60), end: CGPoint(x: 512, y: minY - 60), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Centre dot.
    let dot = CGRect(x: 512 - 52, y: 512 - 52, width: 104, height: 104)
    ctx.saveGState()
    ctx.addEllipse(in: dot)
    ctx.clip()
    ctx.drawLinearGradient(blue, start: CGPoint(x: 512, y: dot.maxY), end: CGPoint(x: 512, y: dot.minY), options: [])
    ctx.restoreGState()

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

struct Entry { let points: Int; let scale: Int }
let entries = [16, 32, 128, 256, 512].flatMap { [Entry(points: $0, scale: 1), Entry(points: $0, scale: 2)] }

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
var images: [[String: String]] = []
for entry in entries {
    let name = "icon_\(entry.points)x\(entry.points)" + (entry.scale == 2 ? "@2x" : "") + ".png"
    try render(pixels: entry.points * entry.scale).write(to: outputDirectory.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(entry.points)x\(entry.points)", "scale": "\(entry.scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(entries.count) icons to \(outputDirectory.path)")
