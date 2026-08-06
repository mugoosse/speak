import AppKit

/// What the recording pill puts to the left of the word "Listening".
///
/// All three answer "is Speak switched on". Only two of them answer "is Speak
/// hearing me", which is the question that actually goes wrong: a muted input,
/// a headset back in its case and a microphone pointed at the wrong edge of the
/// laptop are all indistinguishable from a working one if the indicator is
/// driven by a timer.
enum MeterStyle: String, CaseIterable {
    /// A fixed dot fading in and out on a timer. Says "recording" and nothing
    /// else: it looks exactly the same into a dead microphone.
    case pulse
    /// One dot whose diameter, brightness and halo follow the voice.
    case orb
    /// A scrolling strip of mirrored bars, newest on the right: the last second
    /// and a half of loudness, so a gap is visible after it has passed.
    case waveform

    /// What Settings offers. `pulse` is not among them: it is kept only so
    /// `--hud-demo` can still show what the other two replaced, since "is this
    /// better" is a question about a moving thing and cannot be answered from a
    /// screenshot or from memory of the build before last.
    static let selectable: [MeterStyle] = [.waveform, .orb]

    var meter: MeterView {
        switch self {
        case .pulse:    return PulseMeter()
        case .orb:      return OrbMeter()
        case .waveform: return WaveMeter()
        }
    }

    /// For the comparison harness and for anything that has to name the choice
    /// in a sentence.
    var title: String {
        switch self {
        case .pulse:    return "Pulse"
        case .orb:      return "Orb"
        case .waveform: return "Waveform"
        }
    }

    /// What picking it costs, said on screen rather than hidden in a tooltip.
    var blurb: String {
        switch self {
        case .pulse:
            return "A blinking dot. It looks the same whether or not anything "
                + "is reaching the microphone."
        case .orb:
            return "A dot that grows and brightens with your voice. The "
                + "smaller pill, and still enough to tell a live microphone "
                + "from a dead one."
        case .waveform:
            return "The last two seconds of what the microphone heard, "
                + "scrolling. A wider pill, and the only one that shows a gap "
                + "after it has happened."
        }
    }
}

/// The animated half of the recording pill.
///
/// Three states, and the middle one is the point. `begin` is the microphone
/// open and every movement driven by it. `working` is the microphone closed
/// with the transcriber still busy: it must keep moving, because a pill that
/// freezes reads as an app that hung, but nothing it does may look like it is
/// still hearing something, because it is not. `end` is off screen.
@MainActor
class MeterView: NSView {
    /// How much width the pill has to reserve for this style.
    class var width: CGFloat { 12 }

    /// Whether this style takes the pill over while recording, pushing the word
    /// "Listening" out of it.
    ///
    /// Only the waveform earns that. A dot next to no text is a light on a
    /// dashboard and needs the word to say which light; a waveform reacting to
    /// your own voice already says "listening" more precisely than the word
    /// does, so keeping both is spending the pill's width to repeat itself.
    class var spans: Bool { false }

    var tint: NSColor = .systemRed { didSet { needsDisplay = true } }

    /// Newest loudness, 0 for a silent room and 1 for shouting.
    func push(_ level: CGFloat) {}

    func begin() {}
    func working() {}
    func end() {}

    // MARK: - Frame clock

    private var frames: Timer?

    /// 60 Hz, in `.common` mode.
    ///
    /// The default run loop mode stops firing while a menu is open or a window
    /// is being dragged, and a meter that freezes mid-sentence is worse than
    /// one that never moved: it reads as the app having crashed at exactly the
    /// moment the user is trusting it with their words.
    func startFrames() {
        stopFrames()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        frames = t
    }

    func stopFrames() {
        frames?.invalidate()
        frames = nil
    }

    /// One animation frame. Subclasses advance their own state and redraw.
    func step() {}

    deinit { frames?.invalidate() }
}

/// Follows a target with a fast attack and a slow release.
///
/// Speech is bursts with gaps inside every word, so a meter that falls as fast
/// as it rises spends its time flickering between the syllables rather than
/// tracking the voice. Rising fast and falling slowly is the whole difference
/// between something that reads as a level and something that reads as a
/// strobe.
private enum Mode {
    /// The microphone is open and everything on screen is driven by it.
    case recording
    /// The microphone is closed and the transcriber is busy. Still moving, but
    /// nothing it does may be readable as "I can hear you".
    case working
    case idle
}

