#!/usr/bin/env swift
//
// Generates the README preview and Speak.icns from icon-master.png.
//
// The generated artwork includes its own dark canvas around the squircle.
// Clipping every output size here keeps those corners transparent in Finder,
// System Settings and the About pane instead of baking in a black square.
//
// Run: swift make_icon.swift

import AppKit

// macOS icon geometry: the rounded square sits inside the canvas with ~10%
// breathing room, corner radius ~22.4% of the square's side.
let CONTENT_INSET = 0.094
let CORNER_RATIO = 0.224

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
let masterURL = assets.appendingPathComponent("icon-master.png")

guard let master = NSImage(contentsOf: masterURL) else {
    FileHandle.standardError.write(
        "could not read Assets/icon-master.png\n".data(using: .utf8)!)
    exit(1)
}

func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    let s = Double(size)
    let inset = (s * CONTENT_INSET).rounded()
    let side = s - inset * 2
    let square = NSRect(x: inset, y: inset, width: side, height: side)
    let radius = side * CORNER_RATIO

    // The source is deliberately clipped here rather than edited destructively:
    // icon-master.png remains the full-quality approved artwork, while every
    // generated consumer gets standard macOS padding and transparent corners.
    let body = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)
    body.addClip()
    master.draw(in: square, from: .zero, operation: .copy, fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high])

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// ---------------------------------------------------------------------------

let iconset = assets.appendingPathComponent("Speak.iconset")

try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let preview = drawIcon(size: 512)
guard let previewPNG = preview.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode README preview\n".data(using: .utf8)!)
    exit(1)
}
try previewPNG.write(to: assets.appendingPathComponent("icon.png"))

// (point size, scale) pairs iconutil expects.
let variants: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

for (pt, scale) in variants {
    let px = pt * scale
    let rep = drawIcon(size: px)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed to encode \(px)px\n".data(using: .utf8)!)
        exit(1)
    }
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try png.write(to: iconset.appendingPathComponent(name))
}

// iconutil does the .icns packing; there is no public API for it.
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path,
                  "-o", assets.appendingPathComponent("Speak.icns").path]
try proc.run()
proc.waitUntilExit()

guard proc.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
print("wrote Assets/icon.png and Assets/Speak.icns")
