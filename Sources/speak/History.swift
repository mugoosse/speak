import Foundation

/// Append-only JSONL log of every dictation.
///
/// JSONL rather than a database so the file stays greppable and survives the
/// app entirely: `jq -r .text history.jsonl` gets you everything ever said.
struct History {
    static let dir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/speak")
    static let file = dir.appendingPathComponent("history.jsonl")

    struct Entry {
        let date: Date
        let duration: Double
        let text: String
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func append(_ e: Entry) {
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)

        let obj: [String: Any] = [
            "at": iso.string(from: e.date),
            // Format via string: (x*100).rounded()/100 still lands on 6.200000000000002.
            "duration_sec": Double(String(format: "%.1f", e.duration)) ?? e.duration,
            "words": e.text.split(separator: " ").count,
            "text": e.text,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }

        var line = data
        line.append(0x0a)

        if let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }

    /// Most recent entries, newest first. Reads the tail only.
    static func recent(_ n: Int) -> [Entry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(n).reversed().compactMap { line in
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = o["text"] as? String,
                  let at = o["at"] as? String else { return nil }
            return Entry(date: iso.date(from: at) ?? Date(timeIntervalSince1970: 0),
                         duration: o["duration_sec"] as? Double ?? 0,
                         text: t)
        }
    }
}
