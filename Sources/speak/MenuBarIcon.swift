import AppKit

/// Every appearance the menu bar icon can take, and the artwork for each.
///
/// The steady states draw Speak's Good Pair seal. Its square stamp carries 言
/// (speak): a compact, ownable companion to Listen's 聞 (hear), rather than a
/// stock microphone or a tiny version of the Dock artwork.
///
/// The exceptional states stay on system symbols. A download arrow and a
/// warning triangle are understood instantly; branding them would trade a
/// legible meaning for a recognisable one, which is the wrong way round when
/// something has gone wrong or the user is waiting.
///
/// The mark is drawn rather than shipped as an asset because the app has no
/// asset catalog, and adding one would mean putting `actool` into a build that
/// already has to be coaxed through `xcodebuild`. Drawing keeps the slash and
/// recording plate derivations of the same gesture instead of separate files.
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
        case .ready:        return Self.drawn(self, side) { S in seal(S) }
        case .idle:         return Self.drawn(self, side) { S in
            seal(S)
            slash(S)
        }
        case .recording:    return Self.drawn(self, side) { S in
            plate(S).fill()
            // The same seal inverts inside the existing live-state plate, so
            // recording remains legible without relying on colour.
            seal(S, inverted: true)
        }
        }
    }

    // MARK: - Geometry

    /// 16pt square, which is the height Apple's own `mic` reports, so the
    /// drawn states and the symbol states sit at the same stature.
    private static let side: CGFloat = 16

    /// What the menu builder sizes its own symbols to.
    private static let menuSide: CGFloat = 15

    /// Both apps share this exact 14/16-square stamp envelope. The character
    /// is the only difference, which makes the marks a family rather than two
    /// unrelated controls.
    private func seal(_ S: CGFloat, inverted: Bool = false) {
        let stamp = NSBezierPath(roundedRect: NSRect(x: S * 0.0625, y: S * 0.0625,
                                                      width: S * 0.875, height: S * 0.875),
                                 xRadius: S * 0.203, yRadius: S * 0.203)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if inverted {
            context.setBlendMode(.clear)
            stamp.fill()
            context.setBlendMode(.normal)
            drawCharacter("言", side: S)
        } else {
            stamp.fill()
            context.setBlendMode(.clear)
            drawCharacter("言", side: S)
            context.setBlendMode(.normal)
        }
    }

    private func drawCharacter(_ character: String, side: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont(name: "HiraginoSans-W8", size: side * 0.67)
            ?? NSFont.systemFont(ofSize: side * 0.67, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
        let glyph = NSAttributedString(string: character, attributes: attributes)
        glyph.draw(in: NSRect(x: side * 0.14, y: side * 0.145,
                              width: side * 0.72, height: side * 0.72))
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
