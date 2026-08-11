import AppKit

@MainActor
final class AboutPane: Pane {
    private static let websiteURL = "https://maxgoespublic.com/"
    private static let sourceURL = "https://github.com/mugoosse/speak"
    weak var app: App?

    private var checkButton: NSButton!
    private var autoCheck: NSButton!
    private var result: NSTextField!
    private var lastChecked: NSTextField!

    /// A check can also be started from the menu bar, and a scheduled one
    /// starts on its own, so follow the updater rather than only reacting to
    /// this pane's button.
    override func viewWillAppear() {
        super.viewWillAppear()
        refreshUpdates()
        app?.updater.onChange = { [weak self] in self?.refreshUpdates() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        app?.updater.onChange = nil
    }

    override func build() {
        stack.addArrangedSubview(header())
        stack.addArrangedSubview(separator())

        // Said here as well as in the menu and the release notes, because these
        // are three different people: one who opened the menu, one who read an
        // update pane, and one who came looking for the version number.
        stack.addArrangedSubview(heading("Speak has moved into Listen"))
        let moved = NSTextField(wrappingLabelWithString:
            "Dictation is now a feature of Listen, which also records and transcribes "
            + "meetings. The speech model carries over on its own, because both apps "
            + "always used the same download. The shortcut and the sounds start at "
            + "their defaults, and your dictionary can be imported in one press from "
            + "Listen's Settings, Dictionary.\n\n"
            + "This is Speak's last release. It keeps working; it will not be updated "
            + "again.")
        moved.font = .systemFont(ofSize: 12)
        moved.preferredMaxLayoutWidth = 470
        stack.addArrangedSubview(moved)
        stack.addArrangedSubview(row([
            NSButton(title: "Get Listen", target: self, action: #selector(openListen)),
        ]))
        stack.addArrangedSubview(separator())

        stack.addArrangedSubview(heading("Updates"))

        checkButton = NSButton(title: "Check Now",
                               target: self, action: #selector(checkForUpdates))
        autoCheck = NSButton(checkboxWithTitle: "Check automatically",
                             target: self, action: #selector(toggleAutomatic))
        stack.addArrangedSubview(row([checkButton, autoCheck]))

        result = NSTextField(wrappingLabelWithString: "")
        result.font = .systemFont(ofSize: 12)
        result.preferredMaxLayoutWidth = 470
        stack.addArrangedSubview(result)

        lastChecked = caption("")
        stack.addArrangedSubview(lastChecked)

        stack.addArrangedSubview(caption(
            "Updates come from this project's GitHub releases. Each one is "
            + "checked against Speak's signing key before it is installed, and "
            + "the check itself sends nothing about you."))

        refreshUpdates()

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Setup"))
        let again = NSButton(title: "Run setup again…",
                             target: self, action: #selector(runSetupAgain))
        stack.addArrangedSubview(again)
        stack.addArrangedSubview(caption(
            "Walks through permissions, the shortcut and a test dictation. "
            + "It changes nothing you have already chosen, and it is the "
            + "quickest way to find out which part has stopped working."))

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
            "Speak is free software under the AGPL 3.0. It has no account and "
            + "no telemetry. It uses the network twice: to download a model you "
            + "chose, and to ask whether a newer version of Speak exists."))

        // The AGPL is a source-availability licence, so the About box is the
        // honest place to say where that source is.
        let source = NSButton(title: Self.sourceURL,
                              target: self, action: #selector(openSource))
        source.bezelStyle = .inline
        source.controlSize = .small
        stack.addArrangedSubview(source)
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

    /// Mirror the updater into the three controls, in place. Rebuilding the
    /// pane instead would replace the button under the cursor of someone who
    /// has just clicked it.
    private func refreshUpdates() {
        guard let updater = app?.updater, checkButton != nil else { return }

        checkButton.isEnabled = updater.canCheck
        autoCheck.state = updater.automaticallyChecks ? .on : .off

        switch updater.outcome {
        case .unknown:
            result.stringValue = ""
            result.isHidden = true
        case .checking:
            result.stringValue = "Checking…"
            result.textColor = .secondaryLabelColor
            result.isHidden = false
        case .upToDate(let why):
            result.stringValue = "● \(why)"
            result.textColor = .systemGreen
            result.isHidden = false
        case .available(let version):
            result.stringValue = "● Version \(version) is available."
            result.textColor = .systemBlue
            result.isHidden = false
        case .failed(let why):
            result.stringValue = "○ \(why)"
            result.textColor = .systemOrange
            result.isHidden = false
        }

        if let date = updater.lastCheck {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            f.doesRelativeDateFormatting = true
            lastChecked.stringValue = "Last checked \(f.string(from: date))."
        } else {
            lastChecked.stringValue = "Not checked yet."
        }
    }

    @objc private func openListen() {
        guard let url = URL(string: "https://mugoosse.github.io/listen/") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkForUpdates() {
        app?.updater.checkForUpdates(self)
        refreshUpdates()
    }

    @objc private func toggleAutomatic(_ sender: NSButton) {
        app?.updater.automaticallyChecks = sender.state == .on
    }

    @objc private func openWebsite() {
        if let url = URL(string: Self.websiteURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func runSetupAgain() {
        // From the top, not from wherever the resume position happens to be:
        // reaching for this means something is wrong, and the earlier steps
        // are where the answer usually is.
        Settings.onboardingStep = 0
        app?.startOnboarding()
    }

    @objc private func openSource() {
        if let url = URL(string: Self.sourceURL) { NSWorkspace.shared.open(url) }
    }
}
