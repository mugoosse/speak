# Speak

Push-to-talk dictation for macOS. Press **Fn + Left Shift**, talk, press again.
The transcript lands on your clipboard. That is the whole app.

Pure Swift, fully local. Runs NVIDIA's Parakeet on Apple Silicon via
[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift). No Python, no
network at runtime, no account, no subscription, no telemetry.

**~35 ms** to transcribe a 6-second utterance on an M4 Max, measured warm.

## Install

Requires Apple Silicon, macOS 14+, and Xcode 16+.

```sh
git clone <this repo> && cd speak
xcodebuild -downloadComponent MetalToolchain   # one-time, ~688 MB
./install.sh
```

`install.sh` builds, bundles, installs to `/Applications/Speak.app`, and
restarts the running copy.

Then grant two permissions:

1. **Microphone** — prompted on your first dictation.
2. **Accessibility** — System Settings → Privacy & Security → Accessibility →
   enable **Speak**. Relaunch afterwards; macOS does not apply the grant to an
   already-running process.

Accessibility is not optional: a modifier-only chord like Fn+Shift never
arrives as a `keyDown`, so it has to be reconstructed from a low-level event
tap.

The model (~2.5 GB) downloads once on first launch to
`~/.cache/huggingface/hub/mlx-audio/`.

## Use

Press **Fn + Left Shift** to start, speak, press again to stop. Paste with
Cmd+V. The menu bar icon tracks state:

| Icon | Meaning |
|---|---|
| `mic` | ready |
| red dot | recording |
| hourglass | transcribing |
| warning triangle | see tooltip |

## History

Every dictation is appended to
`~/Library/Application Support/speak/history.jsonl`:

```json
{"at":"2026-07-29T12:31:07Z","duration_sec":6.2,"words":18,"text":"..."}
```

The menu bar shows the last 10; click one to copy it again, or "Open history
file…" to reveal it in Finder.

JSONL rather than a database so it stays greppable and outlives the app:

```sh
jq -r .text ~/Library/Application\ Support/speak/history.jsonl   # everything
jq -r 'select(.words > 50) | .text' ~/Library/…/history.jsonl    # long ones
```

Delete the file to clear history. Nothing is sent anywhere.

## Updating

Login Items stores a **path**, and `install.sh` always ships to the same one,
so registering `/Applications/Speak.app` once is enough. To update:

```sh
./install.sh
```

That quits the old copy, replaces it, and relaunches. Your login item keeps
working and permissions are preserved, because `make_app.sh` always signs with
the same identifier (`com.mgo.speak`) and TCC keys the Accessibility grant to
that identity rather than to the binary's contents.

To run at login: System Settings → General → Login Items → **+** →
`/Applications/Speak.app`.

## Config

| Variable | Default | Meaning |
|---|---|---|
| `SPEAK_MODEL` | `mlx-community/parakeet-tdt-0.6b-v2` | any mlx-audio STT model |
| `SPEAK_AUTOPASTE` | unset | `1` presses Cmd+V after copying |
| `SPEAK_DEBUG` | unset | `1` traces every modifier change to stderr |

## Why Parakeet v2, not v3 or Whisper

**Not Whisper.** Benchmarked against Parakeet on hard passages,
`whisper-large-v3-turbo` hallucinated multilingual text on trailing silence, a
well-documented failure mode. For dictation that is disqualifying: it invents
words you never said and drops them straight into your clipboard. Dropped words
you would notice; invented ones you would not.

**Not v3.** v3 is multilingual across 25 European languages and, on a short
utterance with little context, decodes English speech as Cyrillic. It cannot be
constrained here: mlx-audio's `language` parameter is copied into the output
struct and never reaches the decoder. (TypeWhisper does restrict v3 by language,
but it runs Parakeet through [FluidAudio](https://github.com/FluidInference/FluidAudio),
whose ASR manager takes a real `language:` argument. Switching engines is the
route to multilingual support if you want it.)

v2 is the English-only predecessor: same speed, same architecture, and
structurally unable to emit Cyrillic. A model that cannot produce Russian beats
one that is merely discouraged from it.

## Building by hand

```sh
./build.sh      # xcodebuild wrapper
./make_app.sh   # wrap binary in a signed .app
```

`swift build` alone is **not** enough. It links successfully and then dies at
runtime with `Failed to load the default metallib`, because SwiftPM never
compiles MLX's Metal kernels. Two further wrinkles, both handled by
`build.sh`/`make_app.sh`:

- Xcode 26 ships the Metal compiler as a separate downloadable component.
- mlx-swift ships a `CudaBuild` plugin Xcode refuses to run unattended, hence
  `-skipPackagePluginValidation`. It is a no-op on Apple Silicon.

### Verifying without the GUI

```sh
/Applications/Speak.app/Contents/MacOS/Speak --transcribe some.wav
```

Transcript to stdout, timings to stderr, no permissions needed. The fastest way
to tell a model problem from a hotkey problem.

## Design

Single process, no IPC. The model loads once at launch into an actor and stays
resident, which is what makes dictation feel instant: load is a one-off cost,
transcription is tens of milliseconds. Captured samples go straight from
`AVAudioEngine` into an `MLXArray` with no intermediate WAV file.

Audio is captured at the input device's preferred rate and converted to 16 kHz
mono Float32, which is what Parakeet expects. Clips under one second are padded
with silence, because Parakeet degrades badly on very short inputs and a
one-word dictation is easily that short.

### The hotkey

Fn+Shift is a modifier-only chord, so `RegisterEventHotKey` cannot express it
(it requires a non-modifier key) and it never arrives as a `keyDown`. Both
halves have to be reconstructed from `flagsChanged`, which has three traps:

1. **`NSEvent` global monitors do not see Fn on Apple Silicon.** The Globe/Fn
   key is consumed by the system first. A monitor reports the shift half of the
   chord and never the Fn half, so this uses a `CGEventTap`, which sits lower
   and reports Fn as `maskSecondaryFn`.
2. **`.function` is also set by arrow keys and F-keys**, so testing that flag
   alone misfires constantly.
3. **`NSEvent.shift` cannot distinguish left from right shift.** That needs the
   device-dependent mask `0x02`.

If the chord misbehaves, macOS may be reserving Fn for the emoji picker. Set
System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**, or:

```sh
defaults write com.apple.HIToolbox AppleFnUsageType -int 0
```

Log out and back in for it to take effect. `SPEAK_DEBUG=1` traces what your
keyboard actually reports, which is how the Fn issue above was diagnosed.

## Not implemented

Streaming partial results, custom vocabulary, cloud fallback. Deliberately.

## License

MIT
