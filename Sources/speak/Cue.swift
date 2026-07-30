import AppKit

/// Audible feedback, using system sounds rather than bundled audio files.
///
/// A push-to-talk app is used while looking at something else, so sound is
/// often the only feedback that arrives. System sounds are used deliberately:
/// they already match the user's volume and alert settings, they are familiar,
/// and shipping custom audio would mean choosing something that eventually
/// grates on someone who hears it forty times a day.
enum Cue {
    /// Shown in the Settings pickers. Read from disk rather than hardcoded, so
    /// a macOS release that adds or removes one does not leave a picker
    /// offering something that will not play.
    static var available: [String] {
        let dir = "/System/Library/Sounds"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.hasSuffix(".aiff") }
            .map { String($0.dropLast(5)) }
            .sorted() ?? []
        return names
    }

    /// Chosen because it is short and unobtrusive: this one fires every time
    /// you begin speaking, so anything with character becomes irritating fast.
    static let defaultStart = "Tink"

    /// Blow rather than Glass: this one lands while you are reading back what
    /// you said, and Glass is close enough to the system alert sound to read
    /// as something going wrong.
    static let defaultDone = "Blow"

    /// The microphone is live. Fired from the first audio buffer, never from
    /// the keypress, so it cannot lie about whether recording began.
    static func start() { play(Settings.startSound) }

    /// A transcript reached the clipboard.
    static func done() { play(Settings.doneSound) }

    /// The recording was abandoned deliberately. Distinct from `done`, or
    /// cancelling sounds like success.
    static func cancel() { play("Bottle") }

    /// Nothing was heard, or transcription failed.
    static func failed() { play("Basso") }

    /// Ignores the master toggle, for previewing a choice in Settings: you are
    /// asking to hear it, so hearing nothing would be a broken control.
    static func preview(_ name: String) {
        guard name != none else { return }
        NSSound(named: name)?.play()
    }

    /// Sentinel for "no sound for this event", kept separate from the master
    /// toggle so one cue can be silenced without losing the others.
    static let none = "None"

    private static func play(_ name: String) {
        guard Settings.sounds, name != none else { return }
        NSSound(named: name)?.play()
    }
}
