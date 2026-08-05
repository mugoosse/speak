import AppKit

// ---------------------------------------------------------------------------
// Settings, as a native toolbar-tabbed window
// ---------------------------------------------------------------------------

/// The tabs, in the order they appear.
///
/// Named rather than numbered because the numbers were load-bearing and
/// invisible: the menu's "About Speak" opened tab 4, so inserting a tab
/// anywhere above it would have quietly opened Permissions instead.
enum SettingsTab: Int {
    case general, model, text, history, permissions, about
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    weak var app: App?

    func show(selecting tab: SettingsTab = .general) {
        let index = tab.rawValue
        if let w = window {
            tabs?.selectedTabViewItemIndex = index
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSTabViewController()
        controller.tabStyle = .toolbar

        // NSTabViewController in .toolbar style drives the window title from
        // the selected child's `title`; without one the window reads "Untitled".
        let general = GeneralPane(); general.app = app; general.title = "General"
        let model = ModelPane(); model.app = app; model.title = "Model"
        let text = TextPane(); text.title = "Text"
        let history = HistoryPane(); history.title = "History"
        let permissions = PermissionsPane(); permissions.app = app
        permissions.title = "Permissions"
        let about = AboutPane(); about.app = app; about.title = "About"

        // Order must match SettingsTab.
        for (vc, title, symbol) in [
            (general as NSViewController, "General", "gearshape"),
            (model as NSViewController, "Model", "waveform"),
            (text as NSViewController, "Text", "textformat"),
            (history as NSViewController, "History", "clock"),
            (permissions as NSViewController, "Permissions", "lock.shield"),
            (about as NSViewController, "About", "info.circle"),
        ] {
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            controller.addTabViewItem(item)
        }

        let w = NSWindow(contentViewController: controller)
        w.title = "Speak Settings"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.setContentSize(NSSize(width: 540, height: 500))
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false

        window = w
        tabs = controller
        controller.selectedTabViewItemIndex = index
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ n: Notification) {
        app?.shortcutRecorder = nil      // never leave the tap in record mode
        window = nil
        tabs = nil
    }
}

// ---------------------------------------------------------------------------

/// Shared layout helpers so the panes stay visually consistent.
@MainActor
class Pane: NSViewController {
    let stack = NSStackView()


    /// Every pane is this tall, and scrolls if it holds more.
    ///
    /// The window sizes itself to the tallest pane, so before this a pane that
    /// outgrew the screen took the whole Settings window with it: the buttons
    /// along the bottom ended up below the edge of the display with no way to
    /// reach them, and the window is not resizable. Chosen to fit a 13 inch
    /// laptop with the menu bar and the Dock still on screen.
    private static let paneHeight: CGFloat = 600

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            // Never shorter than the visible area. A clip view is not flipped,
            // so a document view smaller than it is placed at the bottom, and
            // Permissions duly hung off the floor of the window. Making the
            // stack fill the height instead hands the slack to the spacer that
            // `buildContents` appends, which is what has always kept a short
            // pane top-aligned.
            stack.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 540),
            scroll.heightAnchor.constraint(equalToConstant: Self.paneHeight),
        ])

        view = scroll
        buildContents()
    }

    /// Subclasses override.
    func build() {}

    /// `build()` plus the spacer that keeps a short pane top-aligned.
    ///
    /// A vertical NSStackView hands surplus height to whichever arranged
    /// subview hugs its content least. Controls hug at 250 and labels at 750,
    /// so on a pane whose content is shorter than the window a control row was
    /// silently stretched, and because `row` centres its contents the control
    /// then floated in the middle of the extra space. That is what put a
    /// 24-point Language popup inside a 110-point row with a matching hole
    /// above and below it, while the same popup in General looked right purely
    /// because that pane happened to fill its height.
    ///
    /// This spacer hugs at 1, so it loses to everything and absorbs the lot.
    private func buildContents() {
        build()
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        stack.addArrangedSubview(spacer)
    }

    func heading(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        return t
    }

    func caption(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = 470
        return t
    }

    /// Reference text, folded away until the "?" beside it is pressed.
    ///
    /// For what somebody needs while *using* a control, never for what they need
    /// while deciding whether to switch it on. A consequence stays visible: the
    /// panes describe features that rewrite the user's words, and "this rewrites
    /// what you said" behind an affordance nobody presses is how someone is
    /// surprised by their own transcript.
    ///
    /// The test is whether the sentence would change the decision. "Adds about a
    /// second before pasting" would, so it is a caption. "A single word needs
    /// five letters" would not, it is read while typing a term in, so it is one
    /// of these.
    func detail(_ s: String) -> NSTextField {
        let t = caption(s)
        t.isHidden = true
        return t
    }

    func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = 10
        return r
    }

    /// A row with its last view pushed to the trailing edge of the content
    /// column, so it lines up with the separators and the tables rather than
    /// trailing whatever text happens to sit beside it.
    ///
    /// The spacer hugs at 1, so it loses to both sides and absorbs the slack.
    /// Same trick as the vertical spacer `buildContents` appends.
    func row(_ views: [NSView], trailing: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let r = row(views + [spacer, trailing])
        r.translatesAutoresizingMaskIntoConstraints = false
        r.widthAnchor.constraint(equalToConstant: 470).isActive = true
        return r
    }

    func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 470).isActive = true
        return b
    }

    func rebuild() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        buildContents()
    }
}

