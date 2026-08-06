import AppKit
import AVFoundation

/// Stacks one recording pill per meter style, all fed from the same microphone,
/// so the three can be judged against each other rather than one after another
/// from memory.
///
/// Run it with `open -n -a /Applications/Speak.app --args --hud-demo`. The `-n`
/// matters: without it a copy of Speak already running swallows the launch and
/// nothing appears. Going through the bundle rather than the binary matters
/// too, since the microphone grant belongs to the bundle, and running the
/// binary from a terminal asks the terminal for its own.
///
/// `--fake` drives the pills from a synthetic voice envelope instead of the
/// microphone, which is how the animation gets checked without anybody having
/// to talk to it.
@MainActor
final class MeterDemo: NSObject, NSApplicationDelegate {
    private var indicators: [RecordingIndicator] = []
    private let recorder = Recorder()
    private let fake: Bool
    private var fakeClock: Timer?
    private var t: Double = 0
    private var shown: String?

    init(fake: Bool) {
        self.fake = fake
        super.init()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Bottom to top in the order they were invented, so the one being
        // compared against is nearest the Dock where it normally lives.
        for (i, style) in MeterStyle.allCases.enumerated() {
            let indicator = RecordingIndicator(style: style)
            indicator.bottomInset = 90 + CGFloat(i) * 56
            indicator.caption = style == Settings.meterStyle
                ? "\(style.title) (now)" : style.title
            indicator.onCancel = { NSApp.terminate(nil) }
            indicator.show(.recording)
            indicators.append(indicator)
        }

        if fake { startFake() } else { startMicrophone() }
    }

    private func startMicrophone() {
        recorder.onLevel = { [weak self] level in
            // Off the audio thread, and in order: the waveform is a queue, so a
            // reordered sample is a bar in the wrong place.
            DispatchQueue.main.async {
                self?.indicators.forEach { $0.level(level) }
            }
        }
        Permissions.requestMicrophone { [weak self] granted in
            guard let self else { return }
            guard granted else {
                FileHandle.standardError.write(
                    "no microphone permission, use --fake\n".data(using: .utf8)!)
                NSApp.terminate(nil)
                return
            }
            do { try self.recorder.start() } catch {
                FileHandle.standardError.write(
                    "microphone: \(error)\n".data(using: .utf8)!)
                NSApp.terminate(nil)
            }
        }
    }

    /// Syllables inside phrases inside breaths, roughly: the point is that the
    /// meters get something with the shape of speech rather than a sine wave,
    /// since the whole question is how they behave across gaps.
    ///
    /// It also cycles through the pill's states, because the handover from
    /// recording to transcribing is where a spanning meter gives its width back
    /// to the label, and that is a transition nobody can watch by dictating:
    /// transcription is over before you have looked down.
    private func startFake() {
        let timer = Timer(timeInterval: 1.0 / 31.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.t += 1.0 / 31.0
                let phrase = sin(self.t * 0.7) > -0.35 ? 1.0 : 0.0
                let syllable = pow(max(0, sin(self.t * 9.0)), 0.6)
                let level = Float(phrase * (0.25 + 0.6 * syllable))
                self.indicators.forEach { $0.level(level) }

                let cycle = self.t.truncatingRemainder(dividingBy: 14)
                let next: RecordingIndicator.State =
                    cycle < 9 ? .recording
                    : cycle < 11 ? .transcribing
                    : .polishing(step: 1, of: 2)
                if self.shown != next.text {
                    self.shown = next.text
                    self.indicators.forEach { $0.show(next) }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fakeClock = timer
    }
}
