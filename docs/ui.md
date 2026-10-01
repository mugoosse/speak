# UI: windows, onboarding, Settings, recording pill

Covers `Onboarding.swift`, `SettingsWindow.swift`, `TextPane.swift`, `RecordingIndicator.swift`, `Meters.swift` and `MeterDemo.swift`. UI copy rules are in the Conventions section of `AGENTS.md`.

## Windows must float

The app is `LSUIElement`, so it has no Dock icon or app-switcher entry. A window that falls behind a system permission dialog is unrecoverable. Onboarding sets `.floating` and re-activates after each permission prompt.

## Onboarding must never re-render from `updateControls`

`render()` ends by calling `updateControls()`. If `updateControls()` can call `render()`, the two call each other until the stack dies.

That shipped once. `updateControls()` re-rendered whenever the step could advance and any label still began with "○", meaning "a permission just landed, show the tick". On the **Speech model** step both conditions are permanently true while the model downloads: `canAdvance` is `true` there by design, and the pending line always starts with "○". The app hung with a beachball on the first machine that reached that step without the model already cached, which is every new user. It was invisible here because a cached model reaches `.ready` before the step is drawn.

Re-rendering is now driven by `structuralKey()`, a comparison of state rather than a scan of rendered text. The elapsed-time summary is deliberately excluded from that key and its label is updated in place: including it would rebuild the body every 0.8s for the length of the download, replacing the engine radio buttons under the cursor of someone trying to click one. `structuralKey()` must also keep `.idle` distinct from `.downloading` (see `docs/models.md`).

## Settings panes scroll, and a clip view is not flipped

Each `Pane` is a fixed-height `NSScrollView`, because `NSTabViewController` sizes the window to the tallest pane and the window is not resizable. Adding the Text tab pushed the window past the bottom of a laptop screen, taking the buttons with it and leaving no way to reach them.

The stack needs **both** a top constraint to the clip view and a height of at least the clip view's. An `NSClipView` is not flipped, so a document view shorter than it is placed at the *bottom*: with only the top constraint, Permissions hung off the floor of the window. Making the stack fill the height hands the slack to the spacer `buildContents` appends, which is what has always kept a short pane top-aligned.

Keep a pane's content inside `paneHeight` rather than relying on the scrolling. The dictionary table is a scroll view too, and a scroll view inside a scroll view means the wheel moves the table while the page stays put.

## Settings tabs are addressed by name

`SettingsTab`, never a literal index. The menu's "About Speak" used to open tab 4, so inserting a tab above it would have opened Permissions instead.

## The recording pill has to be driven by the microphone, not by a timer

The dot that blinked on a 0.6 s timer answered "is Speak switched on" and nothing else. It looks identical into a muted input, a headset that went back in its case, and a microphone pointed at the wrong edge of the laptop, which are the failures that actually happen. Every shipping dictation app that is any good shows the signal instead, so `Recorder.onLevel` feeds `MeterStyle.waveform` (the default) or `.orb`. How the level is computed and delivered (dB mapping, 32 ms windows, envelope, main-queue ordering) is in `docs/audio-capture.md`.

`--hud-demo` stacks one pill per style on the same microphone, because "is this better" is a question about a moving thing and cannot be answered from a screenshot or from memory of the build before last. That is also why `.pulse` is still in the tree and deliberately not improved: it is the thing being compared against. Launch it with

```sh
open -n -a /Applications/Speak.app --args --hud-demo   # add --fake for no mic
```

`-n` is required, or a running copy swallows the launch and nothing appears. Going through the bundle rather than the binary is required too: the microphone grant belongs to the bundle, and running `Contents/MacOS/Speak` from a shell asks the terminal for its own instead. `--fake` drives it from a synthetic speech envelope and cycles the states, which is the only way to watch the handover from recording to transcribing: real transcription is over before you have looked down.

## One column edge decides the pill's whole layout

A spanning meter (the waveform) hides the word "Listening" while recording, so the timer, the trash button and the status text all share one trailing column, and both the timer and the status text start at its **left** edge. That edge is what the waveform stops against, which is what keeps the strip the same distance from "0:07" as from "Polishing 1/2…" without anything resizing.

Two ways of doing it were tried and are wrong:

- **Shrinking the meter to make room for "Transcribing…".** A width change on a state the user is already watching reads as a glitch rather than as progress.
- **Right-aligning the status text in that column.** The first letter then moves with the string's length, so "Polishing 1/2…" and "Polishing 10/12…" stop the waveform in two different places.

`labelWidth` is measured from the font rather than guessed, because the text is pinned at the left of the column and overflow clips rather than spilling into a margin. It would clip on a machine slow enough to reach "Polishing 10/12…", which is not this one.

`MeterView` has three states and the middle one is the point. `working()` is the microphone closed with the transcriber still busy: it has to keep moving, because a frozen pill reads as a hung app, but nothing it does may look like it is still hearing something. The waveform stops scrolling and a highlight sweeps across what it already captured; the orb switches from a floor under a live level to a slow pulse that is the whole movement.
