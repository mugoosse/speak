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
    /// The model step's download line and bar, updated in place between
    /// rebuilds so the radio buttons above them are not replaced under the
    /// cursor of someone trying to click one.
    private weak var liveStatusLine: NSTextField?
    private weak var liveProgressBar: NSProgressIndicator?
    private var step = 0
    private var onFinish: (() -> Void)?

    private var body: NSStackView!
    private var titleLabel: NSTextField!
    private var backButton: NSButton!
    private var nextButton: NSButton!
    private var rail: NSStackView!

    private struct Step {
        let title: String
        let build: (Onboarding, NSStackView) -> Void
        /// Takes the window so a step can consult live app state, not
        /// just global permission checks.
        let canAdvance: (Onboarding) -> Bool
        /// A label for the primary button when the step is not yet
        /// satisfied, naming the thing to do instead of a bare
        /// "Continue" the user cannot press yet. nil means Continue, and a
        /// step that is not satisfied and offers no action leaves the
        /// button disabled: there is genuinely nothing to press.
        let action: ((Onboarding) -> String?)?
    }

    /// Positions in `steps`. The primary button's action is dispatched by
    /// index, and resuming has to know where the model step is, so these move
    /// with the array below.
    private enum At {
        static let mic = 1, accessibility = 2, model = 3
    }

    private var steps: [Step] {
        [
            .init(title: "Welcome to Speak",
                  build: { $0.buildWelcome($1) },
                  canAdvance: { _ in true },
                  action: nil),
            .init(title: "Microphone access",
                  build: { $0.buildMic($1) },
                  canAdvance: { _ in Permissions.microphone },
                  action: { _ in Permissions.microphone ? nil : "Request microphone access" }),
            .init(title: "Accessibility access",
                  build: { $0.buildAccessibility($1) },
                  canAdvance: { _ in Permissions.accessibility },
                  action: { _ in Permissions.accessibility ? nil : "Open Privacy & Security" }),
            // Not `true`. Advancing mid-download landed people on "you're set"
            // with an engine that could not transcribe anything, and the
            // shortcut then did nothing for several minutes with no
            // explanation. The next step dictates for real, so it needs a
            // working engine anyway.
            .init(title: "Speech model",
                  build: { $0.buildModel($1) },
                  canAdvance: { $0.owner?.status.isReady ?? false },
                  // The button is the consent for the download, so it names
                  // the engine and only appears once one has been chosen.
                  // While a download runs it is nothing: the progress bar is
                  // the answer to "what now", and a live button next to it
                  // would only invite a click that has to be refused.
                  action: { o in
                      guard Settings.modelChosen else { return nil }
                      switch o.owner?.status {
                      case .idle:
                          let c = Settings.choice
                          return c.isDownloaded
                              ? "Set up \(c.title)"
                              : "Download \(c.title) "
                                + "(\(ModelChoice.humanBytes(c.approxBytes)))"
                      case .failed: return "Try again"
                      default:      return nil
                      }
                  }),
            // Telling someone the shortcut works is not the same as showing
            // them. This step is the only proof that the permissions, the
            // event tap, the microphone and the model all line up, and it
            // catches a broken chord while there is still a window to fix it
            // in.
            .init(title: "Try it out",
                  build: { $0.buildTryIt($1) },
                  canAdvance: { $0.didDictate },
                  action: nil),
            .init(title: "You're set",
                  build: { $0.buildDone($1) },
                  canAdvance: { _ in true },
                  action: nil),
        ]
    }

    /// Set once a dictation has actually produced text in this window.
    private var didDictate = false
    /// Survives a rebuild. The text view is recreated whenever the body is
    /// rebuilt, so the transcript has to live outside it or the user's own
    /// words vanish the moment the step re-renders.
    private var tryItText = ""
    private weak var tryItField: NSTextView?
    private weak var tryItResult: NSTextField?
    private var micHelpOpen = false
    private var axHelpOpen = false
    private var tryHelpOpen = false
    private var languagesOpen = false
    private weak var chordChip: NSTextField?
    private weak var changeButton: NSButton?

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
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        // No title text. Every step already carries a large heading saying
        // exactly where you are, so a title bar repeating "Speak Setup" above
        // "Welcome to Speak" says the same thing twice and makes the window
        // feel like a utility rather than a first impression. The transparent
        // bar lets the content run to the top edge.
        w.title = ""
        w.titlebarAppearsTransparent = true
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
        root.spacing = 22
        root.edgeInsets = NSEdgeInsets(top: 34, left: 42, bottom: 26, right: 42)

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
        root.addArrangedSubview(titleLabel)

        body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 20
        root.addArrangedSubview(body)

        root.addArrangedSubview(NSView())        // spacer pushes controls down

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.alignment = .centerY

        rail = NSStackView()
        rail.orientation = .horizontal
        rail.spacing = 6
        rail.alignment = .centerY
        controls.addArrangedSubview(rail)

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
                                        constant: -84).isActive = true

        w.contentView = root
        window = w

        // Resume rather than restart. The model step can sit on a multi-minute
        // download, and losing that position because someone quit is the
        // difference between finishing setup and giving up on it.
        step = min(max(Settings.onboardingStep, 0), steps.count - 1)

        // An engine that is already on disk is loaded on the way in, whichever
        // step we land on. Nothing else on this path would ask for one, and the
        // steps after the model step need a working engine: without this a
        // relaunch left the model idle forever while "Try it out" waited for a
        // readiness nothing was working towards, with Continue disabled and no
        // way out. A download is never started here, only by its button.
        let haveEngine = Settings.modelChosen && Settings.choice.isDownloaded
        if haveEngine { owner?.startModelLoadIfIdle() }
        // Nothing to resume with, so resume where it can be fetched. The same
        // dead end otherwise: the later steps cannot load an engine and the
        // model step is the only place that asks for one.
        if step > At.model, !haveEngine { step = At.model }

        // A regular app for the duration: this window is unrecoverable if it
        // falls behind a System Settings pane, and .floating alone does not
        // give it a Dock icon or an app-switcher entry to get back to. Undone
        // when setup ends.
        NSApp.setActivationPolicy(.regular)

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
                    if let s = self.owner?.status {
                        self.liveStatusLine?.stringValue = s.summary
                        if let bar = self.liveProgressBar, let f = s.fraction {
                            if bar.isIndeterminate {
                                bar.stopAnimation(nil)
                                bar.isIndeterminate = false
                            }
                            bar.doubleValue = f
                        }
                    }
                    self.updateControls()
                }
            }
        }
    }

    // MARK: - Steps

    private func buildWelcome(_ v: NSStackView) {
        v.addArrangedSubview(BrandIcon.view(size: 64, accessibilityLabel: "Speak mascot"))
        // What you get, not what the app is. Three lines, in the order someone
        // actually cares about them.
        v.addArrangedSubview(bullet("mic.fill", "Talk instead of typing",
            "Press a shortcut, say a sentence, press it again."))
        v.addArrangedSubview(bullet("bolt.fill", "Fast enough to not think about",
            "About 35 ms for a six-second sentence."))
        v.addArrangedSubview(bullet("lock.fill", "Nothing leaves this Mac",
            "No account, no subscription, no telemetry."))
        // No download warning here any more, because continuing no longer
        // starts one. It used to: the default engine began fetching 2.4 GB as
        // you left this screen, which spent the bandwidth of anyone who would
        // have picked a different engine two steps later, or none at all.
        // Nothing replaces it. Promising not to download is still a sentence
        // about downloading, on the one screen that has nothing to do with it,
        // and the model step makes the promise by simply not doing it.
        v.addArrangedSubview(hint(
            "Setup takes a minute: two permissions, one speech model, and a "
            + "shortcut. You can stop and come back."))
    }

    /// An icon in a tile, a claim, and the evidence for it.
    ///
    /// The tile is what makes three symbols of different widths read as a
    /// column: a bare glyph aligns either by its left edge or its centre, and
    /// neither looks deliberate when the shapes differ as much as a bolt and a
    /// lock. A uniform rounded square gives every row the same visual weight
    /// and the same left edge, and the glyph can then be centred inside it
    /// where it belongs.
    private func bullet(_ symbol: String, _ title: String, _ detail: String) -> NSView {
        let box = NSView()

        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 14
        tile.layer?.cornerCurve = .continuous
        // Derived from labelColor rather than a fixed grey, so the tile stays
        // subtle in both light and dark appearance without a second palette.
        tile.layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(0.09).cgColor
        tile.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(tile)

        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        let image = (NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage()).withSymbolConfiguration(config)
        let icon = NSImageView(image: image ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(icon)

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 15, weight: .semibold)
        t.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(t)

        let d = NSTextField(wrappingLabelWithString: detail)
        d.font = .systemFont(ofSize: 13)
        d.textColor = .secondaryLabelColor
        d.preferredMaxLayoutWidth = 440
        d.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(d)

        // Pulls the container as short as its children allow. Without a
        // low-priority zero height there is nothing telling Auto Layout to
        // prefer the smallest fitting size.
        let squeeze = box.heightAnchor.constraint(equalToConstant: 0)
        squeeze.priority = .defaultLow

        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            tile.topAnchor.constraint(equalTo: box.topAnchor),
            tile.widthAnchor.constraint(equalToConstant: 52),
            tile.heightAnchor.constraint(equalToConstant: 52),

            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),

            // The text block is centred against the tile rather than pinned to
            // its top, so a one-line and a two-line row both sit level with it.
            t.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 18),
            t.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            t.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),

            d.leadingAnchor.constraint(equalTo: t.leadingAnchor),
            d.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 3),
            d.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
            // The row is exactly as tall as its tallest child. Both of these
            // were lessThanOrEqualTo, which pins nothing: the container's
            // height was ambiguous, so the first row silently absorbed all the
            // stack's slack and opened a hole the size of a paragraph.
            box.bottomAnchor.constraint(greaterThanOrEqualTo: tile.bottomAnchor),
            box.bottomAnchor.constraint(greaterThanOrEqualTo: d.bottomAnchor),
            squeeze,
        ])

        box.setAccessibilityLabel("\(title). \(detail)")
        return box
    }

    private func buildMic(_ v: NSStackView) {
        v.addArrangedSubview(paragraph("Speak needs the microphone to hear you."))
        v.addArrangedSubview(status(Permissions.microphone,
                                    granted: "Microphone access granted.",
                                    pending: "Waiting for permission…"))
        // Troubleshooting is hidden until asked for, and gone entirely once
        // the permission lands: an offer of help under a green tick is an
        // invitation to doubt something that already worked.
        if !Permissions.microphone {
            v.addArrangedSubview(help("Not working?", showing: "troubleshooting",
                                      expanded: micHelpOpen,
                                      toggle: #selector(toggleMicHelp)) { inner in
                inner.addArrangedSubview(self.hint(
                    "If no prompt appears, macOS has remembered an earlier "
                    + "refusal. Open Privacy & Security, then Microphone, and "
                    + "switch Speak on."))
            })
        }
    }

    private func buildAccessibility(_ v: NSStackView) {
        v.addArrangedSubview(paragraph(
            "The shortcut is a chord of modifier keys, which macOS only "
            + "delivers to apps trusted for Accessibility."))
        v.addArrangedSubview(status(Permissions.accessibility,
                                    granted: "Accessibility access granted.",
                                    pending: "Switch Speak on in the list, then come back."))

        if !Permissions.accessibility {
            v.addArrangedSubview(help("Not working?", showing: "troubleshooting",
                                      expanded: axHelpOpen,
                                      toggle: #selector(toggleAxHelp)) { inner in
            // The guaranteed remedy, offered rather than described.
            //
            // A granted Accessibility toggle does not always reach a process
            // that is already running: the trust check can answer from a
            // cached result, and a TCC entry created against a bundle that has
            // since been replaced no longer matches the app asking. Both look
            // identical from here, and both are cured by starting again.
                inner.addArrangedSubview(self.hint(
                    "macOS sometimes does not tell a running app that its "
                    + "permission changed, and it keeps a stale entry after an "
                    + "app is replaced."))
                let relaunch = NSButton(title: "Relaunch Speak",
                                        target: self,
                                        action: #selector(self.relaunchApp))
                inner.addArrangedSubview(relaunch)
                inner.addArrangedSubview(self.hint(
                    "Still nothing? In the list, select Speak, remove it with "
                    + "the minus button, then add it again."))
            })
        }
    }

    /// A collapsed row, "Not working?" or similar, that reveals detail when
    /// clicked. `noun` names what is being revealed, for the screen reader.
    ///
    /// Every one of these steps succeeds on the first try for most people.
    /// Showing three paragraphs of recovery advice to all of them, permanently,
    /// buys nothing and makes a two-click step look precarious. The same is
    /// true of a list of 25 languages that most people do not need to read.
    ///
    /// The open flags these read are deliberately absent from
    /// `structuralKey()`. Toggling one re-renders and records the new key, and
    /// since nothing else moves, the timer finds the key unchanged and leaves
    /// the disclosure open instead of folding it shut under the reader.
    private func help(_ title: String, showing noun: String,
                      expanded: Bool, toggle: Selector,
                      _ build: (NSStackView) -> Void) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10

        // A drawn chevron rather than "▸". The text arrows come from a
        // different family than the label and render visibly smaller than the
        // type they sit next to; a symbol configured at the label's point size
        // matches it exactly.
        let disclose = NSButton(title: title, target: self, action: toggle)
        disclose.image = (NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil) ?? NSImage())
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        disclose.imagePosition = .imageLeading
        disclose.bezelStyle = .inline
        disclose.controlSize = .small
        disclose.setAccessibilityLabel(
            (expanded ? "Hide " : "Show ") + noun)
        column.addArrangedSubview(disclose)

        if expanded {
            let inner = NSStackView()
            inner.orientation = .vertical
            inner.alignment = .leading
            inner.spacing = 10
            inner.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 0)
            build(inner)
            column.addArrangedSubview(inner)
        }
        return column
    }

    /// Lines the given view up with the indented hint under a radio button,
    /// so a disclosure belonging to one engine reads as part of that engine's
    /// entry rather than as a control for the list.
    private func indented(_ view: NSView) -> NSView {
        let box = NSStackView(views: [view])
        box.orientation = .horizontal
        box.alignment = .top
        box.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        return box
    }

    @objc private func toggleMicHelp() { micHelpOpen.toggle(); render() }
    @objc private func toggleAxHelp() { axHelpOpen.toggle(); render() }
    @objc private func toggleLanguages() { languagesOpen.toggle(); render() }

    private func buildModel(_ v: NSStackView) {
        // Loading, never fetching. Weights already on disk cost seconds and no
        // bandwidth, so that engine is made ready without being asked for;
        // anything that would download waits for the button. Arriving here
        // with a chosen, downloaded engine and nothing loading is otherwise a
        // dead end, since this step gates on readiness.
        if Settings.modelChosen, Settings.choice.isDownloaded {
            owner?.startModelLoadIfIdle()
        }

        v.addArrangedSubview(paragraph(
            "Speech recognition runs entirely on this Mac. Choose which engine "
            + "does the work; you can change it later in Settings."))

        for choice in ModelChoice.all {
            let b = NSButton(radioButtonWithTitle: choice.title,
                             target: self, action: #selector(pickModel(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(choice.id)
            // Nothing is selected until the user selects something. The
            // default is a fallback, not an answer, and showing it as a filled
            // radio button asks for a 2.4 GB download on behalf of somebody
            // who has not yet read the line underneath it.
            b.state = Settings.modelChosen && choice.id == Settings.choice.id
                ? .on : .off
            v.addArrangedSubview(b)

            var line = choice.detail
            if choice.kind == .parakeet && choice.isDownloaded { line += " · already downloaded" }
            v.addArrangedSubview(hint("     " + line))

            // "25 languages" is only useful if you can find out whether yours
            // is one of them, and this is the screen where that decides which
            // 2.4 GB you fetch.
            if !choice.languages.isEmpty {
                let list = indented(help(
                    "Which languages?", showing: "the language list",
                    expanded: languagesOpen, toggle: #selector(toggleLanguages)
                ) { inner in
                    inner.addArrangedSubview(self.hint(
                        choice.languages.joined(separator: " · ")))
                    inner.addArrangedSubview(self.hint(
                        "Detected automatically, not chosen: this model has no "
                        + "language setting."))
                })
                v.addArrangedSubview(list)
            }
        }

        // Nothing below this line means anything until an engine is named.
        guard Settings.modelChosen else {
            v.addArrangedSubview(status(false, granted: "",
                                        pending: "Choose an engine to continue."))
            return
        }

        let state = owner?.status ?? ModelStatus.loading
        switch state {
        case .idle:
            // Chosen, not yet fetched. The button below is what starts it, so
            // this line says what it will cost rather than pretending the wait
            // is already under way.
            // The size is on the button and in the line under the radio
            // button; a third copy of it here would be the same number in
            // three places, one of which will eventually be wrong.
            let choice = Settings.choice
            v.addArrangedSubview(status(false, granted: "", pending: choice.isDownloaded
                ? "\(choice.title) is on this Mac already."
                : "\(choice.title) has not been downloaded yet."))
            if !choice.isDownloaded {
                v.addArrangedSubview(hint(
                    "It takes a few minutes on a normal connection, and it is "
                    + "the only time Speak uses the internet. You can switch "
                    + "engines above until you press the button."))
            }
        case .downloading, .loading:
            // Kept so the timer can tick progress without rebuilding the radio
            // buttons above it.
            let (line, label) = statusRow(false, state.summary)
            liveStatusLine = label
            v.addArrangedSubview(line)

            let bar = NSProgressIndicator()
            bar.controlSize = .small
            bar.style = .bar
            bar.minValue = 0
            bar.maxValue = 1
            // Indeterminate until the first callback: a determinate bar
            // sitting at zero reads as stuck.
            if let fraction = state.fraction {
                bar.isIndeterminate = false
                bar.doubleValue = fraction
            } else {
                bar.isIndeterminate = true
                bar.startAnimation(nil)
            }
            bar.widthAnchor.constraint(equalToConstant: 380).isActive = true
            liveProgressBar = bar
            v.addArrangedSubview(bar)

            // The gate on this step is deliberate, but staring at a bar for
            // ten minutes is not. Apple Intelligence needs no download, so it
            // is a real way out rather than a consolation prize, and saying so
            // here is the difference between a wait and a dead end.
            //
            // Downloading only. Loading weights already on disk takes seconds
            // and has no download to stop, so the same offer there is an
            // escape route from a wait that is already over.
            if case .downloading = state, ModelChoice.appleAvailable {
                v.addArrangedSubview(hint(
                    "Do not want to wait? Pick Apple Intelligence above: it "
                    + "needs no download and works immediately. Choosing it "
                    + "stops this download, and you can start it again any "
                    + "time by switching back in Settings."))
            }
        case .ready:
            v.addArrangedSubview(status(true, granted: "Ready to dictate.", pending: ""))
        case .failed(let why):
            // No Try again button here. The primary button says it now, and
            // two buttons a centimetre apart doing the same thing is a
            // question about which one is the real one.
            v.addArrangedSubview(status(false, granted: "", pending: why))
        }
    }

    @objc private func pickModel(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let choice = ModelChoice.named(id) else { return }
        // Not an early return on "same as the current choice". The first pick
        // is usually the engine that was already the fallback, and treating it
        // as a no-op left the radio button filled, the choice unrecorded and
        // Continue disabled with nothing to explain why.
        let firstPick = !Settings.modelChosen
        guard firstPick || choice.id != Settings.choice.id else { return }
        Settings.choice = choice

        // Choosing is not agreeing to a download; the button below is where
        // that is asked. An engine already on disk has nothing to agree to, so
        // it loads at once and the button becomes a plain Continue.
        if choice.isDownloaded {
            owner?.reloadModel()
        } else {
            owner?.idleModel()
        }
        render()
    }

    /// The primary button on the model step: fetch and load the chosen engine,
    /// and the way back from a failed attempt.
    @objc private func startModel() {
        owner?.reloadModel()
        render()
    }

    private func buildTryIt(_ v: NSStackView) {
        // Arm the tap here rather than at the end of onboarding: without it the
        // shortcut does nothing on this step and the user concludes the app is
        // broken at the exact moment they first try it.
        owner?.installHotkeyIfNeeded()

        v.addArrangedSubview(paragraph(
            "Press the shortcut, say a sentence, then press it again. "
            + "What you said should appear below."))

        // The chord and the means to change it, next to the thing that tests
        // it. A separate step for choosing a shortcut showed this same chip and
        // this same button, then asked you to press it on the following screen:
        // two steps to do what reads as one action.
        let chip = NSTextField(labelWithString: Shortcut.description)
        chip.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        chip.setAccessibilityLabel("Current shortcut: \(Shortcut.description)")
        chordChip = chip

        let change = NSButton(title: "Change…", target: self, action: #selector(record))
        changeButton = change

        let chordRow = NSStackView(views: [chip, change])
        chordRow.orientation = .horizontal
        chordRow.alignment = .centerY
        chordRow.spacing = 16
        v.addArrangedSubview(chordRow)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 92).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 520).isActive = true

        let text = NSTextView()
        text.isEditable = true
        text.font = .systemFont(ofSize: 13)
        text.string = tryItText
        text.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = text
        tryItField = text
        v.addArrangedSubview(scroll)

        let (resultRow, resultLabel) = statusRow(didDictate, didDictate
            ? "That worked. The transcript is on your clipboard too."
            : "Waiting for your first dictation.")
        tryItResult = resultLabel
        v.addArrangedSubview(resultRow)

        if !didDictate {
            v.addArrangedSubview(help("Not working?", showing: "troubleshooting",
                                      expanded: tryHelpOpen,
                                      toggle: #selector(toggleTryHelp)) { inner in
                inner.addArrangedSubview(self.hint(
                    "The chord has to be held together and released. Left and "
                    + "right modifiers count separately, so \u{2303} left and "
                    + "\u{2303} right are different shortcuts."))
                inner.addArrangedSubview(self.hint(
                    "If it still does nothing, Accessibility is the usual "
                    + "cause: remove Speak from that list and add it again."))
            })
        }

        // Route finished transcripts here for as long as this step is shown.
        owner?.onTranscript = { [weak self] transcript in
            guard let self else { return }
            guard let transcript, !transcript.isEmpty else {
                self.tryItResult?.stringValue = "Nothing was heard. Try again, a little louder."
                return
            }
            self.didDictate = true
            self.tryItText = self.tryItText.isEmpty
                ? transcript : self.tryItText + " " + transcript
            self.tryItField?.string = self.tryItText
            self.tryItResult?.stringValue =
                "That worked. The transcript is on your clipboard too."
            self.tryItResult?.textColor = .systemGreen
            self.updateControls()
        }
    }

    @objc private func toggleTryHelp() { tryHelpOpen.toggle(); render() }

    /// Captures the next chord in place, rather than sending the user to
    /// Settings in the middle of setup. Hold a combination; it commits on
    /// release, which is what lets a chord be built one key at a time.
    @objc private func record() {
        guard let owner else { return }
        var widest: UInt64 = 0
        chordChip?.stringValue = "press and hold…"
        changeButton?.isEnabled = false

        var pending: DispatchWorkItem?

        let commit: (UInt64, Int?) -> Void = { [weak self] mask, code in
            guard let self else { return }
            owner.shortcutRecorder = nil
            self.changeButton?.isEnabled = true
            if Shortcut.isUsable(mask, code) {
                Shortcut.set(mask: mask, keyCode: code)
            } else {
                NSSound.beep()
            }
            self.chordChip?.stringValue = Shortcut.description
            owner.refreshMenu()
        }

        owner.shortcutRecorder = { [weak self] flags, keyCode in
            guard let self else { return }
            let held = flags.rawValue & Modifier.tracked

            if let keyCode {                // a character key ends it at once
                pending?.cancel()
                commit(held, keyCode)
                return
            }
            if held != 0 {
                pending?.cancel()
                pending = nil
                if held.nonzeroBitCount > widest.nonzeroBitCount,
                   held.nonzeroBitCount <= Shortcut.maxKeys {
                    widest = held
                }
                // The widest chord seen, not what is held at this instant.
                // Showing the live value makes the chip count back down as the
                // keys are released: fn + shift, then fn, then fn + shift
                // again when it commits. The chord being built never shrinks,
                // so neither should its display.
                self.chordChip?.stringValue = Modifier.describe(widest)
                    + (held.nonzeroBitCount > Shortcut.maxKeys
                       ? "   (max \(Shortcut.maxKeys))" : "")
                return
            }
            // Everything released. Wait a moment before committing: three keys
            // rarely go down in one event, and a brief all-clear between
            // presses would otherwise cut the chord short.
            pending?.cancel()
            let work = DispatchWorkItem { commit(widest, nil) }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    /// Quit and start again, keeping the saved onboarding position so the
    /// user lands back on this step rather than at the beginning.
    @objc private func relaunchApp() {
        Settings.onboardingStep = step
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // A short delay so this process is gone before the new one starts;
        // launching a second copy of a running app just activates the first.
        task.arguments = ["-c", "sleep 1; open \"\(url.path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }


    private func buildDone(_ v: NSStackView) {
        v.addArrangedSubview(BrandIcon.view(size: 44, accessibilityLabel: "Speak is ready"))
        v.addArrangedSubview(paragraph(
            "Press \(Shortcut.description) to start, talk, press it again to "
            + "stop. The transcript is pasted where you are typing, and stays "
            + "on the clipboard. Turn off auto-paste in Settings to place it "
            + "yourself with ⌘V."))
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

    private func status(_ ok: Bool, granted: String, pending: String) -> NSView {
        statusRow(ok, ok ? granted : pending).row
    }

    /// A symbol and a line of text, returning both so a caller that updates the
    /// text every second does not have to rebuild the row.
    ///
    /// These were text bullets, "● " and "○ ". At 12pt on a dark background a
    /// hollow circle reads as a tick, so a step that was still waiting looked
    /// like a step that had succeeded. A drawn symbol cannot be misread that
    /// way, and it matches the checkmarks in the step rail.
    private func statusRow(_ ok: Bool, _ text: String) -> (row: NSView, label: NSTextField) {
        let size: CGFloat = 12
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        let name = ok ? "checkmark.circle.fill" : "circle.dotted"
        let icon = NSImageView(image: (NSImage(
            systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage()).withSymbolConfiguration(config) ?? NSImage())
        icon.contentTintColor = ok ? .systemGreen : .tertiaryLabelColor

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = ok ? .systemGreen : .secondaryLabelColor

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 7
        row.setAccessibilityLabel((ok ? "Done. " : "Waiting. ") + text)
        return (row, label)
    }

    // MARK: - Navigation

    private func render() {
        let s = steps[step]
        titleLabel.stringValue = s.title
        body.arrangedSubviews.forEach {
            body.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        liveStatusLine = nil          // rebuilt by buildModel if this step has one
        liveProgressBar = nil
        // Only the try-it step wants transcripts. Leaving it wired up would
        // keep writing into a text view that is no longer on screen, and
        // hold this window alive after it closes.
        owner?.onTranscript = nil
        s.build(self, body)
        renderedKey = structuralKey()
        updateControls()
    }

    /// Only the buttons and dots. It must never call `render()`: `render()`
    /// ends by calling this, so the two would call each other.
    private func updateControls() {
        guard step < steps.count else { return }
        let s = steps[step]
        let ready = s.canAdvance(self)

        backButton.isHidden = step == 0
        // Name the thing to do rather than offering a Continue that cannot be
        // pressed. "Grant microphone access" answers "what am I waiting for?"
        // where a greyed-out Continue only poses it.
        let pending = ready ? nil : s.action?(self)
        nextButton.title = pending
            ?? (step == steps.count - 1 ? "Done" : "Continue")
        // A step with its own action button stays clickable so it can trigger
        // that action; otherwise the button is the gate.
        nextButton.isEnabled = ready || pending != nil
        buildRail()

        window?.setAccessibilityLabel(
            "Speak setup, step \(step + 1) of \(steps.count): \(s.title)")
        nextButton.setAccessibilityLabel(nextButton.title)
    }

    /// Filled circles behind, a ring on the current step, hollow ahead. Same
    /// information the text dots carried, in a form that reads as progress.
    private func buildRail() {
        rail.arrangedSubviews.forEach {
            rail.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        for i in 0..<steps.count {
            let name = i < step ? "checkmark.circle.fill"
                     : (i == step ? "circle.inset.filled" : "circle")
            let dot = NSImageView(image: NSImage(
                systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
            dot.contentTintColor = i <= step ? .controlAccentColor : .tertiaryLabelColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 13).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 13).isActive = true
            rail.addArrangedSubview(dot)
        }
        rail.setAccessibilityLabel("Step \(step + 1) of \(steps.count)")
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
        // Distinct from a download in progress, which is the difference
        // between "press the button" and a progress bar. Folded together, the
        // step that started a download kept the body it was built with, so the
        // bar was never created and the download ran invisibly.
        case .idle:   readiness = "idle"
        default:      readiness = "busy"
        }
        // The chosen engine is structural too: the lines under the radio
        // buttons name it and its download size, and "nothing chosen yet" is a
        // different screen from any of them.
        let engine = Settings.modelChosen ? Settings.choice.id : "unchosen"
        return "\(step)|\(steps[step].canAdvance(self))|\(readiness)|\(engine)"
    }

    @objc private func next() {
        // When the step is not satisfied the button is its action, not
        // navigation: pressing "Request microphone access" must request it.
        let s = steps[step]
        if !s.canAdvance(self), s.action?(self) != nil {
            switch step {
            case At.mic: requestMic()
            case At.accessibility: openAccessibility()
            case At.model: startModel()
            default: break
            }
            return
        }

        if step == steps.count - 1 {
            Settings.onboarded = true
            Settings.onboardingStep = 0      // finished, so do not resume here
            onFinish?()
            window?.close()
            return
        }
        step += 1
        Settings.onboardingStep = step
        // Nothing is started here. Leaving Welcome used to begin the default
        // engine's 2.4 GB download so it would overlap the permission steps,
        // which is a good trade only if the default is the engine you wanted.
        // For everyone else it was a few hundred megabytes of somebody's
        // connection spent on a model they were about to replace, and on a
        // slow or metered one it made the whole choice moot. The model step
        // asks first now.
        render()
    }

    @objc private func back() {
        guard step > 0 else { return }
        step -= 1
        Settings.onboardingStep = step
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
        Permissions.openAccessibilitySettings()
        // The grant happens in System Settings, in another app, possibly a
        // minute from now. Watch for it so the tap arms itself instead of
        // waiting for a relaunch.
        owner?.watchForAccessibility()
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
        owner?.onTranscript = nil
        owner?.shortcutRecorder = nil    // never leave the tap recording
        // Back to a menu bar app. Leaving it .regular would give Speak a
        // permanent Dock icon, which is the one thing it is meant not to have.
        NSApp.setActivationPolicy(.accessory)
        step = 0
        // Reaching the end is not required; permissions can be finished later
        // from Settings.
        //
        // An engine that can actually run is required, though, and this used to
        // ask only about permissions. `onboarded` is what makes the next launch
        // load a model without asking, so setting it for somebody who closed
        // this window before choosing meant the fallback quietly downloading
        // 2.4 GB at the next launch: the very thing the model step now refuses
        // to do. Left false, setup reopens on the model step and asks.
        if Permissions.allGranted, Settings.modelChosen, Settings.choice.isDownloaded {
            Settings.onboarded = true
        }
        onFinish?()
    }
}
