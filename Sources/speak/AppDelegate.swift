import AppKit
import AVFoundation
import Carbon.HIToolbox

@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private var eventTap: CFMachPort?
    private var comboLatched = false
    private var ready = false
    private var downloadWatch: Timer?
    let updater = Updater()
    private let indicator = RecordingIndicator()

    /// Called with each finished transcript, nil when nothing was heard.
    /// Onboarding uses it to prove the shortcut works.
    var onTranscript: ((String?) -> Void)?

    /// True once the event tap is live, so onboarding can arm it the moment
    /// Accessibility is granted rather than waiting until the flow finishes.
    var hotkeyInstalled: Bool { eventTap != nil }

    func installHotkeyIfNeeded() {
        guard eventTap == nil, Permissions.accessibility else { return }
        installHotkey()
    }

    /// Latest model state, and a hook so Settings and onboarding can mirror it.
    private(set) var status: ModelStatus = .loading
    var onStatusChange: ((ModelStatus) -> Void)?

    private lazy var onboarding: Onboarding = {
        let o = Onboarding()
        o.owner = self
        return o
    }()
    private lazy var settings: SettingsWindow = {
        let s = SettingsWindow()
        s.app = self
        return s
    }()

    /// Set while Settings is capturing a replacement chord, so the chord being
    /// recorded does not also toggle dictation.
    var shortcutRecorder: ((CGEventFlags, Int?) -> Void)?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        setIcon("mic.slash", "loading model…")

        // Start-at-login is on by default for new installations only. Record
        // the decision before onboarding changes `Settings.onboarded`, and
        // never use startup to override a later choice by the user.
        LoginItem.applyDefaultIfNeeded(isNewInstallation: !Settings.onboarded)

        reloadModel()

        if Permissions.allGranted {
            installHotkey()
            Settings.onboarded = true
        } else if !Settings.onboarded {
            startOnboarding()
        } else {
            setIcon("exclamationmark.triangle", "permissions needed")
        }
        refreshMenu()
    }

    func startOnboarding() {
        onboarding.show { [weak self] in
            guard let self else { return }
            if Permissions.allGranted, self.eventTap == nil {
                self.installHotkey()
                self.setIcon(self.ready ? "mic" : "mic.slash",
                             self.ready ? "ready" : "loading model…")
            }
            self.refreshMenu()
        }
    }

    // MARK: - Model

    func reloadModel() {
        ready = false
        let choice = Settings.envOverride
            .flatMap { ModelChoice.named(repo: $0) } ?? Settings.choice

        // A first run downloads ~2.4 GB. Transcriber drives that download so it
        // can report real progress; the timer only ticks elapsed time between
        // callbacks, so the line keeps moving during the gaps.
        let started = Date()
        if !choice.isDownloaded {
            setStatus(.downloading(elapsed: 0, total: choice.approxBytes,
                                   received: nil, fraction: nil))
            startDownloadWatch(choice, started: started)
        } else {
            setStatus(.loading)
        }

        Task {
            do {
                try await transcriber.load(choice) { [weak self] fraction, received in
                    guard let self, case .downloading = self.status else { return }
                    self.setStatus(.downloading(
                        elapsed: Date().timeIntervalSince(started),
                        total: choice.approxBytes,
                        received: received,
                        fraction: fraction))
                }
                stopDownloadWatch()
                ready = true
                setStatus(.ready)
            } catch {
                stopDownloadWatch()
                setStatus(.failed(ModelStatus.describe(error)))
                log("model load failed: \(error)")
            }
        }
    }

    /// Keeps the elapsed time honest between progress callbacks, and notices
    /// when the files have landed and the remaining wait is weight loading.
    private func startDownloadWatch(_ choice: ModelChoice, started: Date) {
        downloadWatch?.invalidate()
        downloadWatch = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self,
                      case .downloading(_, _, let received, let fraction) = self.status
                else { return }
                if choice.isDownloaded {
                    self.setStatus(.loading)
                } else {
                    self.setStatus(.downloading(
                        elapsed: Date().timeIntervalSince(started),
                        total: choice.approxBytes,
                        received: received,
                        fraction: fraction))
                }
            }
        }
    }

    private func stopDownloadWatch() {
        downloadWatch?.invalidate()
        downloadWatch = nil
    }

    private func setStatus(_ s: ModelStatus) {
        status = s
        switch s {
        case .downloading: setIcon("arrow.down.circle", s.summary)
        case .loading:     setIcon("mic.slash", s.summary)
        case .ready:       setIcon("mic", s.summary)
        case .failed:      setIcon("exclamationmark.triangle", s.summary)
        }
        onStatusChange?(s)
    }

    // MARK: - Menu

    /// Kept deliberately thin. Everything configurable lives in Settings; the
    /// menu is for status and the two things worth reaching in one click.
    func refreshMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        // Until the model is usable, say so first: the shortcut does nothing
        // yet, and a silent beep explains nothing.
        switch status {
        case .ready:
            let hint = NSMenuItem(title: "\(Shortcut.description) toggles dictation",
                                  action: nil, keyEquivalent: "")
            hint.image = symbol("keyboard")
            menu.addItem(hint)
        case .downloading, .loading:
            let item = NSMenuItem(title: status.summary.prefix(1).uppercased()
                                  + status.summary.dropFirst(),
                                  action: nil, keyEquivalent: "")
            item.image = symbol("arrow.down.circle")
            menu.addItem(item)
            let note = NSMenuItem(title: "Dictation starts once this finishes",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        case .failed(let why):
            let item = NSMenuItem(title: why, action: nil, keyEquivalent: "")
            item.image = symbol("exclamationmark.triangle")
            menu.addItem(item)
            let retry = NSMenuItem(title: "Try again",
                                   action: #selector(retryModel), keyEquivalent: "")
            retry.target = self
            retry.image = symbol("arrow.clockwise")
            menu.addItem(retry)
        }

        if !Permissions.allGranted {
            let warn = NSMenuItem(title: "Finish setup…",
                                  action: #selector(openOnboarding), keyEquivalent: "")
            warn.target = self
            warn.image = symbol("exclamationmark.triangle")
            menu.addItem(.separator())
            menu.addItem(warn)
        }

        let recent = History.recent(5)
        if !recent.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let stamp = DateFormatter()
            stamp.dateFormat = "HH:mm"
            for (i, e) in recent.enumerated() {
                var preview = e.text.replacingOccurrences(of: "\n", with: " ")
                if preview.count > 52 { preview = String(preview.prefix(51)) + "…" }
                let item = NSMenuItem(title: "\(stamp.string(from: e.date))  \(preview)",
                                      action: #selector(copyRecent(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings),
                               keyEquivalent: ",")
        prefs.target = self
        prefs.image = symbol("gearshape")
        menu.addItem(prefs)

        let update = NSMenuItem(title: "Check for Updates…",
                                action: #selector(Updater.checkForUpdates(_:)),
                                keyEquivalent: "")
        update.target = updater
        update.isEnabled = updater.canCheck
        update.image = symbol("arrow.triangle.2.circlepath")
        menu.addItem(update)

        let about = NSMenuItem(title: "About Speak", action: #selector(openAbout),
                               keyEquivalent: "")
        about.target = self
        about.image = symbol("info.circle")
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.image = symbol("power")
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    private func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.size = NSSize(width: 15, height: 15)
        img?.isTemplate = true
        return img
    }

    private func setIcon(_ symbolName: String, _ tip: String) {
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName, accessibilityDescription: tip)
        statusItem.button?.toolTip = "Speak — \(tip)"
        log(tip)
    }

    @objc private func openSettings() { settings.show() }
    /// General is the first tab, and the shortcut lives at the top of it.
    func openSettingsAtShortcut() { settings.show(selecting: 0) }
    /// About is the last tab, so open Settings already showing it.
    @objc private func openAbout() { settings.show(selecting: 4) }
    @objc private func openOnboarding() { startOnboarding() }
    @objc private func retryModel() { reloadModel() }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        let entries = History.recent(5)
        guard sender.tag < entries.count else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entries[sender.tag].text, forType: .string)
    }

    // MARK: - Hotkey

    /// Modifier-only chords never arrive as keyDown, so we watch flagsChanged.
    ///
    /// This uses a CGEventTap rather than an NSEvent global monitor because on
    /// Apple Silicon the Globe/Fn key is swallowed by the system before it
    /// reaches NSEvent: a global monitor sees the shift half of the chord and
    /// never the Fn half. The tap sits lower down and reports Fn as
    /// `.maskSecondaryFn`.
    private func installHotkey() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Not listenOnly: when the shortcut includes a character key, that
            // keystroke has to be swallowed, or pressing fn+⇧+P would toggle
            // dictation *and* type a P into whatever is focused. Everything
            // that does not match is passed straight through.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                guard let ctx else { return Unmanaged.passUnretained(event) }
                let app = Unmanaged<App>.fromOpaque(ctx).takeUnretainedValue()

                // macOS disables a tap that ever runs long. Re-arm rather than
                // dying silently.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated { app.reenableTap() }
                    return Unmanaged.passUnretained(event)
                }

                // The tap runs on the main run loop, so this is already the
                // main thread and can be handled synchronously. That matters:
                // deciding whether to swallow the event has to happen before
                // returning, and it keeps events strictly in order.
                var swallow = false
                MainActor.assumeIsolated {
                    if type == .keyDown {
                        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
                        swallow = app.handleKeyDown(code, event.flags)
                    } else {
                        app.handleFlags(event.flags)
                    }
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: me
        ) else {
            setIcon("exclamationmark.triangle", "event tap refused; check Accessibility")
            return
        }

        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("hotkey armed (CGEventTap)")
    }

    func reenableTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        log("event tap re-enabled")
    }

    func handleFlags(_ flags: CGEventFlags) {
        if DEBUG {
            log(String(format: "raw=0x%09llx held=%@", flags.rawValue,
                       Modifier.describe(flags.rawValue & Modifier.tracked)))
        }

        if let record = shortcutRecorder {
            record(flags, nil)
            return
        }

        // A chord that includes a character key is decided in handleKeyDown;
        // flag changes alone must not fire it.
        guard !Shortcut.usesCharacterKey else { return }

        if Shortcut.modifiersMatch(flags) {
            if !comboLatched { comboLatched = true; toggle() }
        } else {
            comboLatched = false        // require a fresh press to re-fire
        }
    }

    /// Returns true when the event should be swallowed.
    func handleKeyDown(_ code: Int, _ flags: CGEventFlags) -> Bool {
        if DEBUG {
            log("keyDown code=\(code) (\(KeyName.of(code))) held="
                + Modifier.describe(flags.rawValue & Modifier.tracked))
        }

        if let record = shortcutRecorder {
            record(flags, code)
            return true          // never let a chord being recorded reach an app
        }

        guard Shortcut.usesCharacterKey,
              Shortcut.keyCode == code,
              Shortcut.modifiersMatch(flags) else { return false }

        toggle()
        return true
    }

    // MARK: - Dictation

    private func toggle() {
        if recorder.isRecording {
            setIcon("hourglass", "transcribing…")
            indicator.show(.transcribing)
            guard let pcm = recorder.stop() else {
                setIcon("mic", "ready"); indicator.hide(); return
            }
            let seconds = Double(pcm.count) / SAMPLE_RATE
            Task {
                let text = await transcriber.transcribe(pcm)
                indicator.hide()
                if let text {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    if Settings.autoPaste { paste() }
                    History.append(.init(date: Date(), duration: seconds, text: text))
                    setIcon("mic", "copied \(text.split(separator: " ").count) words")
                } else {
                    setIcon("mic", "nothing transcribed")
                }
                // Onboarding's try-it-out step listens here, so the user sees
                // their own words rather than being told it worked.
                onTranscript?(text)
            }
        } else {
            guard ready else { NSSound.beep(); return }
            do {
                try recorder.start()
                setIcon("record.circle", "recording…")
                indicator.show(.recording)
            } catch {
                setIcon("exclamationmark.triangle", "mic error: \(error)")
                indicator.hide()
            }
        }
    }

    private func paste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
