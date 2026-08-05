import AppKit

/// Every appearance the menu bar icon can take, and the artwork for each.
///
/// The steady states use Speak's calling monkey as a monochrome template. It
/// is the compact counterpart to Listen's listening monkey, rather than a
/// stock microphone or a tiny version of the Dock artwork.
///
/// The exceptional states stay on system symbols. A download arrow and a
/// warning triangle are understood instantly; branding them would trade a
/// legible meaning for a recognisable one, which is the wrong way round when
/// something has gone wrong or the user is waiting.
///
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
        // A mascot stays more recognisable than a tiny slash or badge. The
        // menu's command text and tooltip carry the transient state instead.
        case .ready, .idle, .recording: return Self.mascot(side)
        }
    }

    // MARK: - Geometry

    /// 16pt square, which is the height Apple's own `mic` reports, so the
    /// drawn states and the symbol states sit at the same stature.
    private static let side: CGFloat = 16

    /// What the menu builder sizes its own symbols to.
    private static let menuSide: CGFloat = 15

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

    private static func mascot(_ side: CGFloat) -> NSImage {
        let key = CacheKey(icon: .ready, side: side)
        if let hit = cache[key] { return hit }

        let img = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:)) ?? NSImage()
        img.size = NSSize(width: side, height: side)
        img.isTemplate = true
        cache[key] = img
        return img
    }
}
