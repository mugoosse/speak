# Speak

Push-to-talk dictation for macOS. Press a shortcut, talk, press it again. The
transcript lands on your clipboard. That is the whole app.

Pure Swift, fully local. No account, no subscription, no telemetry, and nothing
leaves the machine.

**~35 ms** to transcribe a 6-second utterance on an M4 Max, measured warm.

## Install

Requires Apple Silicon, macOS 14+ (macOS 26+ for Apple Intelligence), Xcode 16+.

```sh
git clone <this repo> && cd speak
xcodebuild -downloadComponent MetalToolchain   # one-time, ~688 MB
./install.sh
```

`install.sh` builds, bundles, signs, installs to `/Applications/Speak.app`, and
restarts the running copy.

A setup window then walks through four steps: microphone, accessibility,
choosing an engine, and done. It ticks each permission off as it lands and arms
the shortcut without needing a relaunch.

Accessibility is not optional: a modifier chord never arrives as a `keyDown`,
so it has to be reconstructed from a low-level event tap.

> If **Speak** is listed in Accessibility but the shortcut does nothing, remove
> it with the minus button and add it again. macOS keeps a stale entry after an
> app is replaced.

## Use

Press **fn + ⇧ left** (the default) to start, speak, press again to stop. Paste
with ⌘V. The menu bar icon tracks state:

| Icon | Meaning |
|---|---|
| `mic` | ready |
| red dot | recording |
| hourglass | transcribing |
| download arrow | fetching the model, with elapsed time |
| warning triangle | see the menu for what went wrong |

## Engines

Choose in **Settings → Model**, or during setup.

| Engine | Trade-off |
|---|---|
| **English only** (default) | Parakeet v2 · most accurate · 2.4 GB download |
| **Multilingual** | Parakeet v3 · 25 languages · may misdetect short clips · 2.4 GB |
| **Apple Intelligence** | Built in · no download · ready immediately · less accurate |

### Why Parakeet v2 by default

**Not Whisper.** Benchmarked against Parakeet on hard passages,
`whisper-large-v3-turbo` hallucinated multilingual text on trailing silence, a
well-documented failure mode. For dictation that is disqualifying: it invents
words you never said and drops them into your clipboard. Dropped words you
notice; invented ones you do not.

