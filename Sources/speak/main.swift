import AppKit
import AVFoundation
import Carbon.HIToolbox
import MLX
import MLXAudioCore
import MLXAudioSTT

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/// Selectable models.
///
/// v2 is the default because it is English-only and therefore *cannot* emit
/// Cyrillic. v3 is multilingual across 25 European languages, but on a short
/// utterance with little context it will decode English speech as Russian, and
/// mlx-audio offers no way to pin it: the `language` parameter is copied into
/// the output struct and never reaches the decoder. Pick v3 only if you
/// actually dictate in another language, and expect occasional drift.
struct ModelChoice {
    let id: String
    let title: String
    let detail: String
    let repo: String

    static let all: [ModelChoice] = [
        .init(id: "v2", title: "English only",
              detail: "Parakeet v2 · cannot drift to other languages",
              repo: "mlx-community/parakeet-tdt-0.6b-v2"),
        .init(id: "v3", title: "Multilingual",
              detail: "Parakeet v3 · 25 languages · may misdetect short clips",
              repo: "mlx-community/parakeet-tdt-0.6b-v3"),
    ]

    static let fallback = all[0]

    static func named(_ id: String) -> ModelChoice? { all.first { $0.id == id } }
}

enum Settings {
    private static let key = "modelID"

    /// SPEAK_MODEL still wins, so a one-off override works without touching
    /// the saved preference.
    static var envOverride: String? {
        ProcessInfo.processInfo.environment["SPEAK_MODEL"]
    }

    static var choice: ModelChoice {
        get {
            guard let id = UserDefaults.standard.string(forKey: key),
                  let c = ModelChoice.named(id) else { return .fallback }
            return c
        }
        set { UserDefaults.standard.set(newValue.id, forKey: key) }
    }

    static var activeRepo: String { envOverride ?? choice.repo }
}
let AUTO_PASTE = ProcessInfo.processInfo.environment["SPEAK_AUTOPASTE"] == "1"

/// Device-dependent modifier masks. NSEvent's `.shift` cannot tell left from
/// right; these IOKit-level bits can.
let LEFT_SHIFT_MASK: UInt = 0x0000_0002
let FN_KEYCODE: UInt16 = 63

let SAMPLE_RATE = 16000.0

/// Diagnostics on stderr. `SPEAK_DEBUG=1` additionally traces every modifier
/// change, which is how you find out what your keyboard actually reports.
let DEBUG = ProcessInfo.processInfo.environment["SPEAK_DEBUG"] == "1"

func log(_ s: String) {
    FileHandle.standardError.write("[Speak] \(s)\n".data(using: .utf8)!)
}

// ---------------------------------------------------------------------------
// Audio capture: mic -> 16 kHz mono Float32, which is what Parakeet expects
// ---------------------------------------------------------------------------

final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: SAMPLE_RATE,
        channels: 1,
        interleaved: false
    )!

    func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(); lock.unlock()

        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: target)

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            guard let self, let conv = self.converter else { return }
            let ratio = SAMPLE_RATE / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: capacity)
            else { return }

            var err: NSError?
            var supplied = false
            conv.convert(to: out, error: &err) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buf
            }
            guard err == nil, out.frameLength > 0,
                  let ch = out.floatChannelData?[0] else { return }

            let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
            self.lock.lock(); self.samples.append(contentsOf: chunk); self.lock.unlock()
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops capture and hands back raw samples. No temp file: the samples go
    /// straight into an MLXArray.
    func stop() -> [Float]? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        lock.lock(); let pcm = samples; samples.removeAll(); lock.unlock()
        return pcm.count > Int(SAMPLE_RATE / 10) ? pcm : nil   // ignore < 0.1 s
    }
}

// ---------------------------------------------------------------------------
// Transcription, in-process
// ---------------------------------------------------------------------------

