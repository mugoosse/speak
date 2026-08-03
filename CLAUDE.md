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
| `MenuBarIcon.swift` | the status item artwork: one case per state, drawn |
| `Config.swift` | `ModelChoice`, `Settings`, `Shortcut`, `Modifier`, `KeyName`, `ModelStatus` |
| `Recorder.swift` | `AVAudioEngine` capture to 16 kHz mono Float32 |
| `Transcriber.swift` | routes to Parakeet (MLX) or Apple Intelligence |
| `AppleEngine.swift` | `SpeechAnalyzer` / `SpeechTranscriber`, macOS 26+ |
| `AudioDevices.swift` | CoreAudio input enumeration |
| `History.swift` | append-only JSONL log |
| `Permissions.swift` | TCC checks and Settings deep links |
| `Onboarding.swift` | stepped first-run window |
| `SettingsWindow.swift` | tabbed Settings: General, Model, History, Permissions |
| `LoginItem.swift` | native start-at-login registration through ServiceManagement |
| `AboutPane.swift` | the About tab: version, author, credits, licence |
| `Updater.swift` | Sparkle wiring, and the activation an `LSUIElement` app needs |

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

### Onboarding must never re-render from `updateControls`

`render()` ends by calling `updateControls()`. If `updateControls()` can call
`render()`, the two call each other until the stack dies.

That shipped once. `updateControls()` re-rendered whenever the step could
advance and any label still began with "○", meaning "a permission just landed,
show the tick". On the **Speech model** step both conditions are permanently
true while the model downloads: `canAdvance` is `true` there by design, and the
pending line always starts with "○". The app hung with a beachball on the first
machine that reached that step without the model already cached, which is every
new user. It was invisible here because a cached model reaches `.ready` before
the step is drawn.

Re-rendering is now driven by `structuralKey()`, a comparison of state rather
than a scan of rendered text. The elapsed-time summary is deliberately excluded
from that key and its label is updated in place: including it would rebuild the
body every 0.8s for the length of the download, replacing the engine radio
buttons under the cursor of someone trying to click one.

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

The process, the one-time setup and the secrets all live in `RELEASING.md`.
Read that before touching `release.sh` or the workflows. What matters here is
the handful of constraints the code depends on.

`VERSION` is the single source of truth for the marketing version.
`CFBundleVersion` is derived from `git rev-list --count HEAD`, so it always
increases without anyone maintaining it. Sparkle compares `CFBundleVersion` to
decide whether an update exists, so anything that makes it go backwards
strands every installed copy.

Signing uses the Hardened Runtime, which notarization requires. That is why
`Speak.entitlements` exists: without `com.apple.security.device.audio-input`
the runtime blocks the microphone.

`release.sh` is the only thing that publishes, and CI calls the same script, so
a local release and a CI release cannot diverge.

### Notarization is not a synchronous step

Apple's queue has taken over an hour on a first submission, and a dropped
connection during the wait kills the run with the submission already accepted
server-side. That is why submit and wait are separate calls rather than
`notarytool submit --wait`, and why `--resume <id>` exists. Recombining them
throws away an hour every time the network hiccups.

### Sparkle's nested code has to be signed inside-out

`Sparkle.framework` contains two XPC services, a helper binary and an updater
app. Each needs its own signature with the hardened runtime, signed before the
framework, which is signed before the app: sealing a container fixes whatever
it holds.

They must not get `$COMMON`. That carries Speak's entitlements and bundle
identifier, so applying it would grant the microphone to Sparkle's downloader
and produce four bundles claiming to be `com.mgo.speak`.

The framework is copied with `ditto`, not `cp -R`, because a framework's
version symlinks get flattened by `cp` and the result fails
`codesign --verify --deep --strict`.

SwiftPM links Sparkle but never embeds it, so `Package.swift` adds an rpath of
`@executable_path/../Frameworks` and `make_app.sh` copies the framework there.
Remove either half and the app dies at launch with a dyld error.

### Losing the Sparkle private key ends the update channel

Installed copies only accept updates signed by the key they shipped with. A new
key means every existing user has to reinstall by hand. It lives in the login
keychain; the backup procedure is in `RELEASING.md`.

## Testing

There is no test target. Verification is manual and mostly through
`--transcribe` plus the debug trace. If you add a test target, note that MLX
needs the Metal toolchain, so tests must run through `xcodebuild`, not
`swift test`.
