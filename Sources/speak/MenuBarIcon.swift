import AppKit

/// Every appearance the menu bar icon can take, and the artwork for each.
///
/// The steady states draw Speak's own mark: the slab-serif I-beam from the app
/// icon. They used to be Apple's stock `mic`, which meant nothing in the menu
/// bar pointed at this app in particular. People could not tell whose icon it
/// was, and a microphone is the single most common thing to find up there.
///
/// The exceptional states stay on system symbols. A download arrow and a
/// warning triangle are understood instantly; branding them would trade a
/// legible meaning for a recognisable one, which is the wrong way round when
/// something has gone wrong or the user is waiting.
///
/// The mark is drawn rather than shipped as an asset because the app has no
/// asset catalog, and adding one would mean putting `actool` into a build that
/// already has to be coaxed through `xcodebuild`. Drawing also makes the slash
/// and the recording plate derivations of one path instead of three files to
/// keep in sync.
@MainActor
enum MenuBarIcon: Hashable {
    case ready
    case idle
    case recording
    case transcribing
    case downloading
    case failed

    /// For the status item itself.
    var image: NSImage { rendered(side: Self.side) }

    /// For a row inside the menu, where the system symbols alongside it are
    /// sized 15. Rasterised at that size rather than scaled down from `image`:
    /// resampling 16pt artwork to 15 undoes the pixel snapping below and the
    /// slabs come out soft.
    var menuImage: NSImage { rendered(side: Self.menuSide) }

    private func rendered(side: CGFloat) -> NSImage {
        switch self {
        case .transcribing: return Self.symbol("hourglass", side)
        case .downloading:  return Self.symbol("arrow.down.circle", side)
        case .failed:       return Self.symbol("exclamationmark.triangle", side)
        case .ready:        return Self.drawn(self, side) { S in beam(S).fill() }
        case .idle:         return Self.drawn(self, side) { S in
            beam(S).fill()
            slash(S)
        }
        case .recording:    return Self.drawn(self, side) { S in
            plate(S).fill()
            // Knocking the mark out of a filled slab reads as "live" across a
            // glance, in both menu bar appearances, without colour. A tint
            // would not survive a dark menu bar or a tinted desktop behind it.
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            beam(S, k: 0.70).fill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
        }
        }
    }

    // MARK: - Geometry

    /// 16pt square, which is the height Apple's own `mic` reports, so the
    /// drawn states and the symbol states sit at the same stature.
    private static let side: CGFloat = 16

    /// What the menu builder sizes its own symbols to.
    private static let menuSide: CGFloat = 15

    /// Proportions taken from `Assets/icon-master.png`: wide slabs, a stem
    /// about a third of their width. The stem is drawn as a capsule so it
    /// carries a hint of a microphone body at the size this is actually seen.
    private func beam(_ S: CGFloat, k: CGFloat = 1) -> NSBezierPath {
        // Snapped to whole pixels. The mark is nothing but axis-aligned bars,
        // and a slab that lands on a half pixel renders grey and soft at the
        // size this is actually read at. Half-extents are rounded rather than
        // widths, so the result stays symmetric about the centre.
        let cx = (S / 2).rounded()
        let h = (S * 0.86 * k).rounded()
        let halfW = (S * 0.66 * k / 2).rounded()
        let slab = max(1, (h * 0.12).rounded())
        let halfStem = max(1, (halfW * 0.37).rounded())
        let y0 = ((S - h) / 2).rounded()

        let p = NSBezierPath()
        p.append(roundedBar(cx: cx, y: y0, w: halfW * 2, h: slab))
        p.append(roundedBar(cx: cx, y: y0 + h - slab, w: halfW * 2, h: slab))
        // The stem runs the full height so its rounded ends finish inside the
        // slabs. Stopping short would leave a visible seam at one size and a
        // notch at another, because where "short" lands moves with the scale.
        p.append(NSBezierPath(
            roundedRect: NSRect(x: cx - halfStem, y: y0,
                                width: halfStem * 2, height: h),
            xRadius: halfStem, yRadius: halfStem))
        p.windingRule = .nonZero
        return p
    }

    private func roundedBar(cx: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: cx - w / 2, y: y, width: w, height: h),
                     xRadius: h * 0.34, yRadius: h * 0.34)
    }

    /// The system's slash treatment: a diagonal with a cleared gutter either
    /// side of it, so the line stays readable where it crosses the mark.
    private func slash(_ S: CGFloat) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: S * 0.11, y: S * 0.13))
        line.line(to: NSPoint(x: S * 0.89, y: S * 0.87))
        line.lineCapStyle = .round

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setBlendMode(.clear)
        line.lineWidth = S * 0.17
        line.stroke()
        ctx.setBlendMode(.normal)
        line.lineWidth = S * 0.085
        line.stroke()
    }

    private func plate(_ S: CGFloat) -> NSBezierPath {
        let r = NSRect(x: S * 0.07, y: S * 0.07, width: S * 0.86, height: S * 0.86)
        return NSBezierPath(roundedRect: r, xRadius: S * 0.25, yRadius: S * 0.25)
    }

    // MARK: - Rasterising

    private struct CacheKey: Hashable {
        let icon: MenuBarIcon
        let side: CGFloat
    }

    private static var cache: [CacheKey: NSImage] = [:]

    /// Matched on height, not fitted to a square: `exclamationmark.triangle`
    /// and `hourglass` are not square, and forcing them to be stretches them.
    private static func symbol(_ name: String, _ side: CGFloat) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage()
        guard img.size.height > 0 else { return img }
        img.size = NSSize(width: img.size.width * side / img.size.height, height: side)
        img.isTemplate = true
        return img
    }

    private static func drawn(_ icon: MenuBarIcon, _ side: CGFloat,
                              _ draw: (CGFloat) -> Void) -> NSImage {
        let key = CacheKey(icon: icon, side: side)
        if let hit = cache[key] { return hit }
        let img = NSImage(size: NSSize(width: side, height: side))
        // One representation per backing scale, each rasterised at its own
        // pixel grid. A single @2x rep downsampled onto a 1x display turns the
        // slabs to mush at the size they are read at.
        for scale in [1, 2] { img.addRepresentation(rep(side, scale: scale, draw)) }
        img.isTemplate = true
        cache[key] = img
        return img
    }

    private static func rep(_ side: CGFloat, scale: Int,
                            _ draw: (CGFloat) -> Void) -> NSBitmapImageRep {
        let px = Int(side) * scale
        let r = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!

        // Drawn in pixels, because every measurement above is a ratio of the
        // side. Setting `r.size` first would make the context point-based and
        // the mark would come out `scale` times too big.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: r)
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
        NSColor.black.setFill()
        NSColor.black.setStroke()
        draw(CGFloat(px))
        NSGraphicsContext.restoreGraphicsState()

        r.size = NSSize(width: side, height: side)
        return r
    }
}
