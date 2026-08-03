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
