import AVFoundation
import Speech

/// Transcription via Apple's on-device speech stack (macOS 26+).
///
/// The draw is that there is nothing for us to download: the assets are system
/// managed and usually already present because system dictation uses them. In
/// exchange, accuracy is noticeably below Parakeet on anything technical, and
/// the available locales are whatever macOS has installed.
@available(macOS 26.0, *)
actor AppleEngine {
    private var transcriber: SpeechTranscriber?
    private var locale: Locale = .current

    /// True when this Mac can run it at all.
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Locales with assets already on disk, so no download is needed.
    static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    /// Picks a locale, preferring ones already installed so nothing downloads.
    ///
    /// Order matters more than it looks: simply taking the first entry whose
    /// language matches yields en-ZA for an English speaker, because the list
    /// is not ordered by usefulness.
    private static func bestLocale() async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        let mine = Locale.current
        let myLang = mine.language.languageCode?.identifier
        let myRegion = mine.region?.identifier

        func tag(_ l: Locale) -> String { l.identifier(.bcp47) }

        // 1. Exactly what the user runs.
        if let exact = supported.first(where: { tag($0) == tag(mine) }) { return exact }

        // 2. Same language and region, e.g. nl-BE.
        if let lang = myLang, let region = myRegion,
           let m = supported.first(where: {
               $0.language.languageCode?.identifier == lang
                   && $0.region?.identifier == region
           }) { return m }

        // 3. Same language, favouring an installed variant over a download.
        if let lang = myLang {
            let sameLanguage = supported.filter {
                $0.language.languageCode?.identifier == lang
            }
            if let ready = sameLanguage.first(where: { s in
                installed.contains { tag($0) == tag(s) }
            }) { return ready }
            if let any = sameLanguage.first { return any }
        }

        // 4. English, preferring the common variants over whatever sorts first.
        for preferred in ["en-US", "en-GB"] {
            if let m = supported.first(where: { tag($0) == preferred }) { return m }
        }
        return supported.first { $0.language.languageCode?.identifier == "en" }
            ?? Locale(identifier: "en-US")
    }

    func load() async throws {
        if let saved = Settings.appleLocale,
           let match = await SpeechTranscriber.supportedLocales.first(
               where: { $0.identifier(.bcp47) == saved }) {
            locale = match
        } else {
            locale = await Self.bestLocale()
        }
        let t = SpeechTranscriber(locale: locale, preset: .transcription)

        // Assets are system managed, but a locale that has never been used may
        // still need fetching. This is normally instant or a few seconds, not
        // the multi-gigabyte download Parakeet needs.
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [t]) {
            try await request.downloadAndInstall()
        }

        transcriber = t
    }

    func transcribe(_ pcm: [Float]) async -> String? {
        guard let transcriber else { return nil }

        // Write a temp file rather than hand-rolling an AnalyzerInput stream:
        // the file path is a single call and the clips are seconds long.
        guard let url = writeTempWAV(pcm) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let file = try AVAudioFile(forReading: url)

            // Collect before finalizing: results arrive as an async sequence
            // and stop once the analyzer finishes.
            let collector = Task { () -> String in
                var parts: [String] = []
                for try await result in transcriber.results {
                    parts.append(String(result.text.characters))
                }
                return parts.joined()
            }

            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()

            let text = try await collector.value
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            log("Apple speech failed: \(error)")
            return nil
        }
    }

    private func writeTempWAV(_ pcm: [Float]) -> URL? {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: SAMPLE_RATE,
            channels: 1, interleaved: false)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speak-\(UUID().uuidString).wav")

        guard let file = try? AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count))
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(pcm.count)
        pcm.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: pcm.count)
        }
        try? file.write(from: buffer)
        return url
    }

    var localeName: String {
        locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}