/// The "?" that folds a `detail` block open and shut.
///
/// Reveals the text in place rather than showing a tooltip, and the difference
/// matters. A tooltip needs a deliberate hover, is unreachable from the
/// keyboard, and does not survive a screenshot, which makes it the wrong home
/// for anything somebody actually has to read. This is a button: it can be
/// tabbed to, pressed with the keyboard, and what it reveals stays on screen to
/// be read at any length.
@MainActor
final class Discloser: NSButton {
    private weak var detail: NSView?
    private let onToggle: (Bool) -> Void

    init(revealing detail: NSView, expanded: Bool, onToggle: @escaping (Bool) -> Void) {
        self.detail = detail
        self.onToggle = onToggle
        super.init(frame: .zero)
        bezelStyle = .helpButton
        title = ""
        target = self
        action = #selector(toggle)
        detail.isHidden = !expanded
        describe(expanded)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    @objc private func toggle() {
        guard let detail else { return }
        detail.isHidden.toggle()
        let expanded = !detail.isHidden
        describe(expanded)
        onToggle(expanded)
    }

    /// Says which way it will go, not which way it is, because that is what
    /// somebody about to press it wants to know.
    private func describe(_ expanded: Bool) {
        let label = expanded ? "Hide the details" : "Show the details"
        toolTip = label
        setAccessibilityLabel(label)
    }
}

// ---------------------------------------------------------------------------
// General: shortcut and paste behaviour
// ---------------------------------------------------------------------------

@MainActor
final class GeneralPane: Pane {
    weak var app: App?
    private var field: NSTextField!
    private var changeButton: NSButton!
    private var warning: NSTextField!
    private var micPopup: NSPopUpButton!
    private var loginError: String?
    private var startSoundPopup: NSPopUpButton!
    private var doneSoundPopup: NSPopUpButton!

    /// Devices come and go, so rebuild the list whenever the pane is shown.
    override func viewWillAppear() {
        super.viewWillAppear()
        loginError = nil
        rebuild()
    }

    private func populateMics() {
        micPopup.removeAllItems()

        micPopup.addItem(withTitle: "System default")
        micPopup.item(at: 0)?.representedObject = ""

        let devices = AudioDevices.inputs()
        if !devices.isEmpty { micPopup.menu?.addItem(.separator()) }

        for d in devices {
            micPopup.addItem(withTitle: d.name)
            micPopup.lastItem?.representedObject = d.uid
        }

        let saved = Settings.microphoneUID
        let match = micPopup.itemArray.firstIndex {
            ($0.representedObject as? String) == (saved ?? "")
        }
        micPopup.selectItem(at: match ?? 0)
    }

    @objc private func selectMic() {
        let uid = micPopup.selectedItem?.representedObject as? String
        Settings.microphoneUID = (uid?.isEmpty ?? true) ? nil : uid
        rebuild()
    }

