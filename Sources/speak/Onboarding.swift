import AppKit

/// First-run walkthrough.
///
/// Deliberately separate from Settings: onboarding is a linear sequence you
/// finish once, Settings is a reference surface you return to. Merging them
/// would mean either a settings window that nags, or an onboarding flow you
/// can wander out of halfway through.
@MainActor
final class Onboarding: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var refresh: Timer?
    /// `structuralKey()` when the body was last built. See `structuralKey()`.
    private var renderedKey: String?
    /// The model step's download line, updated in place between rebuilds.
    private weak var liveStatusLine: NSTextField?
    private var step = 0
    private var onFinish: (() -> Void)?

    private var body: NSStackView!
    private var titleLabel: NSTextField!
    private var backButton: NSButton!
    private var nextButton: NSButton!
    private var pageDots: NSTextField!

    private struct Step {
        let title: String
        let build: (Onboarding, NSStackView) -> Void
        let canAdvance: () -> Bool
    }

    private var steps: [Step] {
        [
            .init(title: "Welcome to Speak",
                  build: { $0.buildWelcome($1) },
                  canAdvance: { true }),
            .init(title: "Microphone access",
                  build: { $0.buildMic($1) },
                  canAdvance: { Permissions.microphone }),
            .init(title: "Accessibility access",
                  build: { $0.buildAccessibility($1) },
                  canAdvance: { Permissions.accessibility }),
            .init(title: "Speech model",
                  build: { $0.buildModel($1) },
                  canAdvance: { true }),
            .init(title: "You're set",
                  build: { $0.buildDone($1) },
                  canAdvance: { true }),
        ]
    }

    /// Set by the app so this step can show live download progress.
    weak var owner: App?

    func show(onFinish: (() -> Void)? = nil) {
        self.onFinish = onFinish
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Speak Setup"
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false
        // Accessory apps have no Dock icon or app-switcher entry, so a window
        // that falls behind a permission dialog is unrecoverable.
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 26, left: 30, bottom: 22, right: 30)

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(titleLabel)

        body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        root.addArrangedSubview(body)

        root.addArrangedSubview(NSView())        // spacer pushes controls down

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.alignment = .centerY

        pageDots = NSTextField(labelWithString: "")
        pageDots.font = .systemFont(ofSize: 13)
        pageDots.textColor = .tertiaryLabelColor
        controls.addArrangedSubview(pageDots)

        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        controls.addArrangedSubview(gap)

        backButton = NSButton(title: "Back", target: self, action: #selector(back))
        controls.addArrangedSubview(backButton)

        nextButton = NSButton(title: "Continue", target: self, action: #selector(next))
        nextButton.keyEquivalent = "\r"
        controls.addArrangedSubview(nextButton)

        root.addArrangedSubview(controls)
        controls.widthAnchor.constraint(equalTo: root.widthAnchor,
                                        constant: -60).isActive = true

        w.contentView = root
        window = w
        render()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        refresh = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Rebuild only when the body's structure actually changed.
                if self.renderedKey != self.structuralKey() {
                    self.render()
                } else {
                    if let line = self.liveStatusLine, let s = self.owner?.status {
                        line.stringValue = "○ " + s.summary
                    }
                    self.updateControls()
                }
            }
        }
    }

    // MARK: - Steps

    private func buildWelcome(_ v: NSStackView) {
        v.addArrangedSubview(paragraph(
            "Press a keyboard shortcut, talk, press it again. What you said "
            + "lands on your clipboard, ready to paste."))
        v.addArrangedSubview(paragraph(
            "Everything runs on this Mac. No account, no network, no "
            + "subscription. Your voice never leaves the machine."))
        v.addArrangedSubview(paragraph(
            "Two permissions are needed first. Both are granted once and "
            + "remembered across updates."))
    }

    private func buildMic(_ v: NSStackView) {
        v.addArrangedSubview(paragraph("Speak needs the microphone to hear you."))
        let b = NSButton(title: "Request access", target: self, action: #selector(requestMic))
        v.addArrangedSubview(b)
        v.addArrangedSubview(status(Permissions.microphone,
                                    granted: "Microphone access granted.",
                                    pending: "Not granted yet."))
        if !Permissions.microphone {
            v.addArrangedSubview(hint(
                "If no prompt appears, macOS has remembered an earlier refusal. "
                + "Open Privacy & Security > Microphone and switch Speak on."))
        }
    }

    private func buildAccessibility(_ v: NSStackView) {
        v.addArrangedSubview(paragraph(
            "The shortcut is a chord of modifier keys, which macOS only "
            + "delivers to apps trusted for Accessibility."))
        let b = NSButton(title: "Open Privacy & Security",
                         target: self, action: #selector(openAccessibility))
        v.addArrangedSubview(b)
        v.addArrangedSubview(status(Permissions.accessibility,
                                    granted: "Accessibility access granted.",
                                    pending: "Switch Speak on in the list, then come back."))
        if !Permissions.accessibility {
            v.addArrangedSubview(hint(
                "Already listed but still not working? Select Speak, remove it "
                + "with the minus button, then add it again. macOS keeps a "
                + "stale entry after an app is replaced."))
        }
    }

    private func buildModel(_ v: NSStackView) {
        v.addArrangedSubview(paragraph(
            "Speech recognition runs entirely on this Mac. Choose which engine "
            + "does the work; you can change it later in Settings."))

        for choice in ModelChoice.all {
            let b = NSButton(radioButtonWithTitle: choice.title,
                             target: self, action: #selector(pickModel(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(choice.id)
            b.state = choice.id == Settings.choice.id ? .on : .off
            v.addArrangedSubview(b)

            var line = choice.detail
            if choice.kind == .parakeet && choice.isDownloaded { line += " · already downloaded" }
            v.addArrangedSubview(hint("     " + line))
        }

        let state = owner?.status ?? ModelStatus.loading
        switch state {
        case .downloading, .loading:
            // Kept so the timer can tick the elapsed time without rebuilding
            // the radio buttons above it.
            let line = status(false, granted: "", pending: state.summary)
            liveStatusLine = line
            v.addArrangedSubview(line)
            v.addArrangedSubview(hint(
                "You can continue and close this window; the download keeps "
                + "going in the background."))
        case .ready:
            v.addArrangedSubview(status(true, granted: "Ready to dictate.", pending: ""))
        case .failed(let why):
            v.addArrangedSubview(status(false, granted: "", pending: why))
            v.addArrangedSubview(
                NSButton(title: "Try again", target: self, action: #selector(retry)))
        }
    }

    @objc private func pickModel(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let choice = ModelChoice.named(id),
              choice.id != Settings.choice.id else { return }
        Settings.choice = choice
        owner?.reloadModel()
        render()
    }

    @objc private func retry() {
        owner?.reloadModel()
        render()
    }

    private func buildDone(_ v: NSStackView) {
        v.addArrangedSubview(paragraph(
            "Press \(Shortcut.description) to start, talk, press it again to "
            + "stop. Paste with ⌘V."))
        v.addArrangedSubview(paragraph(
            "The menu bar icon shows what Speak is doing. Open Settings from "
            + "there to change the shortcut, switch models, or read back "
            + "everything you have dictated."))
    }

    // MARK: - Pieces

    private func paragraph(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: 13)
        t.preferredMaxLayoutWidth = 480
        return t
    }

    private func hint(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = 480
        return t
    }

    private func status(_ ok: Bool, granted: String, pending: String) -> NSTextField {
        let t = NSTextField(labelWithString: (ok ? "● " : "○ ") + (ok ? granted : pending))
        t.font = .systemFont(ofSize: 12)
        t.textColor = ok ? .systemGreen : .secondaryLabelColor
        return t
    }

    // MARK: - Navigation

    private func render() {
        let s = steps[step]
        titleLabel.stringValue = s.title
        body.arrangedSubviews.forEach {
            body.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        liveStatusLine = nil          // rebuilt by buildModel if this step has one
        s.build(self, body)
        renderedKey = structuralKey()
        updateControls()
    }

    /// Only the buttons and dots. It must never call `render()`: `render()`
    /// ends by calling this, so the two would call each other.
    private func updateControls() {
        guard step < steps.count else { return }
        let s = steps[step]
        backButton.isHidden = step == 0
        nextButton.title = step == steps.count - 1 ? "Done" : "Continue"
        nextButton.isEnabled = s.canAdvance()
        pageDots.stringValue = (0..<steps.count)
            .map { $0 == step ? "●" : "○" }.joined(separator: " ")
    }

    /// What the body's *structure* depends on. The timer rebuilds when this
    /// changes, so a permission landing or a download finishing updates the
    /// window without the user clicking anything.
    ///
    /// This compares state. The previous version sniffed the rendered text for
    /// a "○" and re-rendered whenever the step could also advance, which on the
    /// model step is permanently true while the download runs: `canAdvance` is
    /// `true` there by design and the pending line always starts with "○".
    /// Since `render()` calls `updateControls()`, that was unbounded
    /// recursion. The app hung on the first machine that reached this step
    /// without the model already cached, beachballing over the previous step
    /// because the run loop never got control back.
    ///
    /// The elapsed-time summary is deliberately *not* in this key. It changes
    /// every tick, and rebuilding the body every 0.8s for the length of a
    /// multi-minute download would leave the engine radio buttons being
    /// replaced under the user's cursor while they try to pick one. That line
    /// is updated in place instead.
    private func structuralKey() -> String {
        guard step < steps.count else { return "" }
        let readiness: String
        switch owner?.status {
        case .ready:  readiness = "ready"
        case .failed: readiness = "failed"
        default:      readiness = "busy"
        }
        return "\(step)|\(steps[step].canAdvance())|\(readiness)"
    }

    @objc private func next() {
        if step == steps.count - 1 {
            Settings.onboarded = true
            onFinish?()
            window?.close()
            return
        }
        step += 1
        render()
    }

    @objc private func back() {
        guard step > 0 else { return }
        step -= 1
        render()
    }

    @objc private func requestMic() {
        Permissions.requestMicrophone { [weak self] granted in
            Task { @MainActor in
                if !granted { Permissions.openMicrophoneSettings() }
                self?.render()
                self?.resurface()
            }
        }
    }

    @objc private func openAccessibility() {
        Permissions.promptAccessibility()
        // Settings takes focus; come back to the front once it has opened so
        // the remaining steps stay visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.resurface()
        }
    }

    /// The system permission dialogs steal focus, and an accessory app does not
    /// get it back on its own.
    private func resurface() {
        guard let w = window else { return }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ n: Notification) {
        refresh?.invalidate()
        refresh = nil
        window = nil
        step = 0
        // Reaching the end is not required; permissions can be finished later
        // from Settings.
        if Permissions.allGranted { Settings.onboarded = true }
        onFinish?()
    }
}
