## What this changes

<!-- One or two sentences. If it fixes an issue, "Fixes #123". -->

## How it was verified

<!--
There is no test target, so verification is manual and has to be stated.
At minimum, for anything touching audio, the model, or the event tap:

  ./install.sh
  /Applications/Speak.app/Contents/MacOS/Speak --transcribe some.wav

and one real dictation through the shortcut.
-->

- [ ] `./build.sh` succeeds
- [ ] `--transcribe` still prints a correct transcript
- [ ] One real dictation through the shortcut works end to end

## Traps

<!--
CLAUDE.md documents the non-obvious constraints in this codebase: ad-hoc
signing voiding TCC grants, event tap ordering, fn being invisible to NSEvent,
mlx-audio's inert language parameter, audio device selection ordering.

If your change is near one of those, say which and why it still holds.
-->

## Conventions

- [ ] No em dashes in code, comments, docs or UI copy
- [ ] Comments explain *why*, especially where the obvious implementation is wrong
- [ ] UI copy states the trade-off rather than hiding it in a tooltip
