import AppKit
import MLX
import MLXAudioSTT

/// Fronts whichever speech engine is selected.
///
/// The two are not interchangeable underneath: Parakeet is weights we download
/// and run through MLX, Apple's is a system service. Keeping the choice here
/// means the rest of the app only ever calls `transcribe(_:)`.
actor Transcriber {
    private var parakeet: (any STTGenerationModel)?
    private var apple: AnyObject?          // AppleEngine, gated on macOS 26
    private var kind: ModelChoice.Kind = .parakeet

    func load(_ choice: ModelChoice) async throws {
        parakeet = nil                     // drop the old weights before loading
        apple = nil
        kind = choice.kind

        switch choice.kind {
        case .parakeet:
            parakeet = try await STT.loadModel(modelRepo: choice.repo)
            // Warm the compute graph so the first real dictation isn't slow.
            if let m = parakeet {
                let silence = MLXArray(Array(repeating: Float(0), count: Int(SAMPLE_RATE)))
                _ = m.generate(audio: silence, generationParameters: params())
            }

        case .apple:
            guard #available(macOS 26.0, *) else {
                throw NSError(domain: "Speak", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Apple speech needs macOS 26 or later",
                ])
            }
            let engine = AppleEngine()
            try await engine.load()
            apple = engine
        }
    }

    private func params() -> STTGenerateParameters {
        // Utterances are short, so a single chunk is the common case; the
        // 120 s ceiling only matters for a long unbroken dictation.
        STTGenerateParameters(chunkDuration: 120)
    }

    func transcribe(_ pcm: [Float]) async -> String? {
        // Pad very short clips with silence. Parakeet degrades badly on inputs
        // shorter than about a second, and a one-word dictation is easily that
        // short. TypeWhisper does the same thing for the same reason.
        var samples = pcm
        let minimum = Int(SAMPLE_RATE)
        if samples.count < minimum {
            samples.append(contentsOf: repeatElement(0, count: minimum - samples.count))
        }

        switch kind {
        case .parakeet:
            guard let m = parakeet else { return nil }
            let out = m.generate(audio: MLXArray(samples), generationParameters: params())
            let text = out.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return text.isEmpty ? nil : text

        case .apple:
            guard #available(macOS 26.0, *), let engine = apple as? AppleEngine
            else { return nil }
            return await engine.transcribe(samples)
        }
    }
}
