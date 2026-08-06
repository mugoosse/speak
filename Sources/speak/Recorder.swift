import AppKit
import AVFoundation

// Audio capture: mic -> 16 kHz mono Float32, which is what Parakeet expects.

final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    /// Fired once per recording, when the first converted samples arrive.
    ///
    /// The start cue hangs off this rather than off `start()`, so it means
    /// "the microphone is live" instead of "a key was pressed". Those are not
    /// the same moment: the engine takes a beat to spin up, and if another app
    /// holds the device it may never arrive at all, in which case staying
    /// silent is the honest outcome.
    var onFirstBuffer: (@Sendable () -> Void)?
    private var sawFirstBuffer = false

    /// Fired repeatedly while recording with how loud the microphone is right
    /// now, 0 for a silent room and 1 for somebody shouting into it.
    ///
    /// This exists so the recording pill can show that Speak is hearing *you*
    /// rather than only that it is switched on. Those are different claims, and
    /// the second one is the one that goes wrong: a muted input, a headset that
    /// went back to the case, a mic pointed at the wrong side of the laptop all
    /// look identical to a blinking dot.
    var onLevel: (@Sendable (Float) -> Void)?

    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: SAMPLE_RATE,
        channels: 1,
        interleaved: false
    )!

    func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(); lock.unlock()
        sawFirstBuffer = false

        let input = engine.inputNode
        try selectDevice(on: input)

        // Read the format *after* selecting the device: switching inputs
        // changes the sample rate, and a converter built from the old format
        // would resample from the wrong source rate.
        let inFormat = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: target)

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            guard let self, let conv = self.converter else { return }
            let ratio = SAMPLE_RATE / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: capacity)
            else { return }

            var err: NSError?
            var supplied = false
            conv.convert(to: out, error: &err) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buf
            }
            guard err == nil, out.frameLength > 0,
                  let ch = out.floatChannelData?[0] else { return }

            let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
            self.lock.lock()
            self.samples.append(contentsOf: chunk)
            let first = !self.sawFirstBuffer
            self.sawFirstBuffer = true
            self.lock.unlock()
            if first { self.onFirstBuffer?() }
            self.report(chunk)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Undo the tap before rethrowing. `stop()` will not do it: it
            // guards on `isRecording`, which is still false because the line
            // above threw. The tap therefore outlived the failure, and the next
            // attempt installed a second one on the same bus, which
            // AVAudioEngine does not allow. One transient microphone error, a
            // device switching away mid-session is enough, left dictation
            // broken until the app was relaunched.
            input.removeTap(onBus: 0)
            engine.stop()
            // The engine caches the input format, so a device that comes back
            // in a different state is only picked up after a reset.
            engine.reset()
            converter = nil
            throw error
        }
        isRecording = true
    }

    /// Splits one captured buffer into short windows and reports each one's
    /// loudness.
    ///
    /// Per window rather than per buffer: a buffer is about 85 ms, which is
    /// twelve updates a second, and a meter stepping twelve times a second
    /// looks like it is struggling rather than listening. 32 ms windows give
    /// about thirty, which is enough for the animation to be interpolating
    /// between real measurements instead of inventing motion between stale
    /// ones.
    private func report(_ chunk: [Float]) {
        guard let onLevel else { return }
        let window = Int(SAMPLE_RATE / 31)      // ~32 ms
        var i = 0
        while i < chunk.count {
            let end = min(i + window, chunk.count)
            onLevel(Recorder.loudness(chunk[i..<end]))
            i = end
        }
    }

    /// RMS mapped onto 0...1 through decibels rather than linearly.
    ///
    /// Linear amplitude is the wrong scale for a meter because hearing is not
    /// linear: ordinary speech through a laptop microphone peaks around 0.05
    /// of full scale, so a linear meter spends its whole life in the bottom
    /// twentieth and reads as "nothing is happening" while somebody talks.
    /// The window below is measured on this app's own capture path: -55 dBFS
    /// is a quiet room, -14 is shouting, and normal dictation covers most of
    /// what is between them.
    private static func loudness(_ window: ArraySlice<Float>) -> Float {
        guard !window.isEmpty else { return 0 }
        var sum: Float = 0
        for s in window { sum += s * s }
        let rms = (sum / Float(window.count)).squareRoot()
        guard rms > 0 else { return 0 }
        let db = 20 * log10f(rms)
        return min(1, max(0, (db + 55) / 41))
    }

    /// Points the engine's input at the chosen device.
    ///
    /// AVAudioEngine has no device property of its own on macOS; you reach
    /// through to the input node's underlying audio unit. Must happen before
    /// the engine is started.
    private func selectDevice(on input: AVAudioInputNode) throws {
        guard let device = Settings.resolvedMicrophone else { return }
        guard let unit = input.audioUnit else { return }

        var id = device.id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size))

        if status != noErr {
            // Not fatal: fall back to whatever the engine was already using
            // rather than refusing to record at all.
            log("could not select \(device.name) (status \(status)), using default")
        } else if DEBUG {
            log("recording from \(device.name)")
        }
    }

    /// Stops capture and hands back raw samples. No temp file: the samples go
    /// straight into an MLXArray.
    func stop() -> [Float]? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        lock.lock(); let pcm = samples; samples.removeAll(); lock.unlock()
        return pcm.count > Int(SAMPLE_RATE / 10) ? pcm : nil   // ignore < 0.1 s
    }
}
