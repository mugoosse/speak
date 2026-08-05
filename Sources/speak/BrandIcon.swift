import AppKit

/// The full Good Pair character belongs to first-run and quiet, empty moments.
/// The persistent menu-bar affordance stays a monochrome seal, where status is
/// more important than brand colour.
@MainActor
enum BrandIcon {
    static func view(size: CGFloat, accessibilityLabel: String) -> NSImageView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel(accessibilityLabel)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: size).isActive = true
        icon.heightAnchor.constraint(equalToConstant: size).isActive = true
        return icon
    }
}
