# speak

Minimal push-to-talk dictation for macOS. Press **Fn + Left Shift** to start,
press again to stop. The transcript lands on your clipboard. Nothing else.

Pure Swift. Runs `parakeet-tdt-0.6b-v3` locally via
[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift). No Python, no
network at runtime, no account, no subscription.

## Build

Metal kernels must be compiled by Xcode's build system, so **`swift build`
alone is not enough** — it links, but fails at runtime with
`Failed to load the default metallib`.

One-time setup, because Xcode 26 ships the Metal compiler as a separate
downloadable component (~688 MB):

```sh
xcodebuild -downloadComponent MetalToolchain
```

Then:

```sh
xcodebuild -scheme speak -destination 'platform=macOS,arch=arm64' \
  -configuration Release -derivedDataPath .xcbuild \
  -skipPackagePluginValidation build
```

`-skipPackagePluginValidation` is required because mlx-swift ships a
`CudaBuild` plugin that Xcode refuses to run unattended. It is a no-op on
Apple Silicon.

## Run

```sh
.xcbuild/Build/Products/Release/speak
```

First launch asks for two permissions:

1. **Microphone** — standard prompt.
2. **Accessibility** — required because a modifier-only chord like Fn+Shift
   never arrives as a `keyDown` event. It has to be reconstructed from
   `flagsChanged`, and that needs a global event monitor.

Grant Accessibility in System Settings → Privacy & Security → Accessibility,
then relaunch. The menu bar icon shows state: `mic` ready, `record.circle`
recording, `hourglass` transcribing.

The model (~2.5 GB) downloads once on first run to
`~/.cache/huggingface/hub/mlx-audio/`.

## Verify without the GUI

```sh
.xcbuild/Build/Products/Release/speak --transcribe some.wav
```

Prints the transcript to stdout and timings to stderr. Needs no permissions,
so it is the fastest way to confirm the model path works.

## Known gotcha: the Fn key

macOS assigns the Fn/Globe key its own action. If Fn+Shift misfires or opens
the emoji picker, set System Settings → Keyboard → "Press 🌐 key to" →
**Do Nothing**. Equivalent from the shell:

```sh
defaults write com.apple.HIToolbox AppleFnUsageType -int 0
```

Log out and back in for it to take effect.

## Config

| Variable | Default | Meaning |
|---|---|---|
| `SPEAK_MODEL` | `mlx-community/parakeet-tdt-0.6b-v3` | any mlx-audio STT model |
| `SPEAK_AUTOPASTE` | unset | set to `1` to press Cmd+V after copying |

## Design

Single process, no IPC. The model loads once at launch into an actor and stays
resident; captured samples go straight from `AVAudioEngine` into an `MLXArray`
with no intermediate WAV file.

Keeping the model resident is what makes dictation feel instant: load is a
one-off cost at launch, while transcribing a short utterance takes tens of
milliseconds.

Audio is captured at whatever rate the input device prefers and converted to
16 kHz mono Float32, which is what Parakeet expects.

## Why Parakeet and not Whisper

Benchmarked on hard passages, Whisper-large-v3-turbo hallucinated multilingual
text on trailing silence — a well-documented failure mode, and disqualifying
for dictation, because it invents words you never said. Parakeet v3 stayed
clean, punctuated correctly, and got proper nouns right.

## Not implemented

Streaming partial results, custom vocabulary, history. Deliberately.
