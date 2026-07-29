import AppKit
import AVFoundation
import Carbon.HIToolbox
import MLX
import MLXAudioCore
import MLXAudioSTT

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

let MODEL = ProcessInfo.processInfo.environment["SPEAK_MODEL"]
    ?? "mlx-community/parakeet-tdt-0.6b-v3"
let AUTO_PASTE = ProcessInfo.processInfo.environment["SPEAK_AUTOPASTE"] == "1"

/// Device-dependent modifier masks. NSEvent's `.shift` cannot tell left from
/// right; these IOKit-level bits can.
let LEFT_SHIFT_MASK: UInt = 0x0000_0002
let FN_KEYCODE: UInt16 = 63

let SAMPLE_RATE = 16000.0

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

    func load() async throws {
        model = try await STT.loadModel(modelRepo: MODEL)
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
        let audio = MLXArray(pcm)
        let out = m.generate(audio: audio, generationParameters: params())
        let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

@MainActor
final class App: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private var monitors: [Any] = []
    private var fnDown = false
    private var leftShiftDown = false
    private var comboLatched = false
    private var ready = false

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("mic.slash", "loading model…")

        let menu = NSMenu()
        menu.addItem(withTitle: "Fn + Left Shift toggles dictation",
                     action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        statusItem.menu = menu

        requestMic()

        Task {
            do {
                try await transcriber.load()
                ready = true
                setIcon("mic", "ready")
            } catch {
                setIcon("exclamationmark.triangle", "model failed: \(error)")
            }
        }

        guard ensureAccessibility() else {
            setIcon("exclamationmark.triangle", "grant Accessibility, then relaunch")
            return
        }
        installHotkey()
    }

    private func setIcon(_ symbol: String, _ tip: String) {
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: tip)
        statusItem.button?.toolTip = "speak — \(tip)"
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

    /// Modifier-only chords never arrive as keyDown, so watch flagsChanged and
    /// reconstruct the chord from device-dependent flags.
    private func installHotkey() {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: {
            [weak self] e in Task { @MainActor in self?.handleFlags(e) }
        }) { monitors.append(g) }

        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: {
            [weak self] e in self?.handleFlags(e); return e
        }) { monitors.append(l) }
    }

    private func handleFlags(_ e: NSEvent) {
        // `.function` is also set by arrows and F-keys, so only trust it when
        // the physical Fn key is what changed.
        if e.keyCode == FN_KEYCODE {
            fnDown = e.modifierFlags.contains(.function)
        }
        leftShiftDown = (e.modifierFlags.rawValue & LEFT_SHIFT_MASK) != 0

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
            Task {
                let text = await transcriber.transcribe(pcm)
                if let text {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    if AUTO_PASTE { paste() }
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
        let model = try await STT.loadModel(modelRepo: MODEL)
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
        print(out.text.trimmingCharacters(in: .whitespacesAndNewlines))
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
