import Foundation

/// The user's own vocabulary: words to spell right, and text to replace.
///
/// Named `CustomDictionary` because `Dictionary` is `Swift.Dictionary`, and
/// shadowing that in a codebase full of `[String: Any]` would be a cruelty.
///
/// Two kinds, because they solve the problem at different points and neither
/// covers the other:
///
/// - A **term** is a spelling hint. It reaches the polishing model as part of
///   the prompt, so "if you hear something like this, this is how it is
///   spelled". It cannot be exact, and it does nothing when polishing is off.
/// - A **correction** is a literal replacement applied to every transcript,
///   polished or not. It is exact and needs no model, so it is the only half
///   that works below macOS 26.
///
/// Corrections run *after* polishing (see `Polisher`), so the model cannot
/// undo one.
enum CustomDictionary {
    enum Kind: String, Codable {
        case term
        case correction
    }

    struct Entry: Codable, Equatable {
        var kind: Kind
        /// The term itself, or the text a correction looks for.
        var text: String
        /// Corrections only. Empty for terms.
        var replacement: String
        /// Corrections only. Off means "speak" also matches "Speak".
        var caseSensitive: Bool
        var enabled: Bool

        init(kind: Kind, text: String, replacement: String = "",
             caseSensitive: Bool = false, enabled: Bool = true) {
            self.kind = kind
            self.text = text
            self.replacement = replacement
            self.caseSensitive = caseSensitive
            self.enabled = enabled
        }
    }

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    /// Beside `history.jsonl`, and for the same reason: it is the user's own
    /// data, so it belongs somewhere they can read, edit and back up without
    /// the app's help. JSON rather than JSONL because this one is rewritten as
    /// a whole every time, never appended to.
    static let file = History.dir.appendingPathComponent("dictionary.json")

    private struct Document: Codable {
        var version: Int
        var entries: [Entry]
    }