**Not Parakeet v3.** v3 is multilingual and, on a short utterance with little
context, decodes English speech as Cyrillic. It cannot be constrained here:
mlx-audio's `language` parameter is copied into the output struct and never
reaches the decoder. (TypeWhisper does restrict v3 by language, but it runs
Parakeet through [FluidAudio](https://github.com/FluidInference/FluidAudio),
whose ASR manager takes a real `language:` argument.)

v2 is the English-only predecessor: same speed, same architecture, and
structurally unable to emit Cyrillic. A model that cannot produce Russian beats
one that is merely discouraged from it.

### Language

The **Language** picker appears only for Apple Intelligence, because that is the
only engine where it does anything. `SpeechTranscriber` takes a locale that
genuinely constrains recognition; Parakeet has no equivalent control, so
offering one there would be a setting that silently does nothing.

Automatic prefers a locale already installed on your Mac. Options marked
*(downloads)* fetch a small language pack on first use.

## Shortcut

**Settings → General → Change…**, then hold your combination and release.

Up to three modifiers (fn, shift, control, option, command), optionally followed
by one ordinary key. Left and right modifiers count separately, so `⌃ left` and
`⌃ right` are different shortcuts.

- `fn + ⇧ left`: pure modifier chord
- `fn + ⇧ left + P`: with a character key, which is **swallowed** so it does not
  also type a P into whatever is focused

A single modifier is allowed but warned about: it fires every time you press
that key, including mid-sentence.

If the chord misbehaves, macOS may be reserving fn for the emoji picker. Set
System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**, or:

```sh
defaults write com.apple.HIToolbox AppleFnUsageType -int 0
```

Log out and back in for it to take effect.

## Microphone

**Settings → General → Microphone.** "System default" follows Sound settings.
Pick a specific device to pin it regardless.

Devices are saved by UID, not by numeric ID: `AudioDeviceID` is assigned at
connect time, so unplugging a USB mic and reconnecting changes the number. If a
pinned device is disconnected, Speak records from the system default and says so,
then re-binds when the device returns.

## History

Every dictation is appended to
`~/Library/Application Support/speak/history.jsonl`:

```json
{"at":"2026-07-29T13:59:32Z","duration_sec":1.3,"words":5,"text":"…"}
```

**Settings → History** lists them all: double-click a row to copy, or reveal the
file. The menu bar shows the last five.

JSONL rather than a database so it stays greppable and outlives the app:

```sh
jq -r .text ~/Library/Application\ Support/speak/history.jsonl
```

Delete the file to clear it. Nothing is sent anywhere.

## Updating

Login Items stores a **path**, and `install.sh` always ships to the same one, so
register `/Applications/Speak.app` once and never touch it again. To update:

```sh
./install.sh
```

That quits the old copy, replaces it, and relaunches. Permissions survive
because `make_app.sh` signs with a stable identity.

To run at login: System Settings → General → Login Items → **+** →
`/Applications/Speak.app`.

### Signing matters more than it looks

Ad-hoc signing (`codesign --sign -`) produces a designated requirement of
`cdhash H"…"`, which is the hash of *that exact build*. TCC pins the
Accessibility grant to it, so every rebuild silently invalidates the permission:
the toggle still looks on in System Settings, but the new binary is a different
app as far as macOS is concerned, and the shortcut quietly stops working.

`make_app.sh` therefore signs with a real certificate when one is available,
giving a stable requirement:

```
identifier "com.mgo.speak" and anchor apple generic and
certificate leaf[subject.CN] = "Apple Development: …"
```

Any certificate works, including the free Apple Development one Xcode installs
when you add an Apple ID. Without one it falls back to ad-hoc and prints a
warning explaining the consequence.

## Config

Environment variables override the UI, for one-off runs:

| Variable | Default | Meaning |
|---|---|---|
| `SPEAK_MODEL` | unset | force a model repo; disables the Model picker |
| `SPEAK_AUTOPASTE` | unset | `1` presses ⌘V after copying |
| `SPEAK_DEBUG` | unset | `1` traces every modifier change to stderr |

## Disk use

Parakeet is stored **twice**, about 4.6 GB total: once in the Hugging Face blob
cache (`~/.cache/huggingface/hub/models--…`) and once in mlx-audio's own
directory (`~/.cache/huggingface/hub/mlx-audio/…`). That duplication is
mlx-audio's design, not something Speak controls.

Apple Intelligence adds nothing of its own; its assets are system-managed and
usually already present because system dictation uses them.

## Building by hand

```sh
./build.sh      # xcodebuild wrapper
./make_app.sh   # wrap the binary in a signed .app
./install.sh    # both, then install to /Applications and relaunch
swift make_icon.swift   # regenerate Assets/Speak.icns
```

`swift build` alone is **not** enough. It links successfully and then dies at
runtime with `Failed to load the default metallib`, because SwiftPM never
compiles MLX's Metal kernels. Two further wrinkles, both handled by `build.sh`:

- Xcode 26 ships the Metal compiler as a separate downloadable component.
- mlx-swift ships a `CudaBuild` plugin Xcode refuses to run unattended, hence
  `-skipPackagePluginValidation`. It is a no-op on Apple Silicon.

### Verifying without the GUI

```sh
/Applications/Speak.app/Contents/MacOS/Speak --transcribe some.wav
```

Transcript to stdout, timings to stderr, no permissions needed. The fastest way
to tell a model problem from a shortcut problem.

## Design

Single process, no IPC. The engine loads once at launch into an actor and stays
resident, which is what makes dictation feel instant: load is a one-off cost,
transcription is tens of milliseconds. Captured samples go straight from
`AVAudioEngine` into an `MLXArray` with no intermediate WAV file.

Audio is captured at the input device's preferred rate and converted to 16 kHz
mono Float32, which is what Parakeet expects. Clips under one second are padded
with silence, because Parakeet degrades badly on very short inputs and a
one-word dictation is easily that short.

### The shortcut

A modifier chord cannot use `RegisterEventHotKey` (it requires a non-modifier
key) and never arrives as a `keyDown`. Both halves are reconstructed from a
`CGEventTap`, which has four traps worth knowing:

1. **`NSEvent` global monitors never see fn on Apple Silicon.** The Globe key is
   consumed by the system first, so a monitor reports the shift half of the
   chord and never the fn half. The tap sits lower and reports fn as
   `maskSecondaryFn`.
2. **`.function` is also set by arrow and F-keys**, so testing that flag alone
   misfires constantly.
3. **`NSEvent.shift` cannot tell left from right.** That needs the
   device-dependent bit `0x02`.
4. **Tap callbacks must be dispatched in order.** Using one `Task` per event
   loses ordering, and an all-released event can overtake the key-downs and
   truncate a chord being recorded.

`SPEAK_DEBUG=1` traces what your keyboard actually reports, which is how the fn
issue above was diagnosed.

### Download progress is elapsed time, not a percentage

`URLSession.download` streams the weights into a system temp path and only moves
the finished file into the cache, so nothing observable grows while the large
file is in flight. A directory-derived percentage sits at 0% for the whole
download and then jumps to 100%, which reads as hung. Elapsed time is less
informative but true.

## Not implemented

Streaming partial results, custom vocabulary, cloud fallback. Deliberately.

## License

MIT
