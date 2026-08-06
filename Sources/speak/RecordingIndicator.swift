import AppKit

/// A small floating pill that says, unambiguously, whether Speak is listening.
///
/// The menu bar icon already changes, but a menu bar item is 16 points wide at
/// the top of a display you may not be looking at, and on a Mac with a notch it
/// can be hidden entirely. Dictation is modal: holding the wrong belief about
/// whether the mic is live is the single most costly mistake a user of this app
/// can make, so the state gets said out loud on screen.
@MainActor
final class RecordingIndicator: NSObject {
    enum State {
        case recording
        case transcribing
        /// `of` is the number of chunks a long dictation was split into, and is
        /// 1 for everything short enough to go in one request.
        case polishing(step: Int, of: Int)

        var text: String {
            switch self {
            case .recording:    return "Listening"
            case .transcribing: return "Transcribing…"
            // Counted only when there is more than one, because "Polishing 1/1"
            // is noise. When there are several the wait is long enough that a
            // number is the difference between working and stuck.
            case .polishing(let step, let total):
                return total > 1 ? "Polishing \(step)/\(total)…" : "Polishing…"
            }
        }
    }

    /// Set only by `--hud-demo`, which shows every style at once. Left nil
    /// everywhere else so the pill follows the setting, and follows it without
    /// anything having to be told: the panel is rebuilt on the first `show`
    /// after the setting changes, so there is no notification to forget to post
    /// and no live reference from Settings to keep alive.
    private let forcedStyle: MeterStyle?
    private var builtStyle: MeterStyle?
    private var style: MeterStyle { forcedStyle ?? Settings.meterStyle }

    private var panel: NSPanel?
    private var meter: MeterView!
    private var label: NSTextField!
    private var timeLabel: NSTextField!
    private var cancelButton: TrashButton!
    private var started = Date()
    private var tick: Timer?

    var onCancel: (() -> Void)?

    /// Points above the bottom of the screen. Only the comparison harness sets
    /// this, so that several pills can be stacked and looked at together.
    var bottomInset: CGFloat = 90

    /// Replaces "Listening" while recording. Only the comparison harness sets
    /// this, to say which style is which.
    var caption: String?

    init(style: MeterStyle? = nil) {
        self.forcedStyle = style
        super.init()
    }

    func show(_ state: State) {
        // Rebuilt rather than restyled: the pill's width, and which of its
        // parts exist at all, depend on the style.
        if builtStyle != style {
            panel?.orderOut(nil)
            panel = makePanel()
            builtStyle = style
        }
        guard let p = panel else { return }

        switch state {
        case .recording:
            started = Date()
            timeLabel.stringValue = "0:00"
            timeLabel.isHidden = false
            cancelButton.isHidden = false
            label.isHidden = type(of: meter!).spans
            label.stringValue = caption ?? state.text
            p.ignoresMouseEvents = false
            meter.tint = .systemRed
            meter.begin()
            startTick()
        // Both are the same colour on purpose. The meter answers one question,
        // "is the microphone live", and the answer is no for both of these.
        // Splitting the colour would imply a distinction that does not matter
        // to anyone glancing at it.
        case .transcribing, .polishing:
            timeLabel.isHidden = true
            cancelButton.isHidden = true
            label.isHidden = false
            label.stringValue = state.text
            p.ignoresMouseEvents = true
            meter.tint = .systemOrange
            meter.working()
            stopTick()
        }

        position(p)
        // orderFrontRegardless, not makeKeyAndOrderFront: taking key would pull
        // focus away from whatever the user is dictating into, and this app's
        // whole job is to leave the frontmost app alone.
        p.orderFrontRegardless()
    }

    /// How loud the microphone is right now. Ignored by styles that do not
    /// listen, so the caller never has to know which one is on screen.
    func level(_ value: Float) {
        meter?.push(CGFloat(value))
    }

    func hide() {
        stopTick()
        meter?.end()
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
    }

    // MARK: - Building

    /// Laid out left to right from the meter, because the meter is the only
    /// part whose width changes with the style: 30 points for an orb and 216
    /// for a waveform. Hardcoded frames would either clip the wide one or leave
    /// a hole beside the narrow one.
    private func makePanel() -> NSPanel {
        let m = style.meter
        let spans = type(of: m).spans
        let meterWidth = type(of: m).width

        let height: CGFloat = 44
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        // Measured rather than guessed. The status text is right-aligned into
        // the same column as the timer and the trash, so a label narrower than
        // its own longest string does not overflow into a margin, it clips, and
        // it clips on a machine slow enough to reach "Polishing 10/12…" rather
        // than on this one.
        let labelWidth = ceil(["Transcribing…", "Polishing 10/12…"]
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 104) + 2
        let timeWidth: CGFloat = 44
        let trashWidth: CGFloat = 26
        let rightPad: CGFloat = 14
        let gap: CGFloat = 10
        // Flush with the pill's own edge when it spans, so the oldest part of
        // the waveform scrolls out under the rounded border rather than
        // stopping at an invisible margin.
        let leftPad: CGFloat = spans ? 0 : 16

        // A spanning style never shows the label and the recording controls at
        // once, so both live in one trailing column sized for whichever is
        // wider, and both start at its left edge. Sharing that edge is the
        // point: it is what the waveform stops against, so the strip ends the
        // same distance from "0:07" while recording as it does from
        // "Polishing 1/2…" afterwards, and nothing has to resize to keep it
        // there. Everything else shows all three side by side.
        let controls = timeWidth + 8 + trashWidth
        let column = max(controls, labelWidth)
        let right = spans ? column : labelWidth + 2 + controls
        let width = leftPad + meterWidth + gap + right + rightPad
        let columnX = width - rightPad - column

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            // .nonactivatingPanel is the load-bearing flag: without it, showing
            // this steals focus and the keystrokes the user is about to type
            // go to the wrong place.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        // Click-through except while recording, when the cancel button is the
        // only control macOS cannot hide behind another app's secure input.
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                .ignoresCycle]

