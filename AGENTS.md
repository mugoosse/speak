# Speak: working notes for coding agents

Menu-bar push-to-talk dictation for macOS. Pure Swift, fully local. Press a modifier chord, talk, press again, transcript goes to the clipboard. `README.md` covers user-facing behaviour.

Speak is retired: dictation moved into Listen, and 1.6.0 is the last release (see the notice at the top of `README.md`).

## Build and run

**`swift build` does not produce a working binary.** It links, then dies at runtime with `Failed to load the default metallib`, because SwiftPM never compiles MLX's Metal kernels. Always use the scripts:

```sh
./build.sh      # xcodebuild wrapper, checks the Metal toolchain first
./make_app.sh   # wraps the binary in a signed .app
./install.sh    # both, then installs to /Applications and relaunches
```

One-time setup on a new machine:

```sh
xcodebuild -downloadComponent MetalToolchain    # ~688 MB, separate in Xcode 26
```

`-skipPackagePluginValidation` is required because mlx-swift ships a `CudaBuild` plugin Xcode refuses to run unattended. It is a no-op on Apple Silicon.

### Verifying a change without the GUI

```sh
/Applications/Speak.app/Contents/MacOS/Speak --transcribe some.wav
echo "um so i think it works" | /Applications/Speak.app/Contents/MacOS/Speak --polish -
open -n -a /Applications/Speak.app --args --hud-demo   # add --fake for no mic
```

- `--transcribe` prints the transcript to stdout and load/warm timings to stderr, and needs no permissions. Use it to separate a model problem from a shortcut problem before touching UI code.
- `--polish` runs polishing then the dictionary's corrections: result on stdout, chunk count and timings on stderr. `SPEAK_POLISH=0` skips the model so the corrections can be exercised alone; `SPEAK_REPAIR=1` / `SPEAK_REPAIR=0` forces the self-correction pass on or off, which is how to A/B it without touching the saved setting.
- Run the installed binary, not the one in `.xcbuild`: that one dies looking for Sparkle, and it reads a different defaults domain.
- `--hud-demo` must go through the bundle with `-n` (details in `docs/ui.md`).
- `SPEAK_DEBUG=1` traces every modifier change and keyDown to stderr.
- From a shell, `env -u HF_HOME` or expect a surprise model download (`docs/models.md`).

## Testing

There is no test target. Verification is manual, mostly through `--transcribe` plus the debug trace. If you add a test target, MLX needs the Metal toolchain, so tests must run through `xcodebuild`, not `swift test`. Two scripts stand in for one, over the installed app: `./verify_polish.sh` (every polisher claim as an assertion) and `./replay_history.sh` (your own dictations, with and without the repair pass); see `docs/polisher.md`.

## Layout

`Sources/speak/`:

| File | Holds |
|---|---|
| `main.swift` | entry point and the `--transcribe` CLI mode |
| `AppDelegate.swift` | menu bar, event tap, dictation toggle, model state |
| `MenuBarIcon.swift` | the status item artwork: the mascot template plus the system symbols |
| `BrandIcon.swift` | the full-colour app icon view for first-run and empty states |
| `Config.swift` | `ModelChoice`, `Settings`, `Shortcut`, `Modifier`, `KeyName`, `ModelStatus` |
| `Recorder.swift` | HAL audio unit capture to 16 kHz mono Float32, and the loudness the pill animates from |
| `RecordingIndicator.swift` | the floating pill: layout per meter style, and the trash button |
| `Meters.swift` | `MeterStyle` and the three meter views |
| `MeterDemo.swift` | `--hud-demo`, which stacks every style on one microphone |
| `Cue.swift` | start/end sounds, using system sounds |
| `Transcriber.swift` | routes to Parakeet (MLX) or Apple Intelligence |
| `AppleEngine.swift` | `SpeechAnalyzer` / `SpeechTranscriber`, macOS 26+ |
| `Polisher.swift` | `PolishEngine`, both prompts, chunking, timeout, fallbacks |
| `SpeechRepair.swift` | the deterministic gate deciding which sentences are worth a repair request |
| `ApplePolishEngine.swift` | FoundationModels behind `PolishEngine`, macOS 26+ |
| `CustomDictionary.swift` | terms and corrections: storage, matching, import |
| `Punctuation.swift` | trimming the full stop off a short dictation |
| `TextPane.swift` | the Text tab: polish settings and the dictionary editor |
| `AudioDevices.swift` | CoreAudio input enumeration |
| `History.swift` | append-only JSONL log |
| `Permissions.swift` | TCC checks and Settings deep links |
| `SecureInput.swift` | whether another app is swallowing the keyboard, and which |
| `Onboarding.swift` | stepped first-run window |
| `SettingsWindow.swift` | tabbed Settings: General, Model, Text, History, Permissions, About |
| `LoginItem.swift` | native start-at-login registration through ServiceManagement |
| `AboutPane.swift` | the About tab: version, author, credits, licence |
| `Updater.swift` | Sparkle wiring, and the activation an `LSUIElement` app needs |

