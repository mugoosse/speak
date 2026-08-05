# Changelog

Newest first. The top section is the release being cut, and it is the **only**
place its notes are written: `release.sh` reads it for the GitHub release body
and for the "what's new" pane Sparkle shows before an update, and refuses to
publish when its version disagrees with `VERSION`.

A section starts at a heading that is `##` followed by a version number, so
headings inside an entry can be anything that is not one of those.

## 1.3.0 (2026-08-05)

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