actor Transcriber {
    private var model: (any STTGenerationModel)?

    func load(_ repo: String) async throws {
        model = nil                       // drop the old weights before loading
        model = try await STT.loadModel(modelRepo: repo)
        // Warm the compute graph so the first real dictation isn't slow.
        if let m = model {
            let silence = MLXArray(Array(repeating: Float(0), count: Int(SAMPLE_RATE)))
            _ = m.generate(audio: silence, generationParameters: params())
        }
    }

    private func params() -> STTGenerateParameters {
        // Utterances are short, so a single chunk is the common case; the
        // 120 s ceiling only matters for a long unbroken dictation.
        STTGenerateParameters(chunkDuration: 120)
    }

    func transcribe(_ pcm: [Float]) -> String? {
        guard let m = model else { return nil }
        // Pad very short clips with silence. Parakeet degrades badly on inputs
        // shorter than about a second, and a one-word dictation is easily that
        // short. TypeWhisper does the same thing for the same reason.
        var samples = pcm
        let minimum = Int(SAMPLE_RATE)
        if samples.count < minimum {
            samples.append(contentsOf: repeatElement(0, count: minimum - samples.count))
        }
        let audio = MLXArray(samples)
        let out = m.generate(audio: audio, generationParameters: params())
        let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

/// Append-only JSONL log of every dictation.
///
/// JSONL rather than a database so the file stays greppable and survives the
/// app entirely: `jq -r .text history.jsonl` gets you everything ever said.
struct History {
    static let dir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/speak")
    static let file = dir.appendingPathComponent("history.jsonl")

    struct Entry {
        let date: Date
        let duration: Double
        let text: String
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func append(_ e: Entry) {
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)

        let obj: [String: Any] = [
            "at": iso.string(from: e.date),
            // Format via string: (x*100).rounded()/100 still lands on 6.200000000000002.
            "duration_sec": Double(String(format: "%.1f", e.duration)) ?? e.duration,
            "words": e.text.split(separator: " ").count,
            "text": e.text,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }

        var line = data
        line.append(0x0a)

        if let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }

    /// Most recent entries, newest first. Reads the tail only.
    static func recent(_ n: Int) -> [Entry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(n).reversed().compactMap { line in
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = o["text"] as? String,
                  let at = o["at"] as? String else { return nil }
            return Entry(date: iso.date(from: at) ?? Date(timeIntervalSince1970: 0),
                         duration: o["duration_sec"] as? Double ?? 0,
                         text: t)
        }
    }
}

// ---------------------------------------------------------------------------
// Permissions
// ---------------------------------------------------------------------------

enum Permissions {
    static var microphone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Note the `prompt: false` variant: checking must not nag, only the
    /// explicit button in onboarding should raise the system dialog.
    static var accessibility: Bool {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
                as CFDictionary)
    }

    static var allGranted: Bool { microphone && accessibility }

    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { g in
            DispatchQueue.main.async { done(g) }
        }
    }

    static func promptAccessibility() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                as CFDictionary)
        openAccessibilitySettings()
    }

    static func openAccessibilitySettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// ---------------------------------------------------------------------------
// Onboarding
// ---------------------------------------------------------------------------