## Things that will bite you

All found the hard way; changing nearby code without knowing why reintroduces the bug. The short version is here; read the doc before touching the area.

- Code signing (`docs/signing.md`): ad-hoc signing (`--sign -`) silently voids the Accessibility grant on every rebuild; Hardened Runtime needs `Speak.entitlements` for the microphone; Sparkle's nested code is signed inside-out without `$COMMON`, copied with `ditto`, and needs the rpath in `Package.swift`.
- Keyboard input (`docs/input.md`): event tap callbacks use `DispatchQueue.main.async`, never `Task {}`; the tap is `.defaultTap` and must handle `tapDisabledByTimeout`; fn is invisible to `NSEvent`; secure input starves the tap of key events, and `SecureInput.isOn` is checked only in `menuWillOpen`.
- Audio capture (`docs/audio-capture.md`): select the device before reading the format; capture is a raw HAL unit, not `AVAudioEngine`, with the output bus disabled and the unit disposed in `stop()`; never size an `AVAudioPCMBuffer`'s buffer list by hand; how the pill's level signal is computed.
- Speech models and downloads (`docs/models.md`): mlx-audio ignores `language`; download progress is elapsed time, not a percentage; `ModelChoice.hubRoot` must match swift-huggingface's cache rules; setup downloads nothing without a press.
- Polisher (`docs/polisher.md`): prompt framing and `isPlausible` / `isNotInvented` stop the model answering or completing the transcript; the repair pass runs before polishing and only behind the `SpeechRepair` gate; greedy decoding, permissive guardrails, 1,500-character chunks, the 25 s cold-start timeout; the one-word full stop is Parakeet's.
- Custom dictionary (`docs/dictionary.md`): terms are untruncated-Soundex phonetic rules with length and real-word guards; corrections apply longest pattern first.
- UI (`docs/ui.md`): windows float; onboarding re-renders only on `structuralKey()` changes; Settings panes are fixed-height scroll views with a non-flipped clip view; tabs are addressed by `SettingsTab`; the recording pill's meter and column layout.

## Conventions

- No em dashes anywhere: code, comments, docs, UI copy.
- Do not use the word "drift".
- Comments explain *why*, especially where the obvious implementation is wrong. Most comments in this codebase mark a trap; keep them when editing nearby.
- UI copy states the trade-off rather than hiding it in a tooltip. Every control in Settings changes the user's words, so "this rewrites what you said" has to be on screen, not behind a hover nobody performs.
- Reference text is the exception, and it goes behind a `Discloser`, the "?" that folds a `Pane.detail` block open in place. The test is whether the sentence would change the decision: "adds about a second before pasting" would, so it is a `caption`; "a single word needs five letters" would not, since it is read while typing a term in, so it is a `detail`. Not a tooltip, which needs a deliberate hover, cannot be reached from the keyboard and does not survive a screenshot.
- Watch the height of a pane when adding to it. `paneHeight` is 600 and the Text tab already runs past it, which puts the dictionary's buttons below the fold, where the nested scroll view makes them awkward to reach. Adding a four-line caption costs about 60 points of somebody else's reach.

## Releasing

The process, one-time setup, secrets and every release-time trap (changelog parsing, appcast checks, notarization resume, Sparkle key backup) live in `RELEASING.md`. Read it before touching `release.sh` or the workflows. Constraints the code depends on:

- `VERSION` is the single source of truth for the marketing version. `CFBundleVersion` is `git rev-list --count HEAD`; Sparkle compares it, so anything that makes it go backwards strands every installed copy.
- `CHANGELOG.md` is the only place release notes are written; `release.sh` refuses to publish if its top section is missing, empty, or not headed with `VERSION`.
- `release.sh` is the only thing that publishes, and CI calls the same script, so a local release and a CI release cannot diverge. The release skill (`.agents/skills/release/SKILL.md`) drives the steps around it and reimplements none of them, for the same reason.
- Notarization submit and wait stay separate calls (`--resume <id>`); never recombine them into `notarytool submit --wait`.
