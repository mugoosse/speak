import AppKit

/// A small floating pill that says, unambiguously, whether Speak is listening.
///
/// The menu bar icon already changes, but a menu bar item is 16 points wide at
/// the top of a display you may not be looking at, and on a Mac with a notch it
/// can be hidden entirely. Dictation is modal: holding the wrong belief about
/// whether the mic is live is the single most costly mistake a user of this app
/// can make, so the state gets said out loud on screen.
@MainActor
final class RecordingIndicator {
    enum State {
        case recording
        case transcribing

        var text: String {
            switch self {
            case .recording:    return "Listening"
            case .transcribing: return "Transcribing…"
            }
        }
    }

    private var panel: NSPanel?
    private var dot: NSView?
    private var label: NSTextField!
    private var timeLabel: NSTextField!
    private var started = Date()
    private var tick: Timer?
    private var pulse: Timer?
    private var bright = true

    func show(_ state: State) {
        let p = panel ?? makePanel()
        panel = p

        label.stringValue = state.text
        switch state {
        case .recording:
            started = Date()
            timeLabel.stringValue = "0:00"
            timeLabel.isHidden = false
            dot?.layer?.backgroundColor = NSColor.systemRed.cgColor
            startTimers()
        case .transcribing:
            timeLabel.isHidden = true
            dot?.layer?.backgroundColor = NSColor.systemOrange.cgColor
            stopTimers()
        }

        position(p)
        // orderFrontRegardless, not makeKeyAndOrderFront: taking key would pull
        // focus away from whatever the user is dictating into, and this app's
        // whole job is to leave the frontmost app alone.
        p.orderFrontRegardless()
    }

    func hide() {
        stopTimers()
        panel?.orderOut(nil)
    }

    // MARK: - Building

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 190, height: 44),
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
        p.ignoresMouseEvents = true          // never in the way of a click
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                .ignoresCycle]

        let bg = NSVisualEffectView(frame: p.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 22
        bg.layer?.masksToBounds = true

        let d = NSView(frame: NSRect(x: 18, y: 17, width: 10, height: 10))
        d.wantsLayer = true
        d.layer?.cornerRadius = 5
        d.layer?.backgroundColor = NSColor.systemRed.cgColor
        bg.addSubview(d)
        dot = d

        label = NSTextField(labelWithString: "Listening")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 38, y: 13, width: 100, height: 18)
        bg.addSubview(label)

        timeLabel = NSTextField(labelWithString: "0:00")
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        timeLabel.frame = NSRect(x: 120, y: 14, width: 52, height: 16)
        bg.addSubview(timeLabel)

        p.contentView = bg
        return p
    }

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
            y: frame.minY + 90))
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let t = Int(Date().timeIntervalSince(self.started))
                self.timeLabel.stringValue = String(format: "%d:%02d", t / 60, t % 60)
            }
        }
        // A slow pulse rather than a blink: it has to be noticeable in
        // peripheral vision without being the most distracting thing on screen
        // while someone is trying to speak.
        pulse = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, let dot = self.dot else { return }
                self.bright.toggle()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.55
                    dot.animator().alphaValue = self.bright ? 1.0 : 0.35
                }
            }
        }
    }

    private func stopTimers() {
        tick?.invalidate(); tick = nil
        pulse?.invalidate(); pulse = nil
        dot?.alphaValue = 1
    }
}
