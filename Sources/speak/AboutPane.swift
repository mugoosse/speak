import AppKit

@MainActor
final class AboutPane: Pane {
    private static let websiteURL = "https://maxgoespublic.com/"

    override func build() {
        stack.addArrangedSubview(header())
        stack.addArrangedSubview(separator())

        stack.addArrangedSubview(heading("Made by"))
        let author = NSTextField(labelWithString: "Maxime Goossens")
        author.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(author)

        let site = NSButton(title: Self.websiteURL,
                            target: self, action: #selector(openWebsite))
        site.bezelStyle = .inline
        site.controlSize = .small
        stack.addArrangedSubview(site)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Built on"))
        stack.addArrangedSubview(caption(credits))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(caption(
            "Speak is MIT licensed. It has no account, no telemetry, and no "
            + "network access beyond downloading a model you chose."))
    }

    /// Icon, name and version, laid out the way an About box usually is.
    private func header() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 16

        if let icon = NSApp.applicationIconImage {
            let view = NSImageView(image: icon)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 72).isActive = true
            view.heightAnchor.constraint(equalToConstant: 72).isActive = true
            view.imageScaling = .scaleProportionallyUpOrDown
            row.addArrangedSubview(view)
        }

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4

        let name = NSTextField(labelWithString: "Speak")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        text.addArrangedSubview(name)

        let version = NSTextField(labelWithString: Self.versionString)
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        text.addArrangedSubview(version)

        let tagline = NSTextField(wrappingLabelWithString:
            "Push-to-talk dictation that runs entirely on your Mac.")
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor
        tagline.preferredMaxLayoutWidth = 340
        text.addArrangedSubview(tagline)

        row.addArrangedSubview(text)
        return row
    }

    /// Read from the bundle rather than hardcoded, so bumping the version in
    /// Info.plist is enough and this cannot go stale.
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        if let build, build != short { return "Version \(short) (\(build))" }
        return "Version \(short)"
    }

    private var credits: String {
        """
        Parakeet speech models by NVIDIA, CC-BY-4.0, converted for Apple \
        Silicon by mlx-community.

        Run through mlx-audio-swift and mlx-swift by Prince Canuma and the \
        MLX team at Apple.

        Apple Intelligence transcription uses the Speech framework built \
        into macOS.
        """
    }

    @objc private func openWebsite() {
        if let url = URL(string: Self.websiteURL) { NSWorkspace.shared.open(url) }
    }
}