    /// Read from disk on every call.
    ///
    /// A few kilobytes read once per dictation is nothing, and a cache here
    /// would need invalidating from the Settings pane, from a hand edit of the
    /// file, and from `--polish` running in a different process. Correctness is
    /// cheaper than the saving.
    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: file),
              let doc = try? JSONDecoder().decode(Document.self, from: data)
        else { return [] }
        return doc.entries
    }

    static func save(_ entries: [Entry]) {
        try? FileManager.default.createDirectory(
            at: History.dir, withIntermediateDirectories: true)

        guard let data = encode(entries) else { return }
        // Atomic: a crash mid-write must not leave the user with neither the
        // old list nor the new one.
        try? data.write(to: file, options: .atomic)
    }

    // -----------------------------------------------------------------------
    // Import and export
    // -----------------------------------------------------------------------

    /// Read entries out of a file, accepting more shapes than `save` writes.
    ///
    /// Deliberately liberal. A dictionary is worth years of corrections, and the
    /// reason anyone has one to import is that they built it in another app, so
    /// refusing a file over a key name would defeat the point. Three shapes are
    /// understood:
    ///
    /// - Speak's own `{"version": 1, "entries": [...]}`.
    /// - A bare array of entries, which is what TypeWhisper exports.
    /// - Either of those with either app's key names, per entry.
    ///
    /// TypeWhisper calls the fields `type`, `original` and `isEnabled` where
    /// Speak calls them `kind`, `text` and `enabled`, and its term entries carry
    /// a `ctcMinSimilarity` that Speak has no use for and drops.
    ///
    /// Returns nil only when the file is not JSON in either shape. Entries that
    /// cannot mean anything, having no text to match, are skipped rather than
    /// failing the import.
    static func decode(_ data: Data) -> [Entry]? {
        let json = try? JSONSerialization.jsonObject(with: data)
        let array: [[String: Any]]
        switch json {
        case let list as [[String: Any]]:
            array = list
        case let object as [String: Any]:
            guard let entries = object["entries"] as? [[String: Any]] else { return nil }
            array = entries
        default:
            return nil
        }
        return array.compactMap(entry(from:))
    }

    private static func entry(from json: [String: Any]) -> Entry? {
        let text = (json["text"] ?? json["original"]) as? String ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let rawKind = (json["kind"] ?? json["type"]) as? String ?? ""
        // A replacement is what makes an entry a correction, so an unrecognised
        // or missing kind is decided by whether one is present. Guessing wrong
        // here would silently turn a correction into a hint that does nothing.
        let replacement = json["replacement"] as? String ?? ""
        let kind: Kind = Kind(rawValue: rawKind) ?? (replacement.isEmpty ? .term : .correction)

        return Entry(kind: kind,
                     text: text,
                     replacement: kind == .correction ? replacement : "",
                     caseSensitive: json["caseSensitive"] as? Bool ?? false,
                     enabled: (json["enabled"] ?? json["isEnabled"]) as? Bool ?? true)
    }

    /// Pretty-printed and stably ordered because hand-editing the stored file is
    /// a supported way to use it, and a diff of one changed word should be one
    /// changed line.
    static func encode(_ entries: [Entry]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(Document(version: 1, entries: entries))
    }

    struct MergeResult {
        var added: [Entry]
        /// Entries already present, by kind and text. Reported rather than
        /// duplicated: importing the same file twice should be harmless.
        var duplicates: Int
    }

    /// Add `incoming` to `existing`, skipping ones already there.
    ///
    /// Matching ignores case because the entries are text a person typed, and
    /// two rules differing only in the capitalisation of what they look for
    /// would both fire on the same words.
    static func merge(_ incoming: [Entry], into existing: [Entry]) -> MergeResult {
        var seen = Set(existing.map(key))
        var result = MergeResult(added: [], duplicates: 0)
        for entry in incoming {
            let k = key(entry)
            if seen.contains(k) {
                result.duplicates += 1
            } else {
                seen.insert(k)
                result.added.append(entry)
            }
        }
        return result
    }

    private static func key(_ e: Entry) -> String {
        "\(e.kind.rawValue)\u{0}\(e.text.lowercased())"
    }

    // -----------------------------------------------------------------------
    // Terms
    // -----------------------------------------------------------------------

    /// Enabled terms as one comma-separated line for the prompt, truncated to
    /// `capChars`.
    ///
    /// Capped because the model's context window holds the instructions, the
    /// transcript and the reply together: a long list would crowd out the text
    /// it is meant to help. Entries are taken in order, so the top of the list
    /// is the part that survives a cap, which is what the Settings pane tells
    /// the user.
    static func termHints(_ entries: [Entry]? = nil, capChars: Int = 600) -> String {
        let terms = (entries ?? load())
            .filter { $0.kind == .term && $0.enabled }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var out = ""
        for term in terms {
            let addition = out.isEmpty ? term : ", " + term
            if out.count + addition.count > capChars { break }
            out += addition
        }
        return out
    }

    // -----------------------------------------------------------------------
    // Sounds-like matching
    // -----------------------------------------------------------------------

    /// Terms shorter than this are left alone.
    ///
    /// Short words collide constantly under a phonetic code, and an entry like
    /// "R2" would match half the alphabet-and-digit pairs anyone dictates.
    private static let minimumSoundsLike = 5

    /// Consonant-class code, Soundex style but never truncated.
    ///
    /// Soundex proper stops after three digits, which is far too coarse here:
    /// "flyinpublic" and "flamboyant" both reduce to F451 and would be treated
    /// as the same word. Keeping the whole string separates them (f451142
    /// against f45153) while still ignoring the vowels, which is exactly where
    /// mishearings differ.
    ///
    /// Vowels break a run of equal codes, h and w do not, which is what makes
    /// "Goossens", "Gossens", "Goosens", "Gaussens" and "Gusens" all come out
    /// as g252.
    static func phoneticKey(_ s: String) -> String {
        let letters = s.lowercased().filter(\.isLetter)
        guard let first = letters.first else { return "" }
        var key = String(first)
        var previous = consonantClass(first)
        for c in letters.dropFirst() {
            if let d = consonantClass(c) {
                if d != previous { key.append(d) }
                previous = d
            } else if c != "h", c != "w" {
                previous = nil
            }
        }
        return key
    }

    private static func consonantClass(_ c: Character) -> Character? {
        switch c {
        case "b", "f", "p", "v":                     return "1"
        case "c", "g", "j", "k", "q", "s", "x", "z": return "2"
        case "d", "t":                               return "3"
        case "l":                                    return "4"
        case "m", "n":                               return "5"
        case "r":                                    return "6"
        default:                                     return nil
        }
    }

    /// Every word macOS ships a spelling for.
    ///
    /// The guard that makes this safe: a word already in the language is never
    /// touched, however much it sounds like one of your terms. Without it a
    /// term of "Codex" would rewrite "codes", which is the kind of thing that
    /// would make the whole feature untrustworthy.
    ///
    /// Loaded once, and only when there is an eligible term to check against,
    /// so most users never pay for it. `warm()` moves that cost into the time
    /// the user is still speaking.
    private static let lexicon: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words",
                                     encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    static func warm() { _ = lexicon.isEmpty }

    /// `words` is a 1934 word list with no plurals or verb forms, so "codes"
    /// and "dogs" are missing from it. Stripping common endings covers that
    /// without shipping a second dictionary.
    private static func isRealWord(_ w: String) -> Bool {
        let word = w.lowercased()
        if lexicon.contains(word) { return true }
        for (suffix, stem) in [("s", ""), ("es", ""), ("ed", ""), ("ed", "e"),
                               ("ing", ""), ("ing", "e"), ("d", ""), ("ies", "y"),
                               ("er", ""), ("est", ""), ("ly", "")]
        where word.hasSuffix(suffix) {
            if lexicon.contains(word.dropLast(suffix.count) + stem) { return true }
        }
        return false
    }

    /// Replace misheard words with the term they sound like.
    ///
    /// This is what makes a term worth having. Measured, a term as a prompt hint
    /// repairs a mishearing about one time in five, because it only ever asks
    /// the polishing model nicely. This does not ask anyone: a word that sounds
    /// like one of your terms and is not a word in its own right becomes that
    /// term, with no model involved, so it works with polishing switched off and
    /// on macOS 14.
    ///
    /// Only applied to the raw transcript, before polishing. Mishearings come
    /// from the microphone, not from the model.
    static func applyTerms(to text: String, entries: [Entry]? = nil) -> String {
        let terms = (entries ?? load()).filter {
            $0.kind == .term && $0.enabled
                && !$0.text.contains(" ")
                && $0.text.filter(\.isLetter).count >= minimumSoundsLike
        }
        guard !terms.isEmpty, !lexicon.isEmpty else { return text }

        var byKey: [String: String] = [:]
        for term in terms { byKey[phoneticKey(term.text)] = term.text }

        guard let regex = try? NSRegularExpression(
            pattern: "[\\p{L}\\p{N}][\\p{L}\\p{N}._'-]*") else { return text }

        var out = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let token = String(text[range])
            // Trailing punctuation belongs to the sentence, not the word:
            // "flyinpublic.com." must not be compared with its full stop.
            let trimmed = token.drop(while: { _ in false })
                .reversed().drop(while: { ".'_-".contains($0) }).reversed()
            let word = String(trimmed)
            let tail = String(token.dropFirst(word.count))

            guard let term = byKey[phoneticKey(word)],
                  word.caseInsensitiveCompare(term) != .orderedSame,
                  !isRealWord(word),
                  // A wild length difference means the codes collided rather
                  // than the speaker being misheard.
                  Double(word.count) >= Double(term.count) * 0.6,
                  Double(word.count) <= Double(term.count) * 1.6
            else { continue }

            out += text[cursor..<range.lowerBound] + term + tail
            cursor = range.upperBound
        }
        return out.isEmpty ? text : out + text[cursor...]
    }

    // -----------------------------------------------------------------------
    // Corrections
    // -----------------------------------------------------------------------

    /// Apply every enabled correction to `text`, longest pattern first.
    ///
    /// Longest first because corrections overlap, and the specific one has to
    /// win. A real pair from an imported dictionary: "maxim" to "Maxime" and
    /// "maxim Gusens" to "Maxime Goossens". Run in list order, the short rule
    /// fires first, and by the time the long one is tried the text says "Maxime
    /// Gusens", which it no longer matches. The surname is then unfixable by
    /// any rule the user can add. Sorting by length makes the pair compose, and
    /// it needs no reordering UI or any awareness that ordering exists.
    ///
    /// Equal-length patterns keep the list's order, and each correction still
    /// sees what earlier ones produced.
    ///
    /// Pass `again: true` for the run after polishing. See `applyAround`.
    static func apply(to text: String, entries: [Entry]? = nil,
                      again: Bool = false) -> String {
        let corrections = (entries ?? load())
            .enumerated()
            .filter { $0.element.kind == .correction && $0.element.enabled }
            // Explicit index tiebreak: sorted(by:) is not a stable sort, so
            // without it equal-length rules would shuffle between runs.
            .sorted {
                let (a, b) = ($0.element.text.count, $1.element.text.count)
                return a == b ? $0.offset < $1.offset : a > b
            }

        var out = text
        for entry in corrections.map(\.element) {
            let pattern = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { continue }
            if again && growsItself(entry, pattern: pattern) { continue }
            out = replace(pattern, with: entry.replacement,
                          in: out, caseSensitive: entry.caseSensitive)
        }
        return out
    }

    /// Corrections around a polishing pass: once on the raw transcript, once on
    /// what came back.
    ///
    /// Both runs are needed, and each fixes what the other cannot.
    ///
    /// Before, because polishing rewrites the very words the rules look for.
    /// Measured on a real dictionary: "pagament to the Portagens" was tidied
    /// into "payment to the Portagens" and "maxim Gusens" into "Maxim Gusens",
    /// and in both cases the rule written for the raw transcript then matched
    /// nothing. Correcting first also hands the model the right proper nouns,
    /// which is the difference between it keeping "Hetzner" and inventing a
    /// spelling for a word it does not know.
    ///
    /// After, because the model is free to change anything it was given, so
    /// this is what makes a rule the user wrote the final word.
    static func applyAround(_ text: String,
                            polish: (String) async -> String) async -> String {
        // Loaded once: the file is small, but the two passes must agree, and
        // re-reading between them would let an edit land in the middle.
        let entries = load()
        // Literal corrections first: an explicit rule the user wrote outranks a
        // phonetic guess. Sounds-like runs only here, on the raw transcript,
        // because that is where mishearings come from.
        let corrected = applyTerms(to: apply(to: text, entries: entries), entries: entries)
        return apply(to: await polish(corrected), entries: entries, again: true)
    }

    /// Whether applying a correction to its own replacement changes it again.
    ///
    /// Such a rule cannot run twice. "Speak" to "Speak app" would produce
    /// "Speak app app" on the second pass, because the replacement still
    /// contains what the rule matches. These are skipped after polishing, where
    /// the first pass has already done the work.
    private static func growsItself(_ e: Entry, pattern: String) -> Bool {
        replace(pattern, with: e.replacement, in: e.replacement,
                caseSensitive: e.caseSensitive) != e.replacement
    }

    /// Whole-word replacement when the pattern's edge is a word character,
    /// plain substring replacement otherwise.
    ///
    /// The distinction matters at both ends independently. `\b` marks a
    /// transition between a word character and a non-word one, so anchoring
    /// "C++" with a trailing `\b` would stop it ever matching: the character
    /// after "+" is not a word character either, so there is no transition to
    /// find. Anchoring only the ends that are word characters gets "cat"
    /// leaving "category" alone while "C++" still matches.
    private static func replace(_ pattern: String, with replacement: String,
                                in text: String, caseSensitive: Bool) -> String {
        var expression = NSRegularExpression.escapedPattern(for: pattern)
        if pattern.first?.isWordLike == true { expression = "\\b" + expression }
        if pattern.last?.isWordLike == true { expression += "\\b" }

        guard let regex = try? NSRegularExpression(
            pattern: expression, options: caseSensitive ? [] : [.caseInsensitive])
        else { return text }

        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            // Escaped: an unescaped "$1" in someone's replacement would expand
            // to a capture group rather than the two characters they typed.
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}

private extension Character {
    /// Matches what `\b` in ICU regex considers a word character, so the
    /// anchoring decision above and the regex engine agree.
    var isWordLike: Bool { isLetter || isNumber || self == "_" }
}
