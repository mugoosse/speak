import AppKit
import MLXAudioCore
import MLXAudioSTT

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

        // The first pass includes Metal kernel compilation; the app pays that
        // once at launch via its warm-up, so report warm timings too.
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

// `speak --polish [text|-]` runs the post-processing chain on its own: the
// polishing model, then the dictionary's corrections. Reads stdin when given
// `-` or nothing, so it composes with the mode above:
//
//     speak --transcribe some.wav | speak --polish -
//
// There is no test target, so this is how the chain gets verified. It also
// separates a polishing problem from a dictation one, the same way
// `--transcribe` separates a model problem from a shortcut problem.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--polish" {
    let argument = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "-"
    let input: String
    if argument == "-" {
        input = String(
            data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    } else {
        input = argument
    }

    if let reason = Polisher.unavailableReason { log("no polishing: \(reason)") }
    let t0 = Date()
    let polisher = Polisher()
    let out = await CustomDictionary.applyAround(input) {
        await polisher.polish($0, force: true)
    }
    log(String(format: "polish %.1fs", Date().timeIntervalSince(t0)))
    print(Punctuation.trimFragment(out))
    exit(0)
}

// `speak --hud-demo` shows one recording pill per meter style, stacked and all
// driven by the same microphone, so the styles can be compared rather than
// remembered. `--fake` swaps the microphone for a synthetic speech envelope.
// See MeterDemo for how to launch it.
if CommandLine.arguments.contains("--hud-demo") {
    let app = NSApplication.shared
    let demo = MeterDemo(fake: CommandLine.arguments.contains("--fake"))
    app.delegate = demo
    app.setActivationPolicy(.accessory)
    objc_setAssociatedObject(app, "speak.demo", demo, .OBJC_ASSOCIATION_RETAIN)
    app.run()
    exit(0)
}

// Top-level code in main.swift is already main-actor isolated, so the App can
// be constructed directly. (Wrapping this in MainActor.assumeIsolated is an
// error under Swift 6: assumeIsolated is unavailable from an async context,
// and the `await` above makes this one.)
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)     // menu bar only, no Dock icon
// NSApplication holds its delegate weakly, so keep a strong reference.
objc_setAssociatedObject(app, "speak.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
app.run()
