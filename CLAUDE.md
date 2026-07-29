# Speak: working notes for coding agents

Menu-bar push-to-talk dictation for macOS. Pure Swift, fully local. Press a
modifier chord, talk, press again, transcript goes to the clipboard.

Read `README.md` for user-facing behaviour. This file is about working on the
code without re-learning things the hard way.

## Build and run

**`swift build` does not produce a working binary.** It links, then dies at
runtime with `Failed to load the default metallib`, because SwiftPM never
compiles MLX's Metal kernels. Always use the scripts:

```sh
./build.sh      # xcodebuild wrapper, checks the Metal toolchain first
./make_app.sh   # wraps the binary in a signed .app
./install.sh    # both, then installs to /Applications and relaunches
```

One-time setup on a new machine:

```sh
xcodebuild -downloadComponent MetalToolchain    # ~688 MB, separate in Xcode 26
```

`-skipPackagePluginValidation` is required because mlx-swift ships a `CudaBuild`
plugin Xcode refuses to run unattended. It is a no-op on Apple Silicon.

### Verifying a change without the GUI

```sh
/Applications/Speak.app/Contents/MacOS/Speak --transcribe some.wav
```

Prints the transcript to stdout and load/warm timings to stderr, needs no
permissions. Use it to separate a model problem from a shortcut problem before
touching UI code.

`SPEAK_DEBUG=1` traces every modifier change and keyDown to stderr.

## Layout

| File | Holds |
|---|---|
| `main.swift` | entry point and the `--transcribe` CLI mode |
| `AppDelegate.swift` | menu bar, event tap, dictation toggle, model state |
| `Config.swift` | `ModelChoice`, `Settings`, `Shortcut`, `Modifier`, `KeyName`, `ModelStatus` |
| `Recorder.swift` | `AVAudioEngine` capture to 16 kHz mono Float32 |
| `Transcriber.swift` | routes to Parakeet (MLX) or Apple Intelligence |
| `AppleEngine.swift` | `SpeechAnalyzer` / `SpeechTranscriber`, macOS 26+ |
| `AudioDevices.swift` | CoreAudio input enumeration |
| `History.swift` | append-only JSONL log |
| `Permissions.swift` | TCC checks and Settings deep links |
| `Onboarding.swift` | stepped first-run window |
| `SettingsWindow.swift` | tabbed Settings: General, Model, History, Permissions |

## Things that will bite you

These were all found the hard way. Changing the code near them without knowing
why they are the way they are will reintroduce the bug.

### Signing decides whether permissions survive a rebuild

Ad-hoc signing gives a designated requirement of `cdhash H"…"`, pinned to one
build. TCC keys the Accessibility grant to it, so **every rebuild silently
invalidates the permission** while System Settings still shows the toggle on.
`make_app.sh` signs with a real certificate when one exists, producing a stable
identity-based requirement. Do not "simplify" it back to `--sign -`.

Check with:

```sh
codesign -d -r- /Applications/Speak.app     # must not contain cdhash
```

### The event tap must stay ordered and synchronous

`installHotkey` dispatches with `DispatchQueue.main.async`, not `Task {}`.
Independent Tasks have no ordering guarantee, and an all-released event
overtaking the key-downs truncates a chord being recorded (this shipped once as
"3-key shortcuts don't work").

The tap is `.defaultTap`, not `.listenOnly`, because a shortcut containing a
character key has to swallow that keystroke. Only an exact match is consumed;
everything else passes through. Handle `tapDisabledByTimeout` or the tap dies
silently.

### fn is invisible to NSEvent on Apple Silicon

`NSEvent.addGlobalMonitorForEvents` never sees the Globe/fn key; the system
consumes it first. Hence the `CGEventTap`. Also: `.function` is set by arrow and
F-keys too, and `NSEvent.shift` cannot distinguish left from right, which is why
`Modifier` uses device-dependent bits (`0x02` for left shift, and so on).

### mlx-audio's `language` parameter does nothing

It is copied into `STTOutput` and never reaches the decoder. A language picker
for Parakeet would be a control that silently does nothing, which is why the
Language setting only appears for Apple Intelligence. This is also why the
default model is v2 (English-only) rather than the multilingual v3, which
otherwise decodes short English clips as Cyrillic.

### Download progress cannot be a percentage

`URLSession.download` streams to a system temp path and only moves the finished
file into the cache, so nothing observable grows during the transfer. A
directory-derived percentage sits at 0% then jumps to 100%, reading as hung.
`ModelStatus.downloading` therefore carries elapsed time.

Two cache locations matter: `~/.cache/huggingface/hub/models--…` (real
download) and `~/.cache/huggingface/hub/mlx-audio/…` (mlx-audio's copy).
Clearing only the second gives a fake fast "download" that is really a local
copy. A real fresh-install test needs both gone.

### Windows must float

The app is `LSUIElement`, so it has no Dock icon or app-switcher entry. A window
that falls behind a system permission dialog is unrecoverable. Onboarding sets
`.floating` and re-activates after each permission prompt.

### Audio device selection must precede reading the format

Switching inputs changes the hardware sample rate. Build the converter from the
format read *before* selection and audio records pitch-shifted and garbled.
See `Recorder.selectDevice`.

Devices are stored by UID, not `AudioDeviceID`: the numeric ID is assigned at
connect time and changes when a device is replugged.

## Conventions

- No em dashes anywhere: code, comments, docs, UI copy.
- Do not use the word "drift".
- Comments explain *why*, especially where the obvious implementation is wrong.
  Most comments in this codebase mark a trap; keep them when editing nearby.
- UI copy states the trade-off rather than hiding it in a tooltip.

## Releasing

`VERSION` is the single source of truth for the marketing version.
`CFBundleVersion` is derived from `git rev-list --count HEAD`, so it always
increases without anyone maintaining it.

```sh
echo 1.0.1 > VERSION
git commit -am "1.0.1" && git tag v1.0.1
git push && git push --tags        # CI builds, notarizes and publishes
./release.sh                       # or do it locally, artifacts land in dist/
./release.sh --publish             # local build plus GitHub release
```

`release.sh` notarizes only when both a Developer ID Application certificate
and a stored `notarytool` profile exist. Otherwise it still produces artifacts
and warns that users will meet Gatekeeper. It always prints the `spctl` verdict,
so a release that would be blocked is obvious before publishing.

Signing uses the Hardened Runtime, which notarization requires. That is why
`Speak.entitlements` exists: without `com.apple.security.device.audio-input`
the runtime blocks the microphone.

After releasing, bump `version` and `sha256` in the Homebrew cask at
`../homebrew-tap/Casks/speak.rb`.

## Testing

There is no test target. Verification is manual and mostly through
`--transcribe` plus the debug trace. If you add a test target, note that MLX
needs the Metal toolchain, so tests must run through `xcodebuild`, not
`swift test`.