/// First-run setup. Shown automatically until both permissions are granted,
/// and reachable afterwards from the menu.
@MainActor
final class Onboarding: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var refresh: Timer?
    private var rows: [(dot: NSTextField, label: NSTextField, button: NSButton?)] = []
    private var onDone: (() -> Void)?

    func show(onDone: (() -> Void)? = nil) {
        self.onDone = onDone
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Set up Speak"
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false
        // Accessory apps have no Dock icon or app-switcher entry, so a window
        // that falls behind is unrecoverable. Keep it above normal windows.
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Speak needs two permissions")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        root.addArrangedSubview(title)

        let blurb = NSTextField(wrappingLabelWithString:
            "Both are granted once and remembered across updates. "
            + "Nothing leaves your Mac.")
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = 460
        root.addArrangedSubview(blurb)

        rows.append(addRow(to: root,
            text: "Microphone — so Speak can hear you",
            buttonTitle: "Request",
            action: #selector(requestMic)))

        rows.append(addRow(to: root,
            text: "Accessibility — so Fn + Left Shift works anywhere",
            buttonTitle: "Open Settings",
            action: #selector(openAccessibility)))

        let note = NSTextField(wrappingLabelWithString:
            "In Accessibility, switch on “Speak”. If it is already on but the "
            + "hotkey does nothing, switch it off and on again — macOS keeps a "
            + "stale entry after an app is replaced.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 460
        root.addArrangedSubview(note)

        rows.append(addRow(to: root,
            text: "Press Fn + Left Shift, talk, press again. Paste with ⌘V.",
            buttonTitle: nil, action: nil))

        let done = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        done.keyEquivalent = "\r"
        root.addArrangedSubview(done)

        w.contentView = root
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        update()
        refresh = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    private func addRow(to stack: NSStackView, text: String,
                        buttonTitle: String?, action: Selector?)
        -> (NSTextField, NSTextField, NSButton?) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let dot = NSTextField(labelWithString: "○")
        dot.font = .systemFont(ofSize: 15)
        row.addArrangedSubview(dot)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        row.addArrangedSubview(label)

        var button: NSButton?
        if let buttonTitle, let action {
            let b = NSButton(title: buttonTitle, target: self, action: action)
            b.controlSize = .small
            row.addArrangedSubview(b)
            button = b
        }

        stack.addArrangedSubview(row)
        return (dot, label, button)
    }

    private func update() {
        let states = [Permissions.microphone, Permissions.accessibility,
                      Permissions.allGranted]
        for (i, ok) in states.enumerated() where i < rows.count {
            rows[i].dot.stringValue = ok ? "●" : "○"
            rows[i].dot.textColor = ok ? .systemGreen : .tertiaryLabelColor
            rows[i].button?.isHidden = ok
        }
        if Permissions.allGranted { onDone?() }
    }

    @objc private func requestMic() {
        Permissions.requestMicrophone { [weak self] granted in
            // A denial is sticky: only Settings can undo it.
            if !granted { Permissions.openAccessibilitySettings() }
            self?.update()
            self?.resurface()
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

    @objc private func closeWindow() { window?.close() }

    func windowWillClose(_ n: Notification) {
        refresh?.invalidate()
        refresh = nil
        window = nil
        rows = []
    }
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private var eventTap: CFMachPort?
    private var fnDown = false
    private var leftShiftDown = false
    private var comboLatched = false
    private var ready = false
    private let onboarding = Onboarding()

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("mic.slash", "loading model…")

        let menu = NSMenu()
        menu.delegate = self          // rebuild history section on open
        statusItem.menu = menu
        rebuildMenu()

        loadModel()

        if Permissions.allGranted {
            installHotkey()
        } else {
            setIcon("exclamationmark.triangle", "setup needed")
            onboarding.show { [weak self] in
                // Fires as soon as both permissions land, so the hotkey arms
                // without the user having to relaunch.
                guard let self, self.eventTap == nil else { return }
                self.installHotkey()
                self.setIcon(self.ready ? "mic" : "mic.slash",
                             self.ready ? "ready" : "loading model…")
            }
        }
    }

    private func loadModel() {
        ready = false
        let repo = Settings.activeRepo
        setIcon("mic.slash", "loading \(Settings.choice.title.lowercased())…")
        Task {
            do {
                try await transcriber.load(repo)
                ready = true
                setIcon("mic", "ready")
            } catch {
                setIcon("exclamationmark.triangle", "model failed: \(error)")
            }
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let choice = ModelChoice.named(sender.representedObject as? String ?? ""),
              choice.id != Settings.choice.id else { return }
        Settings.choice = choice
        if Settings.envOverride != nil {
            log("SPEAK_MODEL is set; it overrides the menu selection")
        }
        loadModel()
    }

    @objc private func showOnboarding() { onboarding.show() }

    /// Rebuilt whenever the menu opens so the history section stays current.
    fileprivate func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        menu.addItem(withTitle: "Fn + Left Shift toggles dictation",
                     action: nil, keyEquivalent: "")

        menu.addItem(.separator())
        let modelHeader = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelHeader.isEnabled = false
        menu.addItem(modelHeader)

        for choice in ModelChoice.all {
            let item = NSMenuItem(title: choice.title,
                                  action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.id
            item.state = (choice.id == Settings.choice.id) ? .on : .off
            item.toolTip = choice.detail
            if Settings.envOverride != nil { item.isEnabled = false }
            menu.addItem(item)
        }
        if Settings.envOverride != nil {
            let note = NSMenuItem(title: "  overridden by SPEAK_MODEL",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        let entries = History.recent(10)
        if !entries.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent (click to copy)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let stamp = DateFormatter()
            stamp.dateFormat = "MMM d, HH:mm"

            for (i, e) in entries.enumerated() {
                var preview = e.text.replacingOccurrences(of: "\n", with: " ")
                if preview.count > 60 { preview = String(preview.prefix(59)) + "…" }
                let item = NSMenuItem(
                    title: "\(stamp.string(from: e.date))  \(preview)",
                    action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let open = NSMenuItem(title: "Open history file…",
                                  action: #selector(openHistory), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }

        menu.addItem(.separator())
        let setup = NSMenuItem(title: Permissions.allGranted ? "Setup…" : "Finish setup…",
                               action: #selector(showOnboarding), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        let entries = History.recent(10)
        guard sender.tag < entries.count else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entries[sender.tag].text, forType: .string)
    }

    @objc private func openHistory() {
        NSWorkspace.shared.activateFileViewerSelecting([History.file])
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func setIcon(_ symbol: String, _ tip: String) {
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: tip)
        statusItem.button?.toolTip = "Speak — \(tip)"
        log(tip)
    }

    private func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                Task { @MainActor in
                    self.setIcon("exclamationmark.triangle", "microphone denied")
                }
            }
        }
    }

    private func ensureAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    /// Modifier-only chords never arrive as keyDown, so we watch flagsChanged.
    ///
    /// This uses a CGEventTap rather than an NSEvent global monitor because on
    /// Apple Silicon the Globe/Fn key is swallowed by the system before it
    /// reaches NSEvent: a global monitor sees the shift half of the chord and
    /// never the Fn half. The tap sits lower down and reports Fn as
    /// `.maskSecondaryFn`.
    private func installHotkey() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,           // observe only, never swallow keys
            eventsOfInterest: mask,
            callback: { _, _, event, ctx in
                if let ctx {
                    let app = Unmanaged<App>.fromOpaque(ctx).takeUnretainedValue()
                    let flags = event.flags
                    Task { @MainActor in app.handleFlags(flags) }
                }
                return Unmanaged.passUnretained(event)
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

    fileprivate func handleFlags(_ flags: CGEventFlags) {
        fnDown = flags.contains(.maskSecondaryFn)
        leftShiftDown = (flags.rawValue & UInt64(LEFT_SHIFT_MASK)) != 0

        if DEBUG {
            log(String(format: "raw=0x%09llx fn=%@ lshift=%@",
                       flags.rawValue, fnDown ? "Y" : "n", leftShiftDown ? "Y" : "n"))
        }

        if fnDown && leftShiftDown {
            if !comboLatched { comboLatched = true; toggle() }
        } else {
            comboLatched = false        // require a fresh press to re-fire
        }
    }

    private func toggle() {
        if recorder.isRecording {
            setIcon("hourglass", "transcribing…")
            guard let pcm = recorder.stop() else { setIcon("mic", "ready"); return }
            let seconds = Double(pcm.count) / SAMPLE_RATE
            Task {
                let text = await transcriber.transcribe(pcm)
                if let text {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    if AUTO_PASTE { paste() }
                    History.append(.init(date: Date(), duration: seconds, text: text))
                    setIcon("mic", "copied \(text.split(separator: " ").count) words")
                } else {
                    setIcon("mic", "nothing transcribed")
                }
            }
        } else {
            guard ready else { NSSound.beep(); return }
            do { try recorder.start(); setIcon("record.circle", "recording…") }
            catch { setIcon("exclamationmark.triangle", "mic error: \(error)") }
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

// `speak --transcribe <audio>` runs headless. Useful for verifying the model
// path without granting Accessibility, and for one-off files.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--transcribe" {
    let path = CommandLine.arguments[2]
    do {
        let t0 = Date()
        let model = try await STT.loadModel(modelRepo: Settings.activeRepo)
        let load = Date().timeIntervalSince(t0)
        let (_, audio) = try loadAudioArray(
            from: URL(fileURLWithPath: path), sampleRate: Int(SAMPLE_RATE))
        // First pass includes Metal kernel compilation; the app pays this once
        // at launch via its warm-up, so report warm timings too.
        var out = model.generate(
            audio: audio, generationParameters: STTGenerateParameters(chunkDuration: 120))
        var timings: [String] = []
        for _ in 0..<3 {
            let t = Date()
            out = model.generate(
                audio: audio, generationParameters: STTGenerateParameters(chunkDuration: 120))
            timings.append(String(format: "%.0fms", Date().timeIntervalSince(t) * 1000))
        }
        FileHandle.standardError.write(
            "load \(String(format: "%.1f", load))s, warm: \(timings.joined(separator: ", "))\n"
                .data(using: .utf8)!)
        print(out.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // menu bar only, no dock icon
    // NSApplicationDelegate is held weakly, so keep our own strong reference.
    objc_setAssociatedObject(app, "speak.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
