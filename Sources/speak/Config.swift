import AppKit
import Carbon.HIToolbox

let SAMPLE_RATE = 16000.0

/// Diagnostics on stderr. `SPEAK_DEBUG=1` additionally traces every modifier
/// change, which is how you find out what your keyboard actually reports.
let DEBUG = ProcessInfo.processInfo.environment["SPEAK_DEBUG"] == "1"

func log(_ s: String) {
    FileHandle.standardError.write("[Speak] \(s)\n".data(using: .utf8)!)
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// v2 is the default because it is English-only and therefore *cannot* emit
/// Cyrillic. v3 is multilingual across 25 European languages, but on a short
/// utterance with little context it will decode English speech as Russian, and
/// mlx-audio offers no way to pin it: the `language` parameter is copied into
/// the output struct and never reaches the decoder. Pick v3 only if you
/// actually dictate in another language, and expect the occasional wrong one.
struct ModelChoice {
    enum Kind {
        /// Downloaded weights run through MLX.
        case parakeet
        /// Apple's built-in on-device speech, nothing for us to download.
        case apple
    }

    let id: String
    let title: String
    /// What the engine is good and bad at, without its size.
    let blurb: String
    /// Empty for the Apple engine.
    let repo: String
    var kind: Kind = .parakeet
    /// Named in full, and empty unless the coverage is a real question.
    ///
    /// v2 is English and Apple's list is the system's, which the Language
    /// picker already shows. v3's "25 languages" is a claim nobody can check
    /// from the outside, and choosing between a 2.4 GB English model and a
    /// 2.4 GB multilingual one is a decision about whether *your* language is
    /// in that 25, which the number alone does not answer.
    var languages: [String] = []
    /// Measured on disk. Used only to turn a byte count into a percentage
    /// while downloading, so being a few MB out is harmless.
    let approxBytes: Int64

    /// The blurb with the download size on the end, or without one for an
    /// engine that has nothing to fetch.
    ///
    /// Formatted from `approxBytes` rather than written out, because the two
    /// were written out and disagreed: the list said "2.4 GB download" while
    /// the line asking permission for it said 2.51 GB, on the same screen. One
    /// of those was a measurement and the other was a memory of one.
    var detail: String {
        guard kind != .apple else { return blurb }
        return blurb + " · \(Self.humanBytes(approxBytes)) download"
    }

    /// Titles name the model, blurbs describe what it can do. Mixing the two
    /// (a "Multilingual" option next to an "Apple Intelligence" one) makes the
    /// list read as though it is comparing different kinds of thing.
    static let all: [ModelChoice] = {
        var list: [ModelChoice] = [
            .init(id: "v2", title: "Parakeet v2",
                  blurb: "English only · most accurate",
                  repo: "mlx-community/parakeet-tdt-0.6b-v2",
                  approxBytes: 2_471_601_146),
            .init(id: "v3", title: "Parakeet v3",
                  blurb: "25 languages · may misdetect short clips",
                  repo: "mlx-community/parakeet-tdt-0.6b-v3",
                  // The model card's 25, alphabetically rather than in its
                  // own order: this list is read to answer "is mine here?",
                  // and that question is answered by scanning, not by
                  // reading. Note Irish is absent, so it is not simply the
                  // EU's official languages.
                  languages: [
                    "Bulgarian", "Croatian", "Czech", "Danish", "Dutch",
                    "English", "Estonian", "Finnish", "French", "German",
                    "Greek", "Hungarian", "Italian", "Latvian", "Lithuanian",
                    "Maltese", "Polish", "Portuguese", "Romanian", "Russian",
                    "Slovak", "Slovenian", "Spanish", "Swedish", "Ukrainian",
                  ],
                  approxBytes: 2_508_579_601),
        ]
        if #available(macOS 26.0, *) {
            list.append(.init(
                id: "apple", title: "Apple Intelligence",
                blurb: "Built in · no download · ready immediately · less accurate",
                repo: "", kind: .apple, approxBytes: 0))
        }
        return list
    }()

    static let fallback = all[0]

    static var appleAvailable: Bool { all.contains { $0.kind == .apple } }

    static func named(_ id: String) -> ModelChoice? { all.first { $0.id == id } }

    static func named(repo: String) -> ModelChoice? { all.first { $0.repo == repo } }

    /// Where the Hugging Face client keeps its cache, resolved the way the
    /// client resolves it.
    ///
    /// Not simply `~/.cache/huggingface/hub`. swift-huggingface checks
    /// `HF_HUB_CACHE`, then `HF_HOME`, then the standard location, and anyone
    /// who runs other local ML tooling is liable to have set one of those.
    /// Speak looked only in the standard place, so with `HF_HOME` pointing
    /// elsewhere it found an earlier copy of the weights, said "already
    /// downloaded", and then sat on "loading model…" for four minutes while
    /// the library quietly fetched 2.4 GB into the other cache: no progress
    /// bar, because as far as Speak knew nothing was being downloaded. The
    /// disk-space figures in Settings were measuring the wrong directory for
    /// the same reason.
    ///
    /// Every rule here is the library's, including the sandbox branch that
    /// Speak does not currently take. Agreement is the whole point; a "more
    /// sensible" rule on this side is how the two came apart in the first
    /// place.
    static var hubRoot: URL {
        let env = ProcessInfo.processInfo.environment
        if let cache = env["HF_HUB_CACHE"] {
            return URL(fileURLWithPath: NSString(string: cache).expandingTildeInPath)
        }
        if let home = env["HF_HOME"] {
            return URL(fileURLWithPath: NSString(string: home).expandingTildeInPath)
                .appendingPathComponent("hub")
        }
        if env["APP_SANDBOX_CONTAINER_ID"] != nil {
            return URL.cachesDirectory
                .appendingPathComponent("huggingface")
                .appendingPathComponent("hub")
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/huggingface/hub")
    }

    /// The cache root as a person would write it, for UI that names it.
    static var hubRootDisplay: String {
        let path = hubRoot.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Where mlx-audio keeps its own copy, and what it checks before deciding
    /// to fetch anything.
    var cacheDirectory: URL {
        Self.hubRoot
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(repo.replacingOccurrences(of: "/", with: "_"))
    }

    /// Where the bytes actually land while downloading.
    ///
    /// The Hugging Face client streams into `blobs/<etag>.incomplete` and only
    /// moves files into place at the end, so watching `cacheDirectory` shows a
    /// flat 0% for the whole download and then a jump to done.
    var downloadDirectory: URL {
        let parts = repo.split(separator: "/")
        return Self.hubRoot.appendingPathComponent("models--" + parts.joined(separator: "--"))
    }

    private func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Progress is whichever location has more: the hub cache while fetching,
    /// mlx-audio's copy once it has been unpacked there, plus whatever is
    /// still in flight.
    var bytesOnDisk: Int64 {
        max(size(of: downloadDirectory), size(of: cacheDirectory))
            + Self.inFlightBytes()
    }

    /// Bytes of any download still streaming into the temp directory.
    ///
    /// This is the only place a transfer is observable. `URLSession` writes to
    /// `CFNetworkDownload_XXXXXX.tmp` and moves the finished file into the
    /// cache at the end, so the destination stays flat at a megabyte of JSON
    /// for the entire download and then jumps to 2.3 GB. Measured directly:
    /// the temp file went 969 MB, 1001 MB, 1076 MB over six seconds while the
    /// hub directory did not move at all.
    ///
    /// The library does expose a `Progress`, and it is sampled every 100 ms,
    /// but the large file's bytes never reach it on this transport, so it
    /// reports only the small files and sits at 0% throughout.
    static func inFlightBytes() -> Int64 {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return 0 }

        // The most recently written file, not the largest.
        //
        // Cancelling a download leaves its temp file behind at whatever size it
        // reached, and picking the largest recent one latched onto exactly
        // that: switching to Apple Intelligence at 58% and back again pinned
        // the display to 1.42 GB while the real transfer climbed from zero
        // underneath it, invisible until it passed the abandoned file. The
        // active download is the one being written, so mtime identifies it and
        // size does not.
        let cutoff = Date().addingTimeInterval(-10)
        var newest: Date = cutoff
        var bytes: Int64 = 0
        for url in entries where url.lastPathComponent.hasPrefix("CFNetworkDownload") {
            guard let v = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let modified = v.contentModificationDate, modified > newest
            else { continue }
            newest = modified
            bytes = Int64(v.fileSize ?? 0)
        }
        return bytes
    }

    /// Complete enough to skip the download message. The margin covers small
    /// differences in what the library actually fetches.
    ///
    /// Note this needs mlx-audio's own copy: a populated hub cache still costs
    /// a local copy step, but that is seconds rather than minutes.
    var isDownloaded: Bool {
        if kind == .apple { return true }        // nothing of ours to fetch
        return size(of: cacheDirectory) > Int64(Double(approxBytes) * 0.97)
    }

    /// What removing this model would give back.
    ///
    /// A sum, where `bytesOnDisk` takes a maximum. That one follows a single
    /// download through two locations, so the larger reading is the truthful
    /// one. This one answers "how much do I get back", and the answer is both,
    /// because the weights really are stored twice. See README, Disk use.
    var bytesUsed: Int64 {
        guard kind != .apple else { return 0 }   // system assets, not ours
        return size(of: downloadDirectory) + size(of: cacheDirectory)
    }

    /// Delete both copies, returning what was freed.
    ///
    /// Both or neither. Leaving the hub blob cache behind makes the next
    /// selection look like a suspiciously fast download that is really a local
    /// copy, and leaving mlx-audio's copy behind does not reclaim the space
    /// the user asked for.
    @discardableResult
    func removeFromDisk() -> Int64 {
        guard kind != .apple else { return 0 }
        let freed = bytesUsed
        for dir in [downloadDirectory, cacheDirectory] {
            try? FileManager.default.removeItem(at: dir)
        }
        return freed
    }

    /// "2.3 GB", written the way the rest of macOS writes it.
    static func humanBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

/// What the model is doing, so the UI can say something specific instead of
/// leaving the user watching a static icon for ten minutes.
enum ModelStatus {
    /// `fraction` is nil until the first progress callback arrives, and stays
    /// nil for the whole download if the library gives us nothing usable.
    ///
    /// This used to carry only elapsed time, because `STT.loadModel` performs
    /// its own download and forwards no progress: `URLSession.download`
    /// streams into a system temp path and moves the file into the cache only
    /// once complete, so watching the cache directory gives 0% for ten minutes
    /// and then 100%. Speak now runs the download itself through
    /// `ModelUtils.resolveOrDownloadModel`, which does take a progress
    /// handler, and hands the populated cache to `loadModel` afterwards.
    /// Elapsed time is kept as a fallback and as reassurance that something is
    /// still happening.
    /// Nothing has been asked for yet.
    ///
    /// Reachable on a first run, and for as long as setup's model step is
    /// showing an engine whose weights are not on disk. Nothing downloads
    /// until the user presses the button that says so: the default is only a
    /// default, and starting a 2.4 GB fetch of it would spend somebody's
    /// bandwidth on an engine they had not chosen and might not want.
    case idle
    case downloading(elapsed: TimeInterval, total: Int64,
                     received: Int64?, fraction: Double?)
    case loading
    case ready
    case failed(String)

    var isReady: Bool { if case .ready = self { return true }; return false }

    /// True while the engine cannot yet transcribe. Onboarding uses this to
    /// refuse to advance, so nobody reaches "you're set" with no model.
    var isBusy: Bool {
        switch self {
        case .downloading, .loading:  return true
        case .idle, .ready, .failed:  return false
        }
    }

    var summary: String {
        switch self {
        case .downloading(_, let total, let received, let fraction):
            let f = ByteCountFormatter()
            f.countStyle = .file
            f.allowsNonnumericFormatting = false
            guard let fraction, let received else {
                // The first second, before a measurement exists. Say what is
                // coming and nothing else: a percentage would be a guess, and
                // "0s so far" is a stopwatch reporting that no time has
                // passed, which nobody needed telling.
                return "downloading model… \(f.string(fromByteCount: total))"
            }
            // No elapsed time. It was worth showing when there was nothing
            // else to show, as the only evidence anything was still happening.
            // A moving percentage says that better, and a stopwatch next to a
            // progress bar just invites the reader to do arithmetic.
            let pct = Int((fraction * 100).rounded())
            return "downloading model… \(pct)% · "
                 + "\(f.string(fromByteCount: received)) of "
                 + "\(f.string(fromByteCount: total))"
        case .idle:     return "waiting to set up"
        case .loading:  return "loading model…"
        case .ready:    return "ready"
        case .failed(let why): return why
        }
    }

    /// 0...1 for a determinate progress bar, nil when indeterminate.
    var fraction: Double? {
        if case .downloading(_, _, _, let f) = self { return f }
        return nil
    }


    /// Turns library errors into something a person can act on.
    static func describe(_ error: Error) -> String {
        let raw = "\(error)"
        if raw.contains("offline") || raw.contains("network")
            || raw.contains("NSURLError") || raw.contains("Internet") {
            return "no internet connection, cannot download the model"
        }
        if raw.contains("401") || raw.contains("404") || raw.contains("Not Found") {
            return "model not found on Hugging Face"
        }
        if raw.contains("No space") || raw.contains("ENOSPC") {
            return "not enough disk space for the model"
        }
        return "could not load the model"
    }
}

// ---------------------------------------------------------------------------
// Preferences
// ---------------------------------------------------------------------------

enum Settings {
    private static let modelKey = "modelID"
    private static let onboardedKey = "onboarded"
    private static let autoPasteKey = "autoPaste"
    private static let startAtLoginDefaultAppliedKey = "startAtLoginDefaultApplied"
    private static let soundsKey = "sounds"
    private static let indicatorKey = "showIndicator"
    private static let meterKey = "meterStyle"
    private static let onboardingStepKey = "onboardingStep"
    private static let startSoundKey = "startSound"
    private static let doneSoundKey = "doneSound"

    /// Audible cues on start and finish. On by default: the whole point of a
    /// push-to-talk app is that you are looking at something else, and a sound
    /// is the only feedback that needs no glance.
    static var sounds: Bool {
        get { UserDefaults.standard.object(forKey: soundsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: soundsKey) }
    }

    static var showIndicator: Bool {
        get { UserDefaults.standard.object(forKey: indicatorKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: indicatorKey) }
    }

    /// What the recording pill animates. Taste, not correctness: both offered
    /// styles are driven by the microphone and both answer "is it hearing me".
    /// One is quieter and narrower than the other, and which of those matters
    /// depends on where somebody keeps their windows.
    static var meterStyle: MeterStyle {
        get {
            MeterStyle(rawValue: UserDefaults.standard.string(forKey: meterKey) ?? "")
                ?? .waveform
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: meterKey) }
    }

    /// Which system sound each cue uses. Taste in notification sounds is
    /// personal and these fire dozens of times a day, so they are a setting
    /// rather than a decision made on the user's behalf.
    static var startSound: String {
        get { UserDefaults.standard.string(forKey: startSoundKey) ?? Cue.defaultStart }
        set { UserDefaults.standard.set(newValue, forKey: startSoundKey) }
    }

    static var doneSound: String {
        get { UserDefaults.standard.string(forKey: doneSoundKey) ?? Cue.defaultDone }
        set { UserDefaults.standard.set(newValue, forKey: doneSoundKey) }
    }

    /// Where onboarding got to, so quitting part way through a 2.4 GB download
    /// does not start the whole flow again.
    static var onboardingStep: Int {
        get { UserDefaults.standard.integer(forKey: onboardingStepKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardingStepKey) }
    }

    /// SPEAK_MODEL still wins, so a one-off override works without disturbing
    /// the saved preference.
    static var envOverride: String? {
        ProcessInfo.processInfo.environment["SPEAK_MODEL"]
    }

    static var choice: ModelChoice {
        get {
            guard let id = UserDefaults.standard.string(forKey: modelKey),
                  let c = ModelChoice.named(id) else { return .fallback }
            return c
        }
        set { UserDefaults.standard.set(newValue.id, forKey: modelKey) }
    }

    /// True once an engine has actually been chosen, rather than Speak having
    /// fallen back to one.
    ///
    /// Setup will not continue past the model step until this is true, and the
    /// distinction matters: `choice` cannot express "nobody has said", so
    /// without this the radio button on the default reads as a decision the
    /// user made, and the 2.4 GB it implies as one they agreed to.
    ///
    /// Derived rather than stored. The presence of the key is the record of an
    /// explicit pick, since only the two model pickers ever write it, and
    /// having finished setup is the same evidence for anyone who came through
    /// the old flow, where the default was downloaded without being offered.
    static var modelChosen: Bool {
        UserDefaults.standard.string(forKey: modelKey) != nil || onboarded
    }

    static var activeRepo: String { envOverride ?? choice.repo }

    static var onboarded: Bool {
        get { UserDefaults.standard.bool(forKey: onboardedKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardedKey) }
    }

    static var autoPaste: Bool {
        get {
            if ProcessInfo.processInfo.environment["SPEAK_AUTOPASTE"] == "1" { return true }
            return UserDefaults.standard.object(forKey: autoPasteKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: autoPasteKey) }
    }

    /// Tracks the one-time default separately from the system registration.
    /// Once this is set, Speak never changes the login item unless the user
    /// changes it in Settings.
    static var startAtLoginDefaultApplied: Bool {
        get { UserDefaults.standard.bool(forKey: startAtLoginDefaultAppliedKey) }
        set { UserDefaults.standard.set(newValue, forKey: startAtLoginDefaultAppliedKey) }
    }

    /// BCP-47 tag for the Apple engine, or nil to choose automatically.
    ///
    /// Only meaningful for Apple Intelligence: `SpeechTranscriber` takes a
    /// locale that genuinely constrains recognition. Parakeet has no such
    /// control, so this is deliberately not offered for it.
    static var appleLocale: String? {
        get {
            let v = UserDefaults.standard.string(forKey: appleLocaleKey)
            return (v?.isEmpty ?? true) ? nil : v
        }
        set { UserDefaults.standard.set(newValue ?? "", forKey: appleLocaleKey) }
    }

    private static let appleLocaleKey = "appleLocale"
}

// ---------------------------------------------------------------------------
// Shortcut
// ---------------------------------------------------------------------------

/// One modifier key, identified by its device-dependent flag bit.
///
/// These IOKit-level bits are what distinguish left from right;
/// `NSEvent.modifierFlags` collapses both into a single `.shift`.
struct Modifier {
    let bit: UInt64
    let name: String

    static let all: [Modifier] = [
        .init(bit: 0x0080_0000, name: "fn"),        // maskSecondaryFn
        .init(bit: 0x0000_0002, name: "⇧ left"),
        .init(bit: 0x0000_0004, name: "⇧ right"),
        .init(bit: 0x0000_0001, name: "⌃ left"),
        .init(bit: 0x0000_2000, name: "⌃ right"),
        .init(bit: 0x0000_0020, name: "⌥ left"),
        .init(bit: 0x0000_0040, name: "⌥ right"),
        .init(bit: 0x0000_0008, name: "⌘ left"),
        .init(bit: 0x0000_0010, name: "⌘ right"),
    ]

    /// Every bit we track, so caps lock and friends are ignored.
    static let tracked: UInt64 = all.reduce(0) { $0 | $1.bit }

    static func describe(_ mask: UInt64) -> String {
        let parts = all.filter { mask & $0.bit != 0 }.map(\.name)
        return parts.isEmpty ? "none" : parts.joined(separator: " + ")
    }
}

/// Resolves a virtual key code to what that key actually prints.
///
/// Table-free, because a hardcoded map assumes US QWERTY: on AZERTY the key at
/// code 12 is "a", not "q". This asks the active keyboard layout instead.
enum KeyName {
    static func of(_ keyCode: Int) -> String {
        if let special = special[keyCode] { return special }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?
                .takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(
                source, kTISPropertyUnicodeKeyLayoutData)
        else { return "key \(keyCode)" }

        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)

        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?
                    .assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys, chars.count, &length, &chars)
        }

        guard status == noErr, length > 0 else { return "key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    /// Keys that print nothing, so the layout cannot name them.
    private static let special: [Int: String] = [
        49: "space", 36: "return", 48: "tab", 53: "esc", 51: "delete",
        117: "fwd delete", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "home", 119: "end", 116: "page up", 121: "page down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

/// The chord that toggles dictation.
///
/// Either a pure modifier chord (fn + ⇧) or modifiers plus one ordinary key
/// (fn + ⇧ + P). The two are matched differently: a modifier chord has no
/// keyDown to hook, so it is reconstructed from flag changes, while a chord
/// with a real key is matched on keyDown and swallowed so the character is not
/// also typed into whatever you are working in.
enum Shortcut {
    private static let maskKey = "shortcutMask"
    private static let codeKey = "shortcutKeyCode"

    /// Modifiers only; the key itself is extra.
    static let maxKeys = 3

    /// fn + left shift
    static let defaultMask: UInt64 = 0x0080_0000 | 0x0000_0002

    static var mask: UInt64 {
        get {
            let v = UInt64(UserDefaults.standard.integer(forKey: maskKey)) & Modifier.tracked
            return isUsable(v, keyCode) ? v : defaultMask
        }
        set { UserDefaults.standard.set(Int(newValue & Modifier.tracked), forKey: maskKey) }
    }

    /// nil means a pure modifier chord.
    static var keyCode: Int? {
        get {
            let v = UserDefaults.standard.integer(forKey: codeKey)
            return v > 0 ? v - 1 : nil          // 0 is "unset", so store code+1
        }
        set { UserDefaults.standard.set(newValue.map { $0 + 1 } ?? 0, forKey: codeKey) }
    }

    static func set(mask: UInt64, keyCode: Int?) {
        self.keyCode = keyCode
        self.mask = mask
    }

    static func isUsable(_ mask: UInt64, _ keyCode: Int?) -> Bool {
        let mods = mask.nonzeroBitCount
        // With a character key, one modifier is plenty and zero is not: a bare
        // letter would fire on every word containing it.
        if keyCode != nil { return (1...maxKeys).contains(mods) }
        return (1...maxKeys).contains(mods)
    }

    /// A lone modifier toggles every time you reach for it, including mid-word.
    /// Allowed, since some keyboards have a spare key worth dedicating, but
    /// worth saying out loud in the UI.
    static func isRisky(_ mask: UInt64, _ keyCode: Int?) -> Bool {
        keyCode == nil && mask.nonzeroBitCount == 1
    }

    static var description: String {
        let mods = Modifier.describe(mask)
        guard let c = keyCode else { return mods }
        return "\(mods) + \(KeyName.of(c))"
    }

    static var usesCharacterKey: Bool { keyCode != nil }

    /// Exact match, so fn+shift does not also fire on fn+shift+cmd.
    static func modifiersMatch(_ flags: CGEventFlags) -> Bool {
        (flags.rawValue & Modifier.tracked) == mask
    }
}
