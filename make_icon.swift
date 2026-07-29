#!/usr/bin/env swift
//
// Generates Speak.icns.
//
// Rendered per size rather than downscaled from one master: the 16pt icon in
// System Settings needs its geometry snapped to its own pixel grid, and a
// downscaled 1024 master turns the waveform into grey mush at that size.
//
// Run: swift make_icon.swift   (writes Assets/Speak.icns)

import AppKit

// macOS icon geometry: the rounded square sits inside the canvas with ~10%
// breathing room, corner radius ~22.4% of the square's side.
let CONTENT_INSET = 0.094
let CORNER_RATIO = 0.224

/// Bar heights as a fraction of the square, center-outwards. Asymmetric on
/// purpose: a symmetric waveform reads as a graphic-equalizer logo, this reads
/// as speech.
let BARS: [Double] = [0.30, 0.58, 0.86, 0.46, 0.22]

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

    let s = Double(size)
    let inset = (s * CONTENT_INSET).rounded()
    let side = s - inset * 2
    let square = NSRect(x: inset, y: inset, width: side, height: side)
    let radius = side * CORNER_RATIO

    // Rounded-square body with a vertical gradient. Indigo to magenta keeps it
    // distinct from the blue waveform icons every other dictation app uses.
    let body = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.42, green: 0.24, blue: 0.93, alpha: 1),   // indigo
        NSColor(srgbRed: 0.85, green: 0.22, blue: 0.62, alpha: 1),   // magenta
    ])!
    gradient.draw(in: body, angle: -90)

    // Top sheen, the subtle lift Apple's icons have. Skipped below 32px where
    // it only muddies the gradient.
    if size >= 32 {
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        let sheen = NSGradient(colors: [
            NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0),
        ])!
        sheen.draw(in: NSRect(x: square.minX, y: square.midY,
                              width: square.width, height: square.height / 2),
                   angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }

    // Waveform. Bar width and gap are rounded to whole pixels so small sizes
    // stay crisp instead of smearing across half-pixels.
    let count = Double(BARS.count)
    let unit = side / (count * 2 + 1)          // bar + gap per column, plus edge
    var barW = unit.rounded()
    if barW < 1 { barW = 1 }
    let gap = barW
    let totalW = barW * count + gap * (count - 1)
    let startX = (square.midX - totalW / 2).rounded()

    NSColor.white.setFill()
    for (i, h) in BARS.enumerated() {
        var barH = (side * h).rounded()
        if barH < barW { barH = barW }         // never thinner than it is wide
        let x = startX + Double(i) * (barW + gap)
        let y = (square.midY - barH / 2).rounded()
        let bar = NSRect(x: x, y: y, width: barW, height: barH)
        // Rounded caps, but only when there are pixels to spare for them.
        let r = size >= 32 ? barW / 2 : 0
        NSBezierPath(roundedRect: bar, xRadius: r, yRadius: r).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// ---------------------------------------------------------------------------

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("Speak.iconset")

try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

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
print("wrote Assets/Speak.icns")
