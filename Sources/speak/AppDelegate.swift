import AppKit
import AVFoundation
import Carbon.HIToolbox

@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private let polisher = Polisher()
    private var eventTap: CFMachPort?
    private var comboLatched = false
    private var ready = false
    private var downloadWatch: Timer?
    private var accessibilityWatch: Timer?
    private var loadTask: Task<Void, Never>?
    /// Highest byte count seen for the current download.
    private var peakDownloadBytes: Int64 = 0
    /// The download line in the menu bar menu, so it can be updated
    /// while the menu is on screen.
    private weak var statusMenuItem: NSMenuItem?
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
        setIcon(ready ? .ready : .idle, ready ? "ready" : "loading model…")
        refreshMenu()
    }

    /// Watch for Accessibility being granted and arm the tap the moment it is.
    ///
    /// macOS sends no notification when a TCC grant changes, and the grant is
    /// usually made in System Settings, in another app, minutes after we asked.
    /// Without polling, Speak sits there with a dead tap and the shortcut does
    /// nothing until the user thinks to relaunch, which reads as the app being
    /// broken. Stops as soon as it succeeds, or after a minute, because a
    /// permanent timer for a one-time event is waste.
    func watchForAccessibility(seconds: TimeInterval = 60) {
        guard eventTap == nil else { return }
        accessibilityWatch?.invalidate()
        let deadline = Date().addingTimeInterval(seconds)
        accessibilityWatch = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                if self.eventTap != nil || Date() > deadline {
                    t.invalidate(); self.accessibilityWatch = nil; return
                }
                if Permissions.accessibility {
                    self.installHotkeyIfNeeded()
                    t.invalidate(); self.accessibilityWatch = nil
                }
            }
        }
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
        setIcon(.idle, "loading model…")

        // Start-at-login is on by default for new installations only. Record
        // the decision before onboarding changes `Settings.onboarded`, and
        // never use startup to override a later choice by the user.
        LoginItem.applyDefaultIfNeeded(isNewInstallation: !Settings.onboarded)

        // Not on a first run. Loading here would start a 2.4 GB download
        // before the user has read a word about it, and before they have had
        // the chance to choose Apple Intelligence, which needs no download at
        // all. Setup's model step is where an engine is chosen and its
        // download asked for.
        if Settings.onboarded {
            reloadModel()
            // Load the polishing model now rather than at the first dictation.
            // It costs about 50 seconds the first time on any Mac, and doing it
            // here means that is spent while nobody is waiting, instead of
            // between somebody letting go of the key and their words appearing.
            Task {
                CustomDictionary.warm()
                await polisher.prewarm()
            }
        } else {
            setStatus(.idle)
        }

        // Having the permissions is not the same as having been set up.
        //
        // This used to skip onboarding whenever both grants were present, and
        // mark the app onboarded on the strength of that. It dates from when
        // onboarding was only about permissions. It now also chooses an engine
        // and downloads a model, so anyone who already held the grants, which
        // means anyone reinstalling, landed in an app that believed it was
        // configured, had no engine, and never loaded one: the status stayed
        // idle indefinitely with no prompt beyond a menu item they had to
        // think to look for.
        var onboardingShown = false
        if !Settings.onboarded {
            startOnboarding()
            onboardingShown = true
        } else if Permissions.allGranted {
            installHotkey()
        } else {
            setIcon(.failed, "permissions needed")
        }
        refreshMenu()

        // A launch the user asked for has to show something. Onboarding is that
        // something on a first run; every other time it is the menu, matching
        // what a relaunch already does.
        if !onboardingShown, !launchedAtLogin { showMenu() }
    }

    /// True when launchd started us at login rather than a person opening us.
    ///
    /// The launch Apple Event is the only thing that distinguishes the two.
    /// Both arrive from launchd with identical environments (`XPC_SERVICE_NAME`
    /// looks the same either way), and neither activates an `LSUIElement` app,
    /// so process ancestry, start time and frontmost-ness all fail to separate
    /// them. Without this, start-at-login would drop a menu over whatever the
    /// user was looking at, every login.
    private var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?
            .enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// Opening Speak again, from Spotlight or the Finder, drops the menu down.
    ///
    /// An `LSUIElement` app has no window and no Dock icon, so launching an
    /// already-running copy did nothing observable at all: the launch
    /// succeeded, macOS activated us, and the user saw an empty screen and
    /// concluded the app was broken. Spotlight is how most people will try to
    /// "open" a menu bar app, so it has to lead somewhere.
    func applicationShouldHandleReopen(_ app: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        showMenu()
        return true
    }

    /// Set while a menu is waiting for the app to be activated.
    private var menuPending = false
    private var activationWindow: NSWindow?

    /// Drop the status item's menu, activating the app first if need be.
    ///
    /// Two separate things make this more than one line.
    ///
    /// A status item menu is only drawn while its own app is active. Opened
    /// from a background app it tracks invisibly: the button highlights, the
    /// main thread sits in the menu's modal loop, and nothing appears on
    /// screen. That is the "I open Speak and nothing happens" this fixes.
    ///
    /// And macOS will not activate an app that has no window, which is exactly
    /// what an `LSUIElement` app is between menus. `NSApp.activate` on its own
    /// is ignored: traced over four seconds after a launch from Spotlight, the
    /// app never became frontmost, and the click that followed opened a menu
    /// nobody could see. So put a window on screen first, one pixel and
    /// effectively transparent, purely so there is something to activate, and
    /// take it away again once the menu closes.
    ///
    /// Reopening an already-running copy needs none of this, because Launch
    /// Services activates us on its way in. That is why relaunching always
    /// worked and launching never did.
    func showMenu() {
        refreshMenu()
        guard !NSApp.isActive else { dropMenu(); return }

        let anchor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.alphaValue = 0.01
        anchor.level = .floating
        anchor.ignoresMouseEvents = true
        // A window built in code releases itself when closed, which ARC then
        // does again on our own reference. That crashed the app in
        // objc_release the moment the menu was dismissed, taking the status
        // item with it and looking exactly like Speak quitting on its own.
        anchor.isReleasedWhenClosed = false
        anchor.orderFrontRegardless()
        activationWindow = anchor

        menuPending = true
        NSApp.activate(ignoringOtherApps: true)
        // Activation takes about half a second to land after a launch, and it
        // can still be refused: a launch requested by a background process
        // never gets it. Stop waiting after two seconds, and stop waiting
        // rather than clicking anyway. A menu that opens invisibly and shuts
        // says nothing, and a request left armed would drop the menu minutes
        // later, the next time something else made Speak active.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.menuPending else { return }
            self.menuPending = false
            self.discardActivationWindow()
        }
    }

    func applicationDidBecomeActive(_ n: Notification) {
        guard menuPending else { return }
        menuPending = false
        // Not inline: this runs while the activation is still being handled,
        // and a menu's modal tracking loop must not sit inside that. At launch
        // it would also hold up the reply to the launch Apple Event.
        DispatchQueue.main.async { [weak self] in self?.dropMenu() }
    }

    /// True once macOS has laid the status item into the menu bar.
    ///
    /// The item's window is created immediately and positioned asynchronously,
    /// and `performClick` on it before that lands opens the menu at the screen's
    /// top-left corner instead of under the icon.
    ///
    /// Two distinct not-yet-placed states were traced, both reporting
    /// `isVisible == true`, which is why visibility cannot be the test:
    ///
    ///     (0,   0, 30,  0)   just created, zero height
    ///     (0, -33, 30, 33)   given a height, still parked below the screen
    ///
    /// Height alone is not enough either: the second state has a real height and
    /// still lands in the corner. A placed item is in the menu bar, so the test
    /// is whether its frame is on a screen at all. Both bad states sit entirely
    /// at or below y=0 and so intersect nothing.
    private var statusItemIsPlaced: Bool {
        guard let frame = statusItem?.button?.window?.frame,
              frame.height > 0 else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    /// Drop the menu, once the status item has actually been given its place.
    ///
    /// This shipped broken in 1.0.1. It never appeared during development
    /// because the race is only lost on a slower layout: on a 1512-point
    /// MacBook Pro with a crowded menu bar the frame was still unplaced when
    /// activation landed, while on a 3360-point display it was already
    /// `(3330, 1396, 30, 22)`. Both traced with `SPEAK_DEBUG=1`.
    ///
    /// Polling rather than observing, because there is no notification for "your
    /// status item has been placed".
    ///
    /// Giving up after two seconds clicks anyway. That reproduces the old
    /// misplaced menu rather than silently never showing one, which is the
    /// better failure if an item genuinely never gets placed, as happens when
    /// the menu bar is full.
    private func dropMenu(retriesLeft: Int = 40) {
        if DEBUG {
            log("dropMenu: frame \(statusItem?.button?.window?.frame ?? .zero) "
                + "placed=\(statusItemIsPlaced) retriesLeft=\(retriesLeft)")
        }
        if !statusItemIsPlaced, retriesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.dropMenu(retriesLeft: retriesLeft - 1)
            }
            return
        }
        // performClick is the supported way to drop a status item's menu
        // programmatically; there is no public "open this menu" call. It
        // returns once the menu closes, which is when the window that bought
        // the activation has done its job.
        statusItem?.button?.performClick(nil)
        discardActivationWindow()
    }

    private func discardActivationWindow() {
        activationWindow?.orderOut(nil)
        activationWindow = nil
    }

    func startOnboarding() {
        onboarding.show { [weak self] in
            guard let self else { return }
            if Permissions.allGranted, self.eventTap == nil {
                self.installHotkey()
                self.setIcon(self.ready ? .ready : .idle,
                             self.ready ? "ready" : "loading model…")
            }
            self.refreshMenu()
        }
    }

    // MARK: - Model

    /// Begin loading if nothing has been asked for yet.
    ///
    /// Onboarding calls this only for an engine that needs no download, where
    /// loading costs seconds off the disk and nobody has to be asked. A fetch
    /// is never started this way: that is what the model step's button is for.
    func startModelLoadIfIdle() {
        if case .idle = status { reloadModel() }
    }

    /// Stop whatever is loading and go back to having asked for nothing.
    ///
    /// Selecting an engine in setup must not fetch it, so choosing one that is
    /// not on disk lands here. It also has to cancel: picking Parakeet v3 while
    /// v2 is downloading has to stop v2, or the bytes the user just declined
    /// keep arriving anyway.
    func idleModel() {
        loadTask?.cancel()
        loadTask = nil
        stopDownloadWatch()
        peakDownloadBytes = 0
        ready = false
        setStatus(.idle)
    }

    func reloadModel() {
        ready = false
        peakDownloadBytes = 0
        // Switching engines mid-download has to stop the old one, or choosing
        // Apple Intelligence to avoid a 2.4 GB download quietly finishes the
        // 2.4 GB download anyway.
        loadTask?.cancel()
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

        // Detached, with the result delivered through `onMainNow` instead of
        // by resuming on the main actor.
        //
        // `Transcriber` is an actor, so the weights already load off the main
        // thread. What used to stall was the *resumption*: awaiting from a
        // main-actor task hands the continuation to the main dispatch queue,
        // and that queue does not drain while a menu is open. So `ready` was
        // set, and the icon and menu updated, only once the user closed the
        // menu they had opened to watch for exactly that change. The line said
        // "Dictation starts once this finishes" while being the reason it
        // could not finish.
        let engine = transcriber
        loadTask = Task.detached { [weak self] in
            do {
                try await engine.load(choice)
                Self.onMainNow { self?.modelDidLoad() }
            } catch {
                // A cancelled load is a deliberate switch to another engine,
                // not a failure. Reporting it as one would put a red error on
                // the step at the exact moment the user did the right thing.
                //
                // Checked before touching the download watch: by the time a
                // cancelled task resumes, the engine it was replaced by may
                // already have started its own, and tearing that down would
                // freeze the new one's progress at whatever it last showed.
                if Task.isCancelled || error is CancellationError {
                    log("model load cancelled")
                    return
                }
                log("model load failed: \(error)")
                // Rendered here rather than carried across: an arbitrary Error
                // is not Sendable, and a String is.
                let message = ModelStatus.describe(error)
                Self.onMainNow { self?.modelDidFail(message) }
            }
        }
    }

    private func modelDidLoad() {
        stopDownloadWatch()
        ready = true
        setStatus(.ready)
    }

    private func modelDidFail(_ message: String) {
        stopDownloadWatch()
        setStatus(.failed(message))
    }

    /// Run `body` on the main thread, including while a menu is open.
    ///
    /// Anything routed through the main actor is delivered on the main dispatch
    /// queue, and that queue does not drain during the modal tracking loop
    /// NSMenu runs while it is on screen. `RunLoop.perform(inModes:)` is the
    /// way in: `.common` covers the event-tracking mode AppKit uses for menus,
    /// so the block runs with the menu still open rather than after it closes.
    ///
    /// `assumeIsolated` asserts something already true, since
    /// `perform(inModes:)` runs the block on the main thread. It is what makes
    /// this synchronous, and a hop back through the main actor here would
    /// reintroduce the whole problem.
    nonisolated private static func onMainNow(
        _ body: @escaping @Sendable @MainActor () -> Void
    ) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { body() }
        }
    }

    /// Measures the bytes actually on disk, once a second.
    ///
    /// The library's own progress handler counts *completed files*, so with one
    /// dominant 2.3 GB weights file it reports the few KB of JSON and then
    /// nothing at all until the whole thing lands. That produced a bar frozen
    /// at 0% for the entire download, which is precisely the failure the
    /// elapsed-time display was invented to avoid.
    ///
    /// The Hugging Face client streams into `blobs/<etag>`, and that file grows
    /// as it arrives, so the download directory is a truthful second-by-second
    /// measure even though mlx-audio's own copy is not.
    private func startDownloadWatch(_ choice: ModelChoice, started: Date) {
        downloadWatch?.invalidate()
        // .common, not the default mode. An open menu puts the run loop into
        // event tracking, and a timer scheduled the usual way stops firing for
        // exactly as long as the user is looking at the thing it updates.
        let timer = Timer(timeInterval: 1.0, repeats: true) {
            [weak self] _ in
            // Synchronously, not `Task { @MainActor in }`. A timer added to
            // RunLoop.main already fires on the main thread, so that hop bought
            // nothing and cost everything: it re-entered through the main
            // dispatch queue, which does not drain during a menu's tracking
            // loop, so scheduling the timer in `.common` above stopped meaning
            // anything the moment a menu was open. This line froze for exactly
            // as long as the user watched it.
            MainActor.assumeIsolated {
                guard let self, case .downloading = self.status else { return }
                if choice.isDownloaded {
                    self.setStatus(.loading)
                    return
                }
                // Bytes on disk plus bytes in flight. See
                // ModelChoice.inFlightBytes for why the library's own Progress
                // cannot be used here.
                // Hold the last real reading through a stall rather than
                // taking a running maximum. A maximum sounds equivalent and is
                // not: seeded with a stale value it can never come down, which
                // is how an abandoned 1.42 GB temp file froze the display for
                // the rest of the download.
                var bytes = choice.bytesOnDisk
                if bytes == 0 { bytes = self.peakDownloadBytes }
                self.peakDownloadBytes = bytes
                let fraction = choice.approxBytes > 0
                    ? min(1.0, Double(bytes) / Double(choice.approxBytes))
                    : nil
                self.setStatus(.downloading(
                    elapsed: Date().timeIntervalSince(started),
                    total: choice.approxBytes,
                    received: bytes,
                    fraction: fraction))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        downloadWatch = timer
    }

    private func stopDownloadWatch() {
        downloadWatch?.invalidate()
        downloadWatch = nil
    }

    private func setStatus(_ s: ModelStatus) {
        status = s
        // refreshMenu only runs on menuWillOpen, so a menu that is already
        // open would show whatever it said when it appeared. Setting the
        // title directly is the only thing that reaches it.
        if s.isBusy {
            statusMenuItem?.title = s.summary.prefix(1).uppercased() + s.summary.dropFirst()
        }
        switch s {
        case .idle:        setIcon(.idle, s.summary)
        case .downloading: setIcon(.downloading, s.summary)
        case .loading:     setIcon(.idle, s.summary)
        case .ready:       setIcon(.ready, s.summary)
        case .failed:      setIcon(.failed, s.summary)
        }
        onStatusChange?(s)
    }

    // MARK: - Menu

    /// Kept deliberately thin. Everything configurable lives in Settings; the
    /// menu is for status and the two things worth reaching in one click.
    func refreshMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        // Say whose menu this is. Someone who cannot place an icon in their
        // menu bar clicks it to find out, and until this row existed the only
        // answer was "About Speak", five items down past the shortcut, the
        // transcripts and Settings.
        let name = NSMenuItem(title: "Speak", action: nil, keyEquivalent: "")
        name.isEnabled = false
        name.image = MenuBarIcon.ready.menuImage
        menu.addItem(name)
        menu.addItem(.separator())

        // Until the model is usable, say so first: the shortcut does nothing
        // yet, and a silent beep explains nothing.
        switch status {
        case .ready:
            let hint = NSMenuItem(title: "\(Shortcut.description) toggles dictation",
                                  action: nil, keyEquivalent: "")
            hint.image = symbol("keyboard")
            menu.addItem(hint)
        case .idle:
            let item = NSMenuItem(title: "Finish setup to start dictating",
                                  action: #selector(openOnboarding), keyEquivalent: "")
            item.target = self
            item.image = symbol("arrow.down.circle")
            menu.addItem(item)
        case .downloading, .loading:
            let item = NSMenuItem(title: status.summary.prefix(1).uppercased()
                                  + status.summary.dropFirst(),
                                  action: nil, keyEquivalent: "")
            item.image = symbol("arrow.down.circle")
            statusMenuItem = item          // updated in place while showing
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

    private func setIcon(_ icon: MenuBarIcon, _ tip: String) {
        let image = icon.image
        image.accessibilityDescription = tip
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Speak: \(tip)"
        log(tip)
    }

    @objc private func openSettings() { settings.show() }
    /// The shortcut lives at the top of General.
    func openSettingsAtShortcut() { settings.show(selecting: .general) }
    @objc private func openAbout() { settings.show(selecting: .about) }
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
            setIcon(.failed, "event tap refused; check Accessibility")
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

        // Escape abandons a recording. Only while recording, and the keystroke
        // is swallowed then so it does not also dismiss whatever is in front.
        // At any other time Escape is none of our business.
        if code == kVK_Escape, recorder.isRecording {
            cancelDictation()
            return true
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
            setIcon(.transcribing, "transcribing…")
            indicator.show(.transcribing)
            guard let pcm = recorder.stop() else {
                setIcon(.ready, "ready"); indicator.hide(); return
            }
            let seconds = Double(pcm.count) / SAMPLE_RATE
            Task {
                let raw = await transcriber.transcribe(pcm)
                var text = raw
                if let raw {
                    // Corrections run either side of polishing, and still run
                    // when there is no polishing to do.
                    let cleaned = await CustomDictionary.applyAround(raw) { corrected in
                        // Announced from inside the polisher rather than guessed
                        // at from the setting: this fires only when a request is
                        // actually about to be made, so nobody whose Mac cannot
                        // polish is told that it is polishing.
                        await polisher.polish(corrected) { [weak self] step, total in
                            Task { @MainActor in
                                self?.setIcon(.transcribing, "polishing…")
                                self?.indicator.show(.polishing(step: step, of: total))
                            }
                        }
                    }
                    // Last, so it sees whatever the model and the dictionary
                    // settled on rather than the engine's first guess.
                    text = Punctuation.trimFragment(cleaned)
                }
                // Held up through polishing: it means "still working", and the
                // wait it is covering is now longer than the transcription.
                indicator.hide()
                if let text {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    if Settings.autoPaste { paste() }
                    // The raw transcript is kept only when something changed it,
                    // so history stays a record of what was said as well as what
                    // was pasted. Nothing to compare against otherwise.
                    History.append(.init(date: Date(), duration: seconds, text: text,
                                         raw: text == raw ? nil : raw))
                    setIcon(.ready, "copied \(text.split(separator: " ").count) words")
                    Cue.done()
                } else {
                    setIcon(.ready, "nothing transcribed")
                    Cue.failed()
                }
                // Onboarding's try-it-out step listens here, so the user sees
                // their own words rather than being told it worked.
                onTranscript?(text)
            }
        } else {
            guard ready else { NSSound.beep(); return }
            // Tied to the first audio buffer, not to this line: it has to mean
            // "the microphone is live", and the engine takes a moment. If
            // another app is holding the device it never fires, which is the
            // truthful outcome.
            recorder.onFirstBuffer = { Cue.start() }
            do {
                try recorder.start()
                setIcon(.recording, "recording…")
                if Settings.showIndicator { indicator.show(.recording) }
                // Load the polishing model and the word list while the user is
                // still talking. The first request to a cold model is the slow
                // one, and this spends time they were going to spend anyway.
                Task {
                    CustomDictionary.warm()
                    await polisher.prewarm()
                }
            } catch {
                setIcon(.failed, "mic error: \(error)")
                indicator.hide()
            }
        }
    }

    /// Abandon a recording without producing a transcript.
    ///
    /// Without this, a shortcut pressed by accident has no way out that does
    /// not overwrite the clipboard, and the clipboard is somebody's working
    /// state.
    func cancelDictation() {
        guard recorder.isRecording else { return }
        _ = recorder.stop()
        indicator.hide()
        Cue.cancel()
        setIcon(.ready, "cancelled")
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