private struct Envelope {
    private(set) var value: CGFloat = 0
    var attack: CGFloat = 0.45
    var release: CGFloat = 0.08

    mutating func follow(_ target: CGFloat) {
        let k = target > value ? attack : release
        value += (target - value) * k
    }
}

// MARK: - Pulse (the current one)

/// A 10 point dot alternating between full and a third opacity every 0.6 s.
///
/// Kept exactly as it shipped so that a comparison against the other two is a
/// comparison and not a rewrite.
final class PulseMeter: MeterView {
    override class var width: CGFloat { 10 }

    private var bright = true
    private var pulse: Timer?
    private let dot = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        addSubview(dot)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: bounds.midX - 5, y: bounds.midY - 5, width: 10, height: 10)
    }

    override var tint: NSColor {
        didSet { dot.layer?.backgroundColor = tint.cgColor }
    }

    override func begin() {
        pulse?.invalidate()
        // A slow pulse rather than a blink: it has to be noticeable in
        // peripheral vision without being the most distracting thing on screen
        // while someone is trying to speak.
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bright.toggle()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.55
                    self.dot.animator().alphaValue = self.bright ? 1.0 : 0.35
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pulse = t
    }

    /// Goes still, which is what it always did. Kept that way deliberately: it
    /// is here as the thing the other two replaced, and a comparison against a
    /// version that has quietly been improved is not a comparison.
    override func working() { end() }

    override func end() {
        pulse?.invalidate()
        pulse = nil
        dot.alphaValue = 1
    }

    deinit { pulse?.invalidate() }
}

// MARK: - Orb

/// One dot that grows, brightens and blooms with the voice.
///
/// The bloom is a radial gradient rather than a stroked ring on purpose: a ring
/// has an edge, and an edge at this size reads as a second object orbiting the
/// dot instead of as the dot being loud.
final class OrbMeter: MeterView {
    override class var width: CGFloat { 30 }

    private var envelope = Envelope()
    private var target: CGFloat = 0
    private var breath: CGFloat = 0
    private var mode = Mode.idle

    private let minCore: CGFloat = 3.5
    private let maxCore: CGFloat = 8

    override func push(_ level: CGFloat) { target = level }

    override func begin() {
        mode = .recording
        target = 0
        envelope = Envelope()
        startFrames()
    }

    override func working() {
        mode = .working
        // Settle to the resting size rather than carrying on from wherever the
        // last syllable left it, so the working pulse starts from the same
        // place every time instead of inheriting the shape of the final word.
        target = 0
        envelope = Envelope()
    }

    override func end() {
        mode = .idle
        stopFrames()
        target = 0
        envelope = Envelope()
        needsDisplay = true
    }

    override func step() {
        envelope.follow(target)
        breath += 1.0 / 60.0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let base = tint.usingColorSpace(.sRGB) else { return }

        let l: CGFloat
        switch mode {
        case .recording:
            // A slow breath under the level, faded out as soon as there is a
            // voice to follow. Without it a silent room freezes the orb, and a
            // frozen indicator is the one thing this pill exists to never be.
            let idle = (0.5 + 0.5 * sin(breath * 2.6)) * 0.12
            l = min(1, max(envelope.value, idle * (1 - envelope.value)))
        case .working:
            // Deliberately deeper and slower than the recording breath, and it
            // is the whole movement rather than a floor under a live level.
            // Nothing here is driven by audio any more, so it must not be able
            // to be mistaken for something that is.
            l = 0.12 + 0.38 * (0.5 + 0.5 * sin(breath * 4.2))
        case .idle:
            l = 0
        }

        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let core = minCore + (maxCore - minCore) * l
        let bloom = 7 + 8 * l

        let glow = base.withAlphaComponent(0.10 + 0.32 * l)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [glow.cgColor, base.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]) {
            ctx.drawRadialGradient(
                gradient, startCenter: centre, startRadius: core * 0.7,
                endCenter: centre, endRadius: bloom, options: [])
        }

        // Loud reads as hotter, not just bigger. Two channels carrying the same
        // signal is what makes it legible out of the corner of an eye, where
        // a size difference of four points is not.
        let hot = base.blended(withFraction: 0.30 * l, of: .white) ?? base
        ctx.setFillColor(hot.cgColor)
        ctx.fillEllipse(in: CGRect(x: centre.x - core, y: centre.y - core,
                                   width: core * 2, height: core * 2))
    }
}