        let bg = NSVisualEffectView(frame: p.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = height / 2
        bg.layer?.masksToBounds = true

        // The trash keeps the trailing edge in both layouts. The timer starts
        // at the shared column edge when the pill spans, and sits beside the
        // trash when it does not.
        let trashX = width - rightPad - trashWidth
        let timeX = spans ? columnX : trashX - 8 - timeWidth

        // The meter never resizes. It was tried the other way, shrinking to make
        // room for "Transcribing…", and the width change on a state the user is
        // already watching reads as a glitch rather than as progress.
        m.frame = NSRect(x: leftPad, y: 4, width: meterWidth, height: height - 8)
        bg.addSubview(m)
        meter = m

        label = NSTextField(labelWithString: "Listening")
        label.font = font
        // Left-aligned in both layouts, and that is the load-bearing half of
        // it: right-aligning inside the trailing column would move the first
        // letter whenever the string's length changed, and the waveform ends
        // against that first letter. "Polishing 1/2…" and "Polishing 10/12…"
        // would then stop the strip in two different places.
        label.alignment = .left
        label.frame = NSRect(
            x: spans ? columnX : leftPad + meterWidth + gap,
            y: 13, width: labelWidth, height: 18)
        bg.addSubview(label)

        timeLabel = NSTextField(labelWithString: "0:00")
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        // Monospaced digits, so a left-aligned timer keeps its first glyph on
        // the column edge as the minutes roll over.
        timeLabel.alignment = spans ? .left : .right
        timeLabel.frame = NSRect(x: timeX, y: 14, width: timeWidth, height: 16)
        bg.addSubview(timeLabel)

        cancelButton = TrashButton(target: self, action: #selector(cancel(_:)))
        cancelButton.frame = NSRect(x: trashX, y: 9, width: trashWidth, height: 26)
        cancelButton.isHidden = true
        bg.addSubview(cancelButton)

        p.contentView = bg
        return p
    }

    @objc private func cancel(_ sender: NSButton) { onCancel?() }

    /// Bottom centre of whichever screen has the mouse, above the Dock. Near
    /// where the eye already is when typing, and out of the way of content.
    private func position(_ p: NSPanel) {
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + bottomInset))
    }

    // MARK: - Timers

    private func startTick() {
        stopTick()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let t = Int(Date().timeIntervalSince(self.started))
                self.timeLabel.stringValue = String(format: "%d:%02d", t / 60, t % 60)
            }
        }
    }

    private func stopTick() {
        tick?.invalidate(); tick = nil
    }
}

/// The pill's cancel control: a trash glyph that brightens to full white under
/// the pointer.
///
/// It replaced the word "Cancel", which cost 58 points the waveform wanted.
/// Losing the word is affordable here in a way it would not be in a menu,
/// because this button is only ever a mouse target: it exists for the case
/// where another app holds secure input and the Escape key never arrives, so
/// the hand is already on the mouse by the time anyone goes looking for it.
///
/// The hover state is not decoration. At rest the glyph is
/// `secondaryLabelColor` so it does not compete with the waveform, and dimmed
/// icons on a HUD read as disabled. Brightening to `labelColor` on hover is
/// what says it is a button at all, and it is the same white as the pill's own
/// text, so the two agree about what "active" looks like.
@MainActor
final class TrashButton: NSButton {
    private var hovering = false { didSet { contentTintColor = tint } }
    private var tint: NSColor { hovering ? .labelColor : .secondaryLabelColor }

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "trash",
                        accessibilityDescription: "Cancel this dictation")?
            .withSymbolConfiguration(
                .init(pointSize: 13, weight: .medium))
        contentTintColor = tint
        toolTip = "Cancel this dictation without changing the clipboard"
        setAccessibilityLabel("Cancel dictation")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        NSCursor.arrow.set()
    }

    /// Hidden while transcribing, and a hidden view gets no exit event. Without
    /// this the glyph comes back bright on the next recording, having been left
    /// mid-hover by a pointer that never moved.
    override var isHidden: Bool {
        didSet { if isHidden { hovering = false } }
    }
}
