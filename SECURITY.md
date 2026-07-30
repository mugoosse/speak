# Security policy

Speak is maintained by one person. Reports get a response, but not on an
enterprise timetable.

## Reporting

Use [private vulnerability reporting](https://github.com/mugoosse/speak/security/advisories/new)
rather than a public issue. If that is unavailable, open an issue saying only
that you have a security report and asking for a contact address; do not
include details.

## Supported versions

Only the latest release. Speak auto-updates through Sparkle, so an older
version is one update check away from being current.

## What Speak can reach

Speak requires two permissions and makes two kinds of outbound connection.
Both are declared machine-readably in `InternetAccessPolicy.plist`, which
firewall tools such as Little Snitch read.

- **Accessibility.** A modifier chord never arrives as a `keyDown`, so the
  shortcut has to be read from a `CGEventTap`. The tap is `.defaultTap` rather
  than `.listenOnly` because a shortcut containing a character key has to
  swallow that keystroke. It consumes only an exact match; everything else
  passes through untouched.
- **Microphone.** Only while recording.

**Audio never leaves the machine.** Transcription runs locally, on Parakeet via
MLX or on Apple's on-device Speech framework. There is no server, no account,
no telemetry, and no analytics.

The only outbound connections are:

| Host | Purpose |
|---|---|
| `github.com` | Sparkle update check, every two days |
| `huggingface.co` and its CDN | one-time download of the speech model you chose |

## Transcript history

Transcripts are appended to a plaintext JSONL file on disk, so anything you
dictate is readable by anything that can read your home directory. It is not
encrypted. If you dictate secrets, clear the history in Settings.

## Update integrity

Updates are delivered by Sparkle and verified two ways before installation: an
EdDSA signature over the archive, checked against the public key compiled into
the app, and macOS code signing. An update signed by anything other than the
project's key is refused.

Releases are signed with a Developer ID certificate, notarized by Apple, and
carry build provenance attestation. Any published artifact can be checked
against the workflow that produced it:

```sh
gh attestation verify Speak-1.0.0.dmg --repo mugoosse/speak
```

## Out of scope

- An attacker who already has code execution as your user. They can read the
  history file and the model cache directly, without Speak.
- The accuracy of transcription.