// MARK: - Waveform

/// A scrolling strip of mirrored bars, newest on the right.
///
/// The one thing the other two cannot do: it keeps a second and a half of
/// history, so a gap is still visible after it has happened. That is what
/// answers "did it catch the start of that sentence", which is the question
/// somebody asks a beat *after* the moment they could have watched a live dot.
final class WaveMeter: MeterView {
    override class var width: CGFloat { 216 }
    override class var spans: Bool { true }

    private let barWidth: CGFloat = 2
    private let gap: CGFloat = 1.5
    /// One column every second frame: 30 a second across 61 columns is two
    /// seconds of history. Slower and the scroll becomes a series of steps
    /// rather than a movement; faster and there is no history left to read.
    private let framesPerColumn = 2

    private var levels: [CGFloat] = []
    private var envelope = Envelope()
    private var target: CGFloat = 0
    private var frameCount = 0
    private var mode = Mode.idle
    private var sweep: CGFloat = 0

    private var columns: Int {
        max(1, Int((bounds.width + gap) / (barWidth + gap)))
    }

    override func push(_ level: CGFloat) { target = level }

    override func begin() {
        mode = .recording
        target = 0
        envelope = Envelope()
        levels = []
        frameCount = 0
        startFrames()
    }

    /// Stops scrolling and starts sweeping.
    ///
    /// The bars are left standing rather than cleared: what was just said is
    /// worth looking at while it is being transcribed, and clearing would blank
    /// the pill at the exact moment somebody glances down to check it heard
    /// them. What travels across them is a highlight, which is the honest shape
    /// for this state: the audio is finished and something is reading it.
    override func working() {
        mode = .working
        sweep = 0
    }

    override func end() {
        mode = .idle
        stopFrames()
        needsDisplay = true
    }

    override func step() {
        switch mode {
        case .recording:
            envelope.follow(target)
            frameCount += 1
            if frameCount % framesPerColumn == 0 {
                levels.append(envelope.value)
                if levels.count > columns { levels.removeFirst(levels.count - columns) }
            }
        case .working:
            // Leads out past 1 so the highlight finishes leaving the right edge
            // before it reappears on the left, rather than cross-fading between
            // the two ends.
            sweep += 1.0 / 60.0 / 1.3
            if sweep > 1.25 { sweep = -0.1 }
        case .idle:
            break
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let base = tint.usingColorSpace(.sRGB) else { return }
        let n = columns
        let pitch = barWidth + gap
        let mid = bounds.midY
        let maxHalf = min(13, bounds.height / 2)
        let floorHalf: CGFloat = barWidth / 2

        for i in 0..<n {
            // Newest on the right, and the strip starts empty on the right too,
            // so a fresh recording grows into it instead of appearing whole.
            let age = n - 1 - i
            let index = levels.count - 1 - age
            let level = index >= 0 ? levels[index] : 0
            let half = floorHalf + (maxHalf - floorHalf) * pow(level, 0.75)

            // The oldest columns fade to nothing rather than to a dim grey, and
            // the strip is flush with the pill's own left edge, so they read as
            // scrolling out under the rounded border instead of stopping dead
            // at a line. Squared, because a linear ramp still leaves a visible
            // front edge where the fade begins.
            //
            // Only the oldest third fades. Taking it across the whole strip
            // would make the left half unreadable, and the left half is the
            // history this style exists for.
            let fade = min(1, CGFloat(i) / max(1, CGFloat(n) * 0.30))

            // While working, a soft band travels left to right and everything
            // outside it drops back. Left to right because that is the order
            // the words were said and the order they are being read in.
            var lit: CGFloat = 1
            if mode == .working {
                let position = CGFloat(i) / max(1, CGFloat(n - 1))
                let d = (position - sweep) / 0.14
                lit = 0.34 + 0.66 * exp(-d * d)
            }
            let colour = base.withAlphaComponent(fade * fade * lit)
            colour.setFill()

            let rect = NSRect(x: CGFloat(i) * pitch, y: mid - half,
                              width: barWidth, height: half * 2)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2,
                         yRadius: barWidth / 2).fill()
        }
    }
}