    override func build() {
        stack.addArrangedSubview(heading("Startup"))

        let login = NSButton(checkboxWithTitle: "Start Speak at login",
                             target: self, action: #selector(toggleLoginItem))
        let loginState = LoginItem.state
        login.state = loginState.isSelected ? .on : .off
        var loginControls: [NSView] = [login]
        if loginState == .requiresApproval || loginError != nil {
            let open = NSButton(title: "Open Login Items…",
                                target: self, action: #selector(openLoginItems))
            loginControls.append(open)
        }
        stack.addArrangedSubview(row(loginControls))

        let loginStatus: NSTextField
        if let loginError {
            loginStatus = caption(loginError)
            loginStatus.textColor = .systemOrange
        } else {
            switch loginState {
            case .enabled:
                loginStatus = caption("On: Speak will open in the menu bar when you log in.")
            case .requiresApproval:
                loginStatus = caption(
                    "Speak is registered, but macOS needs your approval before it can open at login.")
                loginStatus.textColor = .systemOrange
            case .notRegistered:
                loginStatus = caption("Off: Speak will stay closed until you open it.")
            case .notFound:
                loginStatus = caption(
                    "This copy of Speak cannot be registered. "
                    + "Install it in Applications and try again.")
                loginStatus.textColor = .systemOrange
            }
        }
        stack.addArrangedSubview(loginStatus)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Shortcut"))

        field = NSTextField(labelWithString: Shortcut.description)
        field.font = .monospacedSystemFont(ofSize: 13, weight: .medium)

        changeButton = NSButton(title: "Change…", target: self, action: #selector(record))
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetShortcut))
        stack.addArrangedSubview(row([field, changeButton, reset]))

        stack.addArrangedSubview(caption(
            "Up to \(Shortcut.maxKeys) modifiers (fn, shift, control, option, command), "
            + "optionally followed by one ordinary key. Left and right modifiers "
            + "count separately. A chord with an ordinary key is swallowed, so it "
            + "will not also type that character."))

        warning = caption("")
        warning.textColor = .systemOrange
        stack.addArrangedSubview(warning)
        updateWarning()

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("After transcribing"))

        let paste = NSButton(checkboxWithTitle: "Paste automatically (⌘V)",
                             target: self, action: #selector(togglePaste))
        paste.state = Settings.autoPaste ? .on : .off
        stack.addArrangedSubview(paste)
        stack.addArrangedSubview(caption(
            "On by default. The text always goes to the clipboard as well, so "
            + "turn this off if you would rather choose where it lands: "
            + "auto-paste types into whatever happens to be focused."))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Feedback"))

        let sounds = NSButton(checkboxWithTitle: "Play a sound when recording starts and stops",
                              target: self, action: #selector(toggleSounds))
        sounds.state = Settings.sounds ? .on : .off
        stack.addArrangedSubview(sounds)

        startSoundPopup = soundPopup(selected: Settings.startSound,
                                     action: #selector(pickStartSound))
        doneSoundPopup = soundPopup(selected: Settings.doneSound,
                                    action: #selector(pickDoneSound))
        startSoundPopup.isEnabled = Settings.sounds
        doneSoundPopup.isEnabled = Settings.sounds
        stack.addArrangedSubview(row([
            NSTextField(labelWithString: "Starts:"), startSoundPopup,
            NSTextField(labelWithString: "Finishes:"), doneSoundPopup,
        ]))
        stack.addArrangedSubview(caption(
            "Choosing one plays it. The start sound fires when the microphone "
            + "actually goes live rather than when the key is pressed, so it "
            + "never claims to be listening before it is."))

        let hud = NSButton(checkboxWithTitle: "Show an on-screen indicator while recording",
                           target: self, action: #selector(toggleIndicator))
        hud.state = Settings.showIndicator ? .on : .off
        stack.addArrangedSubview(hud)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Microphone"))

        micPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        micPopup.target = self
        micPopup.action = #selector(selectMic)
        populateMics()
        stack.addArrangedSubview(row([micPopup]))

        if Settings.microphoneMissing {
            let gone = caption(
                "The saved microphone is not connected. Recording from the "
                + "system default until it comes back.")
            gone.textColor = .systemOrange
            stack.addArrangedSubview(gone)
        } else {
            stack.addArrangedSubview(caption(
                "“System default” follows whatever is selected in Sound "
                + "settings, so changing it there changes it here."))
        }
    }

    private func updateWarning() {
        if Shortcut.isRisky(Shortcut.mask, Shortcut.keyCode) {
            warning.stringValue =
                "A single modifier fires every time you press that key, "
                + "including mid-sentence. Use it only on a key you never "
                + "otherwise touch."
        } else {
            warning.stringValue = ""
        }
    }

    /// Captures the next chord: hold a combination, and it commits on release.
    /// Waiting for release is what lets you build the chord one key at a time.
    @objc private func record() {
        guard let app else { return }
        var widest: UInt64 = 0
        field.stringValue = "press and hold…"
        changeButton.isEnabled = false

        var pending: DispatchWorkItem?

        let commit: (UInt64, Int?) -> Void = { [weak self] mask, code in
            guard let self else { return }
            app.shortcutRecorder = nil
            self.changeButton.isEnabled = true
            if Shortcut.isUsable(mask, code) {
                Shortcut.set(mask: mask, keyCode: code)
            } else {
                NSSound.beep()
            }
            self.field.stringValue = Shortcut.description
            self.updateWarning()
            self.app?.refreshMenu()
        }

        app.shortcutRecorder = { [weak self] flags, keyCode in
            guard let self else { return }
            let held = flags.rawValue & Modifier.tracked

            // A character key ends the chord immediately: there is nothing more
            // to wait for, and holding it would just repeat.
            if let keyCode {
                pending?.cancel()
                commit(held, keyCode)
                return
            }

            if held != 0 {
                pending?.cancel()           // still building the chord
                pending = nil
                if held.nonzeroBitCount > widest.nonzeroBitCount,
                   held.nonzeroBitCount <= Shortcut.maxKeys {
                    widest = held
                }
                // The widest chord seen, not the live one: showing what is
                // held right now makes the field count back down as the keys
                // are released, then jump back up when it commits.
                self.field.stringValue = Modifier.describe(widest)
                    + (held.nonzeroBitCount > Shortcut.maxKeys
                       ? "   (max \(Shortcut.maxKeys))" : "")
                return
            }

            // Everything released with no character key. Wait before
            // committing: three keys rarely go down in one event, and a brief
            // all-clear between presses would otherwise cut the chord short.
            pending?.cancel()
            let work = DispatchWorkItem { commit(widest, nil) }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    @objc private func resetShortcut() {
        app?.shortcutRecorder = nil
        changeButton.isEnabled = true
        Shortcut.set(mask: Shortcut.defaultMask, keyCode: nil)
        field.stringValue = Shortcut.description
        updateWarning()
        app?.refreshMenu()
    }

    /// A menu of the system sounds, plus None for silencing one cue without
    /// losing the other.
    private func soundPopup(selected: String, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = action
        popup.addItem(withTitle: Cue.none)
        popup.menu?.addItem(.separator())
        for name in Cue.available { popup.addItem(withTitle: name) }
        popup.selectItem(withTitle: selected)
        if popup.selectedItem == nil { popup.selectItem(withTitle: Cue.none) }
        return popup
    }

    @objc private func toggleSounds(_ sender: NSButton) {
        Settings.sounds = sender.state == .on
        startSoundPopup?.isEnabled = Settings.sounds
        doneSoundPopup?.isEnabled = Settings.sounds
    }

    @objc private func pickStartSound(_ sender: NSPopUpButton) {
        let name = sender.titleOfSelectedItem ?? Cue.defaultStart
        Settings.startSound = name
        Cue.preview(name)      // hearing it is the only way to judge it
    }

    @objc private func pickDoneSound(_ sender: NSPopUpButton) {
        let name = sender.titleOfSelectedItem ?? Cue.defaultDone
        Settings.doneSound = name
        Cue.preview(name)
    }

    @objc private func toggleIndicator(_ sender: NSButton) {
        Settings.showIndicator = sender.state == .on
    }

    @objc private func togglePaste(_ sender: NSButton) {
        Settings.autoPaste = sender.state == .on
    }

    @objc private func toggleLoginItem(_ sender: NSButton) {
        loginError = LoginItem.setEnabled(sender.state == .on)
        rebuild()
    }

    @objc private func openLoginItems() {
        LoginItem.openSystemSettings()
    }
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

@MainActor
final class ModelPane: Pane {
    weak var app: App?
    private var localePopup: NSPopUpButton!
    /// Held on the pane rather than in the view, because this pane rebuilds
    /// itself on every model status change: a download ticking away would
    /// otherwise fold the list shut once a second while it was being read.
    private var languagesOpen = false

    /// Mirror the app's model state so a download is visible from the screen
    /// where you started it.
    override func viewWillAppear() {
        super.viewWillAppear()
        rebuild()
        app?.onStatusChange = { [weak self] _ in self?.rebuild() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        app?.onStatusChange = nil
    }

    override func build() {
        stack.addArrangedSubview(heading("Transcription model"))

        let busy: Bool
        switch app?.status {
        case .downloading, .loading: busy = true
        default: busy = false
        }

        for choice in ModelChoice.all {
            let b = NSButton(radioButtonWithTitle: choice.title,
                             target: self, action: #selector(select(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(choice.id)
            b.state = choice.id == Settings.choice.id ? .on : .off
            // Switching mid-download would abandon the fetch half-finished.
            b.isEnabled = Settings.envOverride == nil && !busy
            stack.addArrangedSubview(b)

            var line = choice.detail
            if !choice.isDownloaded { line += " · not downloaded yet" }
            let d = caption(line)
            d.textColor = .secondaryLabelColor
            stack.addArrangedSubview(d)

            // Which 25, spelled out. The number is what the engine list has
            // room for, but the question anyone actually has is whether their
            // language is in it, and that cannot be answered by a count.
            if !choice.languages.isEmpty {
                let disclose = NSButton(
                    title: (languagesOpen ? "Hide the " : "Show the ")
                         + "\(choice.languages.count) languages",
                    target: self, action: #selector(toggleLanguages))
                disclose.bezelStyle = .inline
                disclose.controlSize = .small
                stack.addArrangedSubview(row([disclose]))
                if languagesOpen {
                    stack.addArrangedSubview(
                        caption(choice.languages.joined(separator: " · ")))
                    stack.addArrangedSubview(caption(
                        "Detected automatically. The Language picker does not "
                        + "appear for Parakeet because the model has no "
                        + "language setting to offer."))
                }
            }
        }

        // Directly under the engine list, not after Language. It reports the
        // state of the engine chosen above, and sitting below the Language
        // picker it read as though "Ready" described the language.
        stack.addArrangedSubview(statusView())

        if Settings.envOverride != nil {
            let o = caption("SPEAK_MODEL is set to “\(Settings.envOverride!)”, "
                            + "which overrides this choice.")
            o.textColor = .systemOrange
            stack.addArrangedSubview(o)
        }

        // Language only appears for Apple Intelligence. Parakeet v2 is English
        // by construction and v3's language parameter never reaches its
        // decoder, so a picker there would be a control that does nothing.
        if Settings.choice.kind == .apple {
            stack.addArrangedSubview(separator())
            stack.addArrangedSubview(heading("Language"))

            localePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            localePopup.target = self
            localePopup.action = #selector(selectLocale)
            // Populated before it joins the stack, the way the Microphone
            // popup in General is. An empty NSPopUpButton has no useful
            // intrinsic height, so the stack has nothing to size its row by
            // and stretches it to whatever height is going; `row` centres its
            // contents, so the control ends up floating in the middle of a
            // hole with matching gaps above and below. Adding the items later
            // does not undo it.
            loadLocales()
            stack.addArrangedSubview(row([localePopup]))
            stack.addArrangedSubview(caption(
                "Automatic follows your Mac's language, preferring one already "
                + "installed. Others may download a small language pack."))
        }

        stack.addArrangedSubview(separator())

        if Settings.choice.kind == .apple {
            stack.addArrangedSubview(caption(
                "Apple Intelligence is part of macOS, so there is nothing to "
                + "download. Transcription stays on this Mac."))
        } else {
            stack.addArrangedSubview(heading("Where the model comes from"))
            stack.addArrangedSubview(caption(
                "Parakeet is NVIDIA's speech model, converted for Apple Silicon "
                + "by the mlx-community project and downloaded from Hugging Face "
                + "on first use. CC-BY-4.0."))

            let link = NSButton(title: "huggingface.co/\(Settings.choice.repo)",
                                target: self, action: #selector(openModelPage))
            link.bezelStyle = .inline
            link.controlSize = .small
            stack.addArrangedSubview(link)

            // The real path, not the usual one. HF_HOME and HF_HUB_CACHE move
            // it, and naming a directory the weights are not in is worse than
            // naming none.
            stack.addArrangedSubview(caption(
                "Kept in \(ModelChoice.hubRootDisplay). The download is the "
                + "only time Speak uses the network; transcription is always "
                + "local."))
        }

        // Disk space last, because it is housekeeping rather than a choice.
        //
        // One control for the whole pane rather than a line under each engine:
        // the question is "how much is Speak using and can I have some back",
        // not "what do I do about this particular model".
        //
        // It belongs in the app rather than only in the README because Speak
        // is the only thing that knows which directories inside
        // ~/.cache/huggingface are its own. That cache is shared with anything
        // else using MLX on this Mac, so "delete the folder" is bad advice and
        // this is the honest alternative.
        let downloaded = ModelChoice.all.filter { $0.kind != .apple && $0.isDownloaded }
        if !downloaded.isEmpty {
            stack.addArrangedSubview(separator())
            stack.addArrangedSubview(heading("Disk space"))

            let total = downloaded.reduce(Int64(0)) { $0 + $1.bytesUsed }
            stack.addArrangedSubview(caption(
                "Speak's downloaded models use \(ModelChoice.humanBytes(total)). "
                + "That is more than the download size because each model is "
                + "stored twice: once in the shared Hugging Face cache and "
                + "again in mlx-audio's own copy."))

            // Never the engine in use. Deleting the weights out from under it
            // would only force a re-download at the next launch, so the way to
            // reclaim everything is to pick Apple Intelligence first, which
            // needs no download and makes every Parakeet removable.
            let removable = downloaded.filter { $0.id != Settings.choice.id }
            if removable.isEmpty {
                stack.addArrangedSubview(caption(
                    "Only the engine you are using is downloaded. Switch to "
                    + "Apple Intelligence, which needs no download, to free "
                    + "this up."))
            } else {
                let reclaimable = removable.reduce(Int64(0)) { $0 + $1.bytesUsed }
                let free = NSButton(
                    title: "Free up \(ModelChoice.humanBytes(reclaimable))",
                    target: self, action: #selector(freeUpSpace))
                // Same reason the radio buttons are disabled while busy: a
                // deletion mid-download would race the fetch writing into it.
                free.isEnabled = !busy
                stack.addArrangedSubview(row([free]))
                stack.addArrangedSubview(caption(
                    "Removes \(removable.map(\.title).joined(separator: " and ")), "
                    + "which you are not using. The engine you have selected is "
                    + "left alone."))
            }
        }
    }

    @objc private func freeUpSpace() {
        let removable = ModelChoice.all.filter {
            $0.kind != .apple && $0.isDownloaded && $0.id != Settings.choice.id
        }
        // Recomputed rather than captured: the pane rebuilds on every status
        // change, so the selected engine can move under a click already in
        // flight, and the one thing this must never delete is the engine in use.
        guard !removable.isEmpty else { return }

        let names = removable.map(\.title).joined(separator: " and ")
        let freed = removable.reduce(Int64(0)) { $0 + $1.bytesUsed }

        let a = NSAlert()
        a.messageText = "Remove \(names)?"
        a.informativeText =
            "\(ModelChoice.humanBytes(freed)) will be freed. Choosing one of "
            + "these engines again re-downloads it, which takes a few minutes. "
            + "The engine you have selected is not touched."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }

        for choice in removable { choice.removeFromDisk() }
        rebuild()
    }

    @objc private func toggleLanguages() {
        languagesOpen.toggle()
        rebuild()
    }

    @objc private func openModelPage() {
        guard !Settings.choice.repo.isEmpty,
              let url = URL(string: "https://huggingface.co/\(Settings.choice.repo)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Download / load / error state, shown here because this is the screen
    /// where a switch is started.
    private func statusView() -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 8

        switch app?.status {
        case .idle:
            let label = NSTextField(labelWithString: "Setup has not finished yet.")
            label.font = .systemFont(ofSize: 12)
            box.addArrangedSubview(label)
        case .downloading(_, let total, _, let fraction):
            let f = ByteCountFormatter()
            f.countStyle = .file

            // Determinate once the first progress callback lands, spinning
            // before that. A bar stuck at zero is worse than no bar.
            let bar = NSProgressIndicator()
            bar.controlSize = .small
            if let fraction {
                bar.style = .bar
                bar.isIndeterminate = false
                bar.minValue = 0
                bar.maxValue = 1
                bar.doubleValue = fraction
                bar.widthAnchor.constraint(equalToConstant: 220).isActive = true
            } else {
                bar.style = .spinning
                bar.startAnimation(nil)
            }

            let label = NSTextField(labelWithString: app?.status.summary ?? "")
            label.font = .systemFont(ofSize: 12)
            box.addArrangedSubview(fraction == nil ? row([bar, label]) : label)
            if fraction != nil { box.addArrangedSubview(bar) }
            box.addArrangedSubview(caption(
                "Downloading \(f.string(fromByteCount: total)) once. You can "
                + "close this window; it continues in the background."))

        case .loading:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let label = NSTextField(labelWithString: "Loading model…")
            label.font = .systemFont(ofSize: 12)
            box.addArrangedSubview(row([spinner, label]))

        case .ready:
            let label = NSTextField(labelWithString: "● Ready")
            label.textColor = .systemGreen
            label.font = .systemFont(ofSize: 12)
            box.addArrangedSubview(label)

        case .failed(let why):
            let label = NSTextField(labelWithString: "○ \(why)")
            label.textColor = .systemOrange
            label.font = .systemFont(ofSize: 12)
            box.addArrangedSubview(label)
            box.addArrangedSubview(
                NSButton(title: "Try again", target: self, action: #selector(retry)))

        case nil:
            break
        }
        return box
    }

    /// Populated asynchronously: the supported and installed lists are async
    /// properties on SpeechTranscriber.
    private func loadLocales() {
        guard #available(macOS 26.0, *), let popup = localePopup else { return }
        popup.removeAllItems()
        popup.addItem(withTitle: "Automatic")
        popup.item(at: 0)?.representedObject = ""
        popup.selectItem(at: 0)

        Task { @MainActor in
            let supported = await AppleEngine.supportedLocales()
            let installed = Set(await AppleEngine.installedLocales().map {
                $0.identifier(.bcp47)
            })

            let sorted = supported.sorted {
                name(of: $0).localizedCaseInsensitiveCompare(name(of: $1)) == .orderedAscending
            }
            for l in sorted {
                let tag = l.identifier(.bcp47)
                // Flag the ones that need fetching, since "no download" is the
                // reason to pick this engine at all.
                let suffix = installed.contains(tag) ? "" : "  (downloads)"
                popup.addItem(withTitle: name(of: l) + suffix)
                popup.lastItem?.representedObject = tag
            }

            let saved = Settings.appleLocale ?? ""
            if let i = popup.itemArray.firstIndex(where: {
                ($0.representedObject as? String) == saved
            }) { popup.selectItem(at: i) }
        }
    }

    private func name(of locale: Locale) -> String {
        let tag = locale.identifier(.bcp47)
        return (Locale.current.localizedString(forIdentifier: locale.identifier) ?? tag)
            + " (\(tag))"
    }

    @objc private func selectLocale() {
        let tag = localePopup.selectedItem?.representedObject as? String
        Settings.appleLocale = (tag?.isEmpty ?? true) ? nil : tag
        app?.reloadModel()
    }

    @objc private func retry() { app?.reloadModel() }

    @objc private func select(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let choice = ModelChoice.named(id),
              choice.id != Settings.choice.id else { return }
        Settings.choice = choice
        app?.reloadModel()
        rebuild()
    }

}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

@MainActor
final class HistoryPane: Pane, NSTableViewDataSource, NSTableViewDelegate {
    private var entries: [History.Entry] = []
    private var table: NSTableView!
    private var empty: NSTextField!
    private var emptyIcon: NSImageView!

    /// Re-read on every appearance. The pane is built once but dictations keep
    /// arriving behind it, so without this the table shows whatever existed
    /// when Settings was first opened.
    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    private func reload() {
        entries = History.recent(500)
        table?.reloadData()
        empty?.isHidden = !entries.isEmpty
        emptyIcon?.isHidden = !entries.isEmpty
    }

    override func build() {
        entries = History.recent(500)

        stack.addArrangedSubview(heading("Previous transcriptions"))

        table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 34
        table.allowsMultipleSelection = false
        table.doubleAction = #selector(copySelected)
        table.target = self

        let when = NSTableColumn(identifier: .init("when"))
        when.title = "When"
        when.width = 120
        table.addTableColumn(when)

        let text = NSTableColumn(identifier: .init("text"))
        text.title = "Text"
        text.width = 320
        table.addTableColumn(text)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 470).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        stack.addArrangedSubview(scroll)

        emptyIcon = BrandIcon.view(size: 40, accessibilityLabel: "Speak mascot")
        emptyIcon.isHidden = !entries.isEmpty
        stack.addArrangedSubview(emptyIcon)

        empty = caption("Nothing yet. Dictations appear here as you make them.")
        empty.isHidden = !entries.isEmpty
        stack.addArrangedSubview(empty)

        stack.addArrangedSubview(row([
            NSButton(title: "Copy", target: self, action: #selector(copySelected)),
            NSButton(title: "Reveal file", target: self, action: #selector(reveal)),
            NSButton(title: "Clear…", target: self, action: #selector(clear)),
        ]))
        stack.addArrangedSubview(caption(
            "Stored as JSONL at ~/Library/Application Support/speak/history.jsonl, "
            + "so it stays greppable and outlives the app. Double-click a row to copy it."))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let e = entries[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail

        if column?.identifier.rawValue == "when" {
            let f = DateFormatter()
            f.dateFormat = "d MMM, HH:mm"
            label.stringValue = f.string(from: e.date)
            label.textColor = .secondaryLabelColor
        } else {
            label.stringValue = e.text.replacingOccurrences(of: "\n", with: " ")
            // Show what was said alongside what was pasted whenever polishing
            // or a correction changed it, so a rewrite that went wrong is
            // recoverable without opening the file.
            label.toolTip = e.raw.map { "\(e.text)\n\nAs transcribed:\n\($0)" } ?? e.text
        }

        cell.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func copySelected() {
        let r = table.selectedRow
        guard r >= 0, r < entries.count else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entries[r].text, forType: .string)
    }

    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([History.file])
    }

    @objc private func clear() {
        let a = NSAlert()
        a.messageText = "Delete all transcription history?"
        a.informativeText = "\(entries.count) entries will be removed. This cannot be undone."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: History.file)
        reload()
    }
}

// ---------------------------------------------------------------------------
// Permissions
// ---------------------------------------------------------------------------

@MainActor
final class PermissionsPane: Pane {
    weak var app: App?
    private var timer: Timer?

    override func build() {
        stack.addArrangedSubview(heading("Permissions"))

        stack.addArrangedSubview(statusRow(
            "Microphone", Permissions.microphone,
            action: #selector(fixMic), button: "Request"))
        stack.addArrangedSubview(caption("So Speak can hear you."))

        stack.addArrangedSubview(statusRow(
            "Accessibility", Permissions.accessibility,
            action: #selector(fixAccessibility), button: "Open Settings"))
        stack.addArrangedSubview(caption(
            "The shortcut is a chord of modifier keys, which macOS only "
            + "delivers to apps trusted for Accessibility."))

        if !Permissions.accessibility {
            let h = caption(
                "Already listed but not working? Remove Speak with the minus "
                + "button and add it again. macOS keeps a stale entry after an "
                + "app is replaced.")
            h.textColor = .systemOrange
            stack.addArrangedSubview(h)
        }

        stack.addArrangedSubview(separator())
        let again = NSButton(title: "Run setup again",
                             target: self, action: #selector(rerunOnboarding))
        stack.addArrangedSubview(again)

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfChanged() }
        }
    }

    private var lastState: (Bool, Bool)?

    private func refreshIfChanged() {
        let now = (Permissions.microphone, Permissions.accessibility)
        if let last = lastState, last == now { return }
        lastState = now
        rebuild()
    }

    private func statusRow(_ name: String, _ ok: Bool,
                           action: Selector, button: String) -> NSStackView {
        let dot = NSTextField(labelWithString: ok ? "●" : "○")
        dot.textColor = ok ? .systemGreen : .tertiaryLabelColor
        dot.font = .systemFont(ofSize: 15)

        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 13)

        var views: [NSView] = [dot, label]
        if !ok {
            views.append(NSButton(title: button, target: self, action: action))
        }
        return row(views)
    }

    @objc private func fixMic() {
        Permissions.requestMicrophone { [weak self] granted in
            Task { @MainActor in
                if !granted { Permissions.openMicrophoneSettings() }
                self?.rebuild()
            }
        }
    }

    @objc private func fixAccessibility() {
        Permissions.openAccessibilitySettings()
        // Same reason as in onboarding: the grant lands in another app, later,
        // and without this the tap stays dead until Speak is relaunched.
        app?.watchForAccessibility()
    }

    @objc private func rerunOnboarding() { app?.startOnboarding() }

    deinit { timer?.invalidate() }
}
