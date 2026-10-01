# Audio capture

How `Recorder.swift` and `AudioDevices.swift` capture from the chosen microphone, and why the obvious implementations fail.

## Audio device selection must precede reading the format

Switching inputs changes the hardware sample rate. Build the converter from the format read *before* selection and audio records pitch-shifted and garbled. See `Recorder.build`.

Devices are stored by UID, not `AudioDeviceID`: the numeric ID is assigned at connect time and changes when a device is replugged.

## `AVAudioEngine` picks the input device before you can, and the first recording pays

Capture is a raw `kAudioUnitSubType_HALOutput` unit rather than an `AVAudioEngine` because the engine chooses its device the instant `inputNode` is first read, and there is no way to get in front of that. Measured with music on a Bose headset and the built-in microphone chosen in Settings:

- reading `engine.inputNode` bound the unit to `CADefaultDeviceAggregate`, not to a device, and dropped the headset from 44100 Hz to 16000 Hz. That is the hands-free profile: the music went mono and the headset announced a call, before Speak had expressed any preference at all;
- `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` then returned `noErr` **and did not take effect**. The unit stayed on the aggregate, the headset's input device read `running=true`, and the tap delivered **0 buffers in 1.5 seconds**. The first dictation of every session recorded nothing;
- the second recording bound correctly. So the bug was invisible to anyone who tested by dictating twice.

A HAL unit takes its device before `AudioUnitInitialize`, so no default device is ever opened. Same machine, same headset: the Bose stayed at 44100 Hz throughout, its input never ran, and the first recording delivered 141 buffers.

Two consequences worth keeping:

- **Disable the output bus.** A HAL unit with output enabled opens the default *output* device too, which on a Bluetooth headset is the other half of the same profile switch.
- **Dispose the unit in `stop()`, do not keep it.** A unit that is merely stopped still holds its device, so the headset would sit in hands-free mode from the first dictation until Speak quit. Disposing also re-resolves the device every time, which is what makes a Settings change take effect on the next recording instead of the next launch.

`AppDelegate.startDictation` still waits for `onFirstBuffer` before saying "talk", and that is still right: a cold device takes a beat. It is no longer waiting for a profile switch that should never have happened.

Listen's `MicRecorder` has the same shape and the same flaw.

## `AVAudioPCMBuffer` rebuilds its buffer list, so do not size it by hand

`AudioUnitRender` needs a buffer list whose `mDataByteSize` says how much room there is. The obvious way to say so is to write the sizes through `mutableAudioBufferList` and then pass that list to render. It does not work, and the way it fails is nasty:

    let list = UnsafeMutableAudioBufferListPointer(scratch.mutableAudioBufferList)
    for i in 0..<list.count { list[i].mDataByteSize = frames * 4 }
    AudioUnitRender(unit, flags, ts, bus, frames, scratch.mutableAudioBufferList)

`AVAudioPCMBuffer` derives `mDataByteSize` from `frameLength` and recomputes it on *every* access, so the second `mutableAudioBufferList` returns a list claiming **zero** bytes and render answers `paramErr` (-50) on every slice for ever. Set `frameLength` first and touch nothing else:

    scratch.frameLength = frames
    AudioUnitRender(unit, flags, ts, bus, frames, scratch.mutableAudioBufferList)

Worth knowing what this looks like from outside, because it looks like anything but a buffer bug: the device really is running, so macOS shows the microphone indicator in the menu bar and the user is certain Speak is recording. But no buffer ever arrives, so `onFirstBuffer` never fires, and everything hanging off it silently does not happen: no recording pill, no start cue, no end cue, no transcript. Debug tracing lives in `Recorder.trace`, capped at eight lines because it runs on the audio thread; `SPEAK_DEBUG=1` with `--hud-demo` is the fastest way to see whether slices are arriving at all.

## Levels for the recording pill

The pill is driven by `Recorder.onLevel` (see `docs/ui.md`). Four things about the level signal are measured rather than chosen:

- **The loudness is mapped through decibels, not linearly.** Speech through a laptop microphone peaks around 0.05 of full scale, so a linear meter lives in the bottom twentieth of its range and reads as nothing happening while somebody talks. `Recorder.loudness` clamps -55 dBFS to -14 dBFS onto 0...1.
- **Levels are reported per 32 ms window, not per buffer.** A 4096-frame buffer is about 85 ms, and twelve updates a second looks like a meter struggling rather than listening.
- **Fast attack, slow release** (`Envelope`). Speech has gaps inside every word, and following them down as fast as up strobes instead of tracking.
- **The level callback goes to the main actor through `DispatchQueue.main.async`, not `Task {}`.** The waveform is a queue, so a reordered sample is a bar drawn in the wrong place. This is the same ordering trap as `installHotkey` (see `docs/input.md`).
