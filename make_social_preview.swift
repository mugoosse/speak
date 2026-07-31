#!/usr/bin/env swift
//
// Generates Assets/social-preview.png, the 1280x640 card GitHub renders when
// the repository is linked from anywhere else (Instagram bio, Slack, X, a
// message). Without one, GitHub falls back to a generic grey card that says
// nothing about the app.
//
// GitHub has no API for setting it. Upload the output by hand:
// Settings > General > Social preview > Edit.
//
// Colours are sampled from Assets/icon.png so the card and the app agree.
//
// Run: swift make_social_preview.swift

import AppKit

let W = 1280.0
let H = 640.0

// Sampled from Assets/icon.png: the I-beam mint, and the two near-blacks of
// the squircle body.
let MINT = NSColor(srgbRed: 0x9B / 255, green: 0xDC / 255, blue: 0xB0 / 255, alpha: 1)
let INK = NSColor(srgbRed: 0x0D / 255, green: 0x0D / 255, blue: 0x0C / 255, alpha: 1)
let INK_LIGHT = NSColor(srgbRed: 0x1E / 255, green: 0x1D / 255, blue: 0x1D / 255, alpha: 1)
let GREY = NSColor(srgbRed: 0x8A / 255, green: 0x8A / 255, blue: 0x88 / 255, alpha: 1)
let GREY_DIM = NSColor(srgbRed: 0x63 / 255, green: 0x63 / 255, blue: 0x61 / 255, alpha: 1)

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")

guard let icon = NSImage(contentsOf: assets.appendingPathComponent("icon.png")) else {
    FileHandle.standardError.write("could not read Assets/icon.png\n".data(using: .utf8)!)
    exit(1)
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// The bitmap context has its origin at the bottom left, so every layout number
// below is stated from the top and converted once, here, rather than each call
// site doing the subtraction and getting it wrong somewhere.
func fromTop(_ y: Double, height: Double = 0) -> Double { H - y - height }

// --- background ------------------------------------------------------------

// A vertical wash rather than flat black: flat fills read as a placeholder at
// this size, and the card is often shown against white chat backgrounds.
let bg = NSGradient(colors: [INK_LIGHT, INK],
                    atLocations: [0, 1],
                    colorSpace: .sRGB)!
bg.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -75)

// --- icon ------------------------------------------------------------------

// icon.png carries ~9.4% transparent padding on every side (macOS icon
// geometry), so the drawn box has to be bigger than the squircle you want.
let ICON_SIZE = 244.0
let ICON_X = 236.0
let iconCentre = NSPoint(x: ICON_X + ICON_SIZE / 2, y: fromTop(H / 2))

// Soft mint bloom behind the icon, tying the card to the app's one accent.
// The gradient has to reach full transparency well inside the path it fills,
// otherwise the fill's own edge shows up as a hard circle on this dark a
// background. Hence a bloom far wider than the glow it appears to produce.
let BLOOM = 900.0
let bloom = NSGradient(
    colors: [MINT.withAlphaComponent(0.13), MINT.withAlphaComponent(0.03), MINT.withAlphaComponent(0)],
    atLocations: [0, 0.42, 0.78],
    colorSpace: .sRGB)!
bloom.draw(in: NSBezierPath(ovalIn: NSRect(x: iconCentre.x - BLOOM / 2,
                                           y: iconCentre.y - BLOOM / 2,
                                           width: BLOOM, height: BLOOM)),
           relativeCenterPosition: .zero)

let iconRect = NSRect(x: ICON_X, y: fromTop((H - ICON_SIZE) / 2, height: ICON_SIZE),
                      width: ICON_SIZE, height: ICON_SIZE)
icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
          respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])

// --- text ------------------------------------------------------------------

let TEXT_X = 516.0

func draw(_ string: String, x: Double, top: Double,
          size: Double, weight: NSFont.Weight, color: NSColor, tracking: Double = 0) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .kern: tracking,
    ]
    let text = NSAttributedString(string: string, attributes: attrs)
    let height = text.size().height
    text.draw(at: NSPoint(x: x, y: fromTop(top, height: height)))
}

// The wordmark, then the promise, then the proof. Same order as the README,
// so someone arriving from the card is not re-oriented on landing.
draw("Speak", x: TEXT_X, top: 172, size: 92, weight: .bold, color: .white, tracking: -2)
draw("Talk instead of typing.", x: TEXT_X, top: 288, size: 44, weight: .medium, color: MINT)
draw("Anywhere on your Mac.", x: TEXT_X, top: 342, size: 44, weight: .medium, color: GREY)

// Hairline rule, the only structural element on the card.
MINT.withAlphaComponent(0.28).setFill()
NSRect(x: TEXT_X, y: fromTop(422, height: 2), width: 300, height: 2).fill()

draw("Free  ·  Runs offline  ·  No account  ·  Open source",
     x: TEXT_X, top: 448, size: 25, weight: .regular, color: GREY_DIM)

NSGraphicsContext.restoreGraphicsState()

// ---------------------------------------------------------------------------

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
let out = assets.appendingPathComponent("social-preview.png")
try png.write(to: out)
print("wrote Assets/social-preview.png (\(Int(W))x\(Int(H)))")
print("upload it at Settings > General > Social preview > Edit")
