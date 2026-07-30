Push-to-talk dictation for macOS. Press a shortcut, talk, press it again, and
the transcript is on your clipboard. Everything runs on your Mac.

## Install

```sh
brew install --cask mugoosse/tap/speak
```

Or download `Speak-x.y.z.dmg` below, open it, and drag **Speak** to
Applications. Releases are signed and notarized, so there is no Gatekeeper
warning to click through.

Already have Speak? It updates itself. **Check for Updates…** in the menu bar,
or wait: it checks every two days.

## First launch

macOS asks for **Microphone** and **Accessibility**. Both are needed:
Accessibility is what lets a keyboard shortcut work while another app is
focused.

## Requirements

Apple Silicon, macOS 14 or later. macOS 26 for the Apple Intelligence engine.

Parakeet downloads about 2.4 GB the first time you use it. Apple Intelligence
needs no download and works immediately.

## Verifying the download

```sh
shasum -a 256 Speak-x.y.z.dmg          # compare against SHA256SUMS.txt
gh attestation verify Speak-x.y.z.dmg --repo mugoosse/speak
```

---

<!--
Everything above ships with every release. What changed in THIS one is
generated below by `gh release create --generate-notes`, from the commits since
the previous tag. Do not hand-write a changelog here: it would go stale the
moment it was carried into the next release, which is exactly the bug this
file used to have.
-->
