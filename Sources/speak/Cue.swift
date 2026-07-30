import AppKit

/// Audible feedback, using system sounds rather than bundled audio files.
///
/// A push-to-talk app is used while looking at something else, so sound is
/// often the only feedback that arrives. System sounds are used deliberately:
/// they already match the user's volume and alert settings, they are familiar,
/// and shipping custom audio would mean choosing something that eventually
/// grates on someone who hears it forty times a day.
enum Cue {
    /// The microphone is live. Fired from the first audio buffer, never from
    /// the keypress, so it cannot lie about whether recording began.
    static func start() { play("Tink") }

    /// A transcript reached the clipboard.
    static func done() { play("Pop") }

    /// The recording was abandoned deliberately. Deliberately distinct from
    /// `done`, or cancelling sounds like success.
    static func cancel() { play("Bottle") }

    /// Nothing was heard, or transcription failed.
    static func failed() { play("Basso") }

    private static func play(_ name: String) {
        guard Settings.sounds else { return }
        NSSound(named: name)?.play()
    }
}
