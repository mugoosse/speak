<p align="center">
  <img width="110" alt="Speak red monkey app icon" src="Assets/icon.png" />
</p>

<h1 align="center">Speak</h1>

<p align="center"><b>Talk instead of typing. Anywhere on your Mac.</b></p>

<p align="center">
  <a href="https://github.com/mugoosse/speak/actions/workflows/build.yml"><img src="https://github.com/mugoosse/speak/actions/workflows/build.yml/badge.svg" alt="Build" /></a>
  <a href="https://github.com/mugoosse/speak/releases/latest"><img src="https://img.shields.io/github/v/release/mugoosse/speak?color=2563eb" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/macOS%2014%2B-Apple%20Silicon-111827" alt="macOS 14+, Apple Silicon" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/licence-AGPL%203.0-2563eb" alt="AGPL 3.0" /></a>
</p>

<p align="center">
  <img src="Assets/demo.gif" width="640" alt="Pressing the shortcut, speaking, and the text appearing in another app" />
</p>

Press a shortcut, say what you mean, press it again. Your words appear in
whatever app you are already in: an email, Slack, a search bar, a code comment.

Free, no account, and your voice never leaves your Mac. **There is no account
because there is no server.** That is the whole app.

Speak is the red half of the Good Pair: a speaking monkey with its hands around
an open mouth. In the menu bar, it uses the Good Pair's square speaking seal,
carrying 言 (speak), so the family resemblance remains clear at 16 points.

## Download

### **[Download Speak for macOS](https://github.com/mugoosse/speak/releases/latest/download/Speak.dmg)**

Open the downloaded file and drag **Speak** to Applications. It is signed and
notarized by Apple, so it opens normally, with no "unidentified developer"
warning to click through.

### Other ways to install

Prefer Homebrew?

```sh
brew install --cask mugoosse/tap/speak
```

Homebrew installs update with `brew upgrade --cask speak` rather than through
the in-app updater. The two do not fight.

### What you need

- **A Mac with Apple silicon**, meaning an M1 or newer, so any Mac sold since
  late 2020. There is no Intel version.
- **macOS 14 or later.** The Apple Intelligence engine, and the optional
  [AI polish](#polish) pass, additionally need macOS 26.
- **About 5 GB free**, for the speech model, if you choose Parakeet. You can
  skip that entirely by choosing Apple Intelligence instead.

### First run

A setup window walks through it. Speak asks for two permissions:

1. **Microphone**, so it can hear you.
2. **Accessibility**, so your shortcut works while you are in another app.

Then it asks which speech model to use. **Nothing is downloaded until you have
chosen one and pressed the button that names it**, so a 2.4 GB Parakeet is
never fetched on the assumption that you wanted the default. The download takes
a few minutes on a normal connection, and it is the only time Speak uses the
internet: once the model is on disk you can turn the wifi off and it still
works. Apple Intelligence needs no download at all.

If the shortcut does nothing afterwards, see
[Troubleshooting](#troubleshooting). There is one common macOS quirk with a
one-line fix.

## How fast

About **35 ms** to turn a 6-second sentence into text, measured warm on an
M4 Max. In practice the words are on screen before you have finished letting
go of the key.

Most people speak at around 150 words a minute and type at around 40.

## Why nothing leaves your Mac

Speak downloads a speech model once and then runs it on your own hardware,
using Apple's MLX framework. Transcription never touches the network, so there
is nothing to log in to, nothing to subscribe to, and no server that could hold
your recordings even in principle.

The optional [AI polish](#polish) pass does not change that. It uses the model
built into macOS, which runs on your Mac like everything else here, so a
polished transcript has still never left the machine.

The trade is honest and worth stating: when a local model gets a word wrong,
it is wrong. There is no cloud fallback to catch it. See
[Limitations](#limitations) for the rest of what Speak deliberately will not do.

---

# Manual

Everything below is reference. You do not need any of it to use Speak.

[Use](#use) ·
[Engines](#engines) ·
[Polish](#polish) ·
[Dictionary](#dictionary) ·
[Punctuation](#punctuation) ·
[Shortcut](#shortcut) ·
[Microphone](#microphone) ·
[History](#history) ·
[Updating](#updating) ·
[Troubleshooting](#troubleshooting) ·
[Uninstalling](#uninstalling) ·
[Config](#config) ·
[Disk use](#disk-use) ·
[Building from source](#building-from-source) ·
[Design](#design) ·
[Limitations](#limitations) ·
[Contributing](#contributing)

## Use

Press **fn + ⇧ left** (the default) to start, speak, press again to stop. The
transcript is pasted into whatever is focused and stays on the clipboard, so
⌘V works too. Turn off **Paste automatically** in Settings to only copy.

Optionally the transcript is [polished](#polish) and run through your
[dictionary](#dictionary) first. Both are off until you set them up.

The menu bar icon tracks state:

| Icon | Meaning |
|---|---|
| the Good Pair speaking seal | ready |
| the Good Pair speaking seal, crossed out | loading the model, or setup unfinished |
| the Good Pair speaking seal, inverted in a filled square | recording |
| hourglass | transcribing |
| download arrow | fetching the model, with elapsed time |
| warning triangle | see the menu for what went wrong |

The mark is the Good Pair's speaking seal, carrying 言 (speak). Listen carries
the matching 聞 (hear) seal: together they reference the Japanese roots of the
three wise monkeys without trying to shrink either mascot into 16 points.
Clicking it names the app at the top of the menu.

A small floating pill says the same thing on screen, where you are actually
looking: **Listening** with a red dot and a running timer, then **Transcribing…**,
then **Polishing…** if that is switched on. A dictation long enough to be split
into several requests counts them off, **Polishing 2/4…**, so a long wait is
visibly progress rather than a hang. Turn the pill off in Settings → General.

## Engines

Choose in **Settings → Model**, or during setup.

| Engine | Trade-off |
|---|---|
| **Parakeet v2** (default) | English only · most accurate · 2.47 GB download |
| **Parakeet v3** | 25 languages · may misdetect short clips · 2.51 GB download |
| **Apple Intelligence** | Built in · no download · ready immediately · less accurate |

Setup downloads nothing until you pick one, and neither does switching here: the
button names the engine and its size, and it is the only thing that starts a
transfer.

### The 25 languages

Parakeet v3 recognises these, and detects which one you are speaking on its own.
**Settings → Model → Show the 25 languages** lists them in the app too, and so
does the setup step where you choose.

Bulgarian · Croatian · Czech · Danish · Dutch · English · Estonian · Finnish ·
French · German · Greek · Hungarian · Italian · Latvian · Lithuanian · Maltese ·
Polish · Portuguese · Romanian · Russian · Slovak · Slovenian · Spanish ·
Swedish · Ukrainian

Note that Irish is not among them, so this is not simply the EU's official
languages. If yours is missing, Apple Intelligence covers a different set, which
its own Language picker lists.

### Where the Parakeet model comes from

[Parakeet TDT](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) is NVIDIA's
speech recognition model, released under CC-BY-4.0. Speak uses the MLX
conversions published by the [mlx-community](https://huggingface.co/mlx-community)
project, which repackage the NeMo weights to run on Apple Silicon:

| Engine | Repository |
|---|---|
| Parakeet v2 | [`mlx-community/parakeet-tdt-0.6b-v2`](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2) |
| Parakeet v3 | [`mlx-community/parakeet-tdt-0.6b-v3`](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3) |

They are fetched from Hugging Face the first time you select one, by
[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) via
[swift-huggingface](https://github.com/huggingface/swift-huggingface). No
account or token is needed; both repositories are public.

**That download is the only time Speak touches the network.** Transcription
never does, so once the model is on disk the app works offline. Apple
Intelligence never downloads anything through Speak, since its assets are
managed by macOS.

Settings > Model links to the exact repository in use.

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

## Polish

**Settings → Text → Polish transcripts with Apple Intelligence.** Off by
default.

Speech recognition writes down what you said. It does not know that "um" was
not a word, that you started the sentence twice, or where the full stops go.
Polishing hands the transcript to Apple Intelligence's on-device model, which
punctuates it, drops fillers and false starts, and splits a long dictation into
paragraphs.

    um so i think we should uh basically try the the parakeet
    model and see if it you know works better

    So I think we should basically try the Parakeet model and
    see if it works better.

**Needs macOS 26 and Apple Intelligence switched on.** The checkbox says which
of those is missing when it cannot run. Nothing else changes: corrections below
still work, and so does dictation.

It costs about a second on a normal dictation, which is why it is a choice
rather than the default. **Style notes** in the same pane is free text passed
to the model ("prefer short sentences"). It shapes how the result reads and
cannot make the model add content or answer what you dictated.

Still local. The model is part of macOS and runs on your Mac, so polishing adds
no network traffic and nothing to log in to.

### When polishing does nothing

A transcript is passed through unchanged, rather than lost, whenever the model
fails, refuses, takes too long, or returns something implausible. Speak also
skips polishing above 8,000 characters, roughly ten minutes of talking, because
the wait would be longer than rereading it yourself.

The last check is worth knowing about, because it is what keeps a dictated
question a question. A small model asked to tidy up "what time is the meeting
tomorrow, can you let me know" will sometimes answer it instead, inventing a
time. Speak compares the length of the reply with the length of the transcript
and throws away anything that collapsed, on the grounds that tidying up does not
make text three times shorter. Whatever the model did, the words you actually
said are what reach the clipboard.

Both halves are recorded: when polishing or a correction changes a transcript,
the original is kept in the history file under `raw`, and the History pane shows
it in the row's tooltip.

## Dictionary

**Settings → Text → Dictionary.** Two kinds of entry, because names come out
wrong in two different ways.

**Terms** are words Speak should know: names, product names, jargon, domains.
They do two jobs.

*Sounds-like correction.* Anything you dictate that sounds like a term is
replaced with it. One entry for "Goossens" catches "Gossens", "Goosens",
"Gaussens" and "Gusens"; one for "flyinpublic.com" catches "Flamepublic.com";
one for "Claude Code" catches "Cloud coat". No model is involved, so this works
with polishing off, on macOS 14, and when polishing fails.

It compares the consonants and ignores the vowels, which is where mishearings
differ. What keeps it safe depends on the length of the term:

- **A single word** needs at least five letters, so short entries like "R2" are
  left alone, and it will never replace a word that is already English: a term
  of "Codex" does not turn "codes" into "Codex".
- **A phrase** needs every word to match in sequence, which is a far stronger
  signal, so it is allowed to replace ordinary words. That is the only way to
  fix "Cloud coat", which is two perfectly good English words and still
  obviously a misheard "Claude Code".

*Spelling hints.* Terms are also given to the polishing model, which stops it
rewriting words it does not recognise. Measured over six runs each,
"flyinpublic.com" survived polishing 0 times out of 6 without a hint and 5 out
of 6 with one. Worth adding for any word you dictate often, even one the
microphone always gets right. The first 600 characters of enabled terms are
sent, from the top of the list.

**Corrections** are exact replacements, for a mishearing that sounds nothing
like the word you meant and so cannot be caught by a term: "Chrome Drops" for
"cron jobs", "Dusk Warrior" for "Taskwarrior". A correction whose text is a word
matches whole words only, so "cat" leaves "category" alone; anything else
matches anywhere.

**The longest match wins.** With rules for both "maxim" and "maxim Gusens", the
full name is corrected as a unit rather than being half-fixed into "Maxime
Gusens" by the shorter rule and then left unmatchable. Equal-length rules apply
in list order.

Corrections run **on both sides of polishing**, and each pass earns its keep.
Running first means the rules see the raw transcript they were written against,
and the model is handed the right proper nouns rather than guessing at a word it
does not know. Running again afterwards means a replacement you asked for is the
final word rather than something the model is free to revert.

Polishing can still alter a corrected term in between: if it respells one, the
second pass no longer recognises it. That is one more reason the raw transcript
is kept in the history file.

Stored as JSON at `~/Library/Application Support/speak/dictionary.json`, so it
can be edited by hand or kept in a dotfiles repo.

### Import and export

**Import…** merges a file into what you already have rather than replacing it,
skipping entries that are already present, so importing the same file twice is
harmless. **Export…** writes the whole dictionary out for a backup or another
Mac.

Import reads Speak's own exports and
[TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac)'s, which uses a
bare array and different field names (`type`, `original`, `isEnabled`). Terms
and corrections both arrive whichever tab you are looking at.

## Punctuation

A dictation of four words or fewer does not get a full stop on the end.

The speech model punctuates as it transcribes and treats every recording as a
sentence, so dictating a single word would otherwise give you "Tomorrow." rather
than "Tomorrow". That is correct for prose and wrong for a search box, a form
field, a file name or a spreadsheet cell, and a full stop is a character you can
type if you want one.

This is the speech engine's doing rather than the [polishing](#polish) pass, so
it happens whether or not polishing is on. There is no setting: it has an
answer, so Speak does not ask.

Only a full stop is dropped, and only when the whole dictation is one short
fragment. Question marks and exclamation marks are always kept, because they
change what the words say. Anything with a sentence break in it counts as prose
whatever its length, though a full stop inside a domain does not count, so
"flyinpublic.com." still loses its final one.

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

`text` is what was pasted. When [polishing](#polish) or a
[correction](#dictionary) changed it, a `raw` field holds the transcript as the
speech engine produced it. The key is absent when nothing changed it, so the
file does not carry two copies of every line.

**Settings → History** lists them all: double-click a row to copy, or reveal the
file. Hovering a row shows the original when it differs. The menu bar shows the
last five.

JSONL rather than a database so it stays greppable and outlives the app:

```sh
jq -r .text ~/Library/Application\ Support/speak/history.jsonl
```

Delete the file to clear it. Nothing is sent anywhere.

## Updating

Speak checks for updates every two days and offers them through
[Sparkle](https://sparkle-project.org). **Check for Updates…** in the menu bar
does it on demand, and **Settings → About** has the same button along with the
answer the last check gave, the time it ran, and a switch for the scheduled
ones. Each update is verified twice before it installs: an EdDSA signature over
the archive, checked against a public key compiled into the app, and macOS code
signing. An update signed by anything else is refused.

Homebrew installs update the usual way instead, and the two do not fight:

```sh
brew upgrade --cask speak
```

Speak starts at login by default on a new installation. Change this at any time
under **Settings → General → Start Speak at login**. If macOS needs approval,
Speak links directly to System Settings → General → Login Items.

If you build from source, `./install.sh` quits the old copy, replaces it and
relaunches. Permissions survive because `make_app.sh` signs with a stable
identity.

## Troubleshooting

### Speak is listed in Accessibility but the shortcut does nothing

Remove it with the minus button and add it again. macOS keeps a stale entry
after an app is replaced, and that stale entry is the single most common reason
a working install stops responding.

### The fn key does nothing, or opens the emoji picker

macOS may be reserving fn for the emoji picker. Set System Settings → Keyboard
→ "Press 🌐 key to" → **Do Nothing**, or:

```sh
defaults write com.apple.HIToolbox AppleFnUsageType -int 0
```

Log out and back in for it to take effect.

### Working out whether it is the model or the shortcut

```sh
/Applications/Speak.app/Contents/MacOS/Speak --transcribe some.wav
```

Transcript to stdout, timings to stderr, no permissions needed. If that works,
the model is fine and the problem is the shortcut. `SPEAK_DEBUG=1` traces every
modifier change to stderr.

The [polishing](#polish) pass and the [dictionary](#dictionary) can be run the
same way, on text rather than audio:

```sh
echo "um so i think it works" | /Applications/Speak.app/Contents/MacOS/Speak --polish -
/Applications/Speak.app/Contents/MacOS/Speak --transcribe some.wav | \
    /Applications/Speak.app/Contents/MacOS/Speak --polish -
```

Reads an argument or stdin, prints the result to stdout, and reports on stderr
why it did nothing if polishing is unavailable.

## Uninstalling

Quit Speak from the menu bar, then drag **Speak** from Applications to the
Trash. Or:

```sh
brew uninstall --cask speak
```

That is genuinely all most people need. It leaves three small things behind.

**Remove the permission entries.** System Settings → Privacy & Security →
**Accessibility**, select Speak, click **−**. Same under **Microphone**.

This is the one worth doing. macOS keeps the entry after the app is gone, and a
stale entry is the single most common reason a reinstalled Speak looks
installed but the shortcut does nothing. Removing it now saves confusion later.

**Delete the settings and history**, if you would rather not leave transcripts
on disk:

```sh
rm -rf ~/Library/Application\ Support/speak        # transcript history
rm -f  ~/Library/Preferences/com.mgo.speak.plist   # settings and shortcut
rm -rf ~/Library/Caches/com.mgo.speak              # update cache
```

`brew uninstall --zap --cask speak` does the same three in one step.

**Delete the model**, if you want the 4.6 GB back. It lives in the shared
Hugging Face cache, so delete the two Parakeet directories rather than the
cache itself, which probably holds other things:

```sh
rm -rf ~/.cache/huggingface/hub/models--mlx-community--parakeet-tdt-0.6b-v*
rm -rf ~/.cache/huggingface/hub/mlx-audio/mlx-community_parakeet-tdt-0.6b-v*
```

Both paths are the same model stored twice; see [Disk use](#disk-use). Apple
Intelligence leaves nothing behind, as its assets belong to macOS.

Finally, remove Speak from Login Items if it still appears there: System
Settings → General → Login Items.

## Config

Environment variables override the UI, for one-off runs:

| Variable | Default | Meaning |
|---|---|---|
| `SPEAK_MODEL` | unset | force a model repo; disables the Model picker |
| `SPEAK_AUTOPASTE` | unset | `1` forces the ⌘V press on, even if Settings has it off |
| `SPEAK_POLISH` | unset | `1` forces polishing on, `0` forces it off |
| `SPEAK_DEBUG` | unset | `1` traces every modifier change to stderr |

## Disk use

Parakeet is stored **twice**, about 4.6 GB total: once in the Hugging Face blob
cache (`~/.cache/huggingface/hub/models--…`) and once in mlx-audio's own
directory (`~/.cache/huggingface/hub/mlx-audio/…`). That duplication is
mlx-audio's design, not something Speak controls.

If you have set `HF_HUB_CACHE` or `HF_HOME`, the models go there instead, and
Speak follows: Settings → Model names the directory actually in use.

Apple Intelligence adds nothing of its own; its assets are system-managed and
usually already present because system dictation uses them.

## Building from source

Only needed to develop Speak; the releases above are prebuilt.

```sh
./build.sh      # xcodebuild wrapper
./make_app.sh   # wrap the binary in a signed .app
./install.sh    # both, then install to /Applications and relaunch
swift make_icon.swift            # regenerate Assets/icon.png and Assets/Speak.icns
swift make_social_preview.swift  # regenerate Assets/social-preview.png
```

`swift build` alone is **not** enough. It links successfully and then dies at
runtime with `Failed to load the default metallib`, because SwiftPM never
compiles MLX's Metal kernels. Two further wrinkles, both handled by `build.sh`:

- Xcode 26 ships the Metal compiler as a separate downloadable component.
- mlx-swift ships a `CudaBuild` plugin Xcode refuses to run unattended, hence
  `-skipPackagePluginValidation`. It is a no-op on Apple Silicon.

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

This is also why Accessibility is not an optional permission: a modifier chord
never arrives as a `keyDown`, so it has to be read from a low-level event tap,
which macOS only allows for trusted apps.

### Download progress is elapsed time, not a percentage

`URLSession.download` streams the weights into a system temp path and only moves
the finished file into the cache, so nothing observable grows while the large
file is in flight. A directory-derived percentage sits at 0% for the whole
download and then jumps to 100%, which reads as hung. Elapsed time is less
informative but true.

## Limitations

Stated up front rather than discovered later. Most of these are decisions, not
gaps, but they are still things Speak will not do for you.

**Apple Silicon only, macOS 14 or later.** MLX is Metal-based and has no Intel
path. The Apple Intelligence engine additionally needs macOS 26.

**No language picker for Parakeet.** mlx-audio accepts a `language` parameter,
copies it into its output struct, and never passes it to the decoder. A picker
would be a control that silently does nothing, so there isn't one. The default
is the English-only v2 for the same reason: multilingual v3 decodes short
English clips as Cyrillic often enough to be a problem.

**Download progress is elapsed time, not a percentage.** Not a stylistic
choice; nothing observable grows during the transfer. Explained
[above](#download-progress-is-elapsed-time-not-a-percentage).

**No streaming partial results.** You get the transcript when you stop talking,
not as you speak. Parakeet transcribes a complete utterance.

**The speech engines cannot be taught new words.** Neither Parakeet nor
`SpeechTranscriber` exposes a vocabulary or hotword API, so a name is misheard
first and repaired afterwards, in the text. [Terms](#dictionary) catch the
mishearings that sound like the word you meant; anything further off needs a
[correction](#dictionary) naming it.

**Polishing is a small model and can be wrong.** It occasionally rewrites a
technical term, or leaves fillers it was asked to remove. It is off by default,
it never replaces a transcript it failed to improve, and the original stays in
the history file under `raw`. It also covers fewer languages than Parakeet v3's
25; where it is out of its depth the transcript passes through unchanged.

**No cloud fallback, ever.** When the local model is wrong, it is wrong. That
is the trade for audio never leaving the machine. Polishing is local too, so it
is not that fallback.

**Text is inserted with a synthetic ⌘V, not typed at the cursor.** Some apps
ignore a synthetic keystroke, and the paste lands wherever focus happens to be.
The transcript is always on the clipboard as well, and **Paste automatically**
in Settings turns the keystroke off.

**Transcripts are stored in plaintext.** The history file is unencrypted JSONL
in your home directory. Clear it in Settings if you dictate anything sensitive.

**Parakeet takes about 4.6 GB on disk**, not 2.4 GB, because mlx-audio keeps
its own copy alongside the Hugging Face cache. See [Disk use](#disk-use).

## Contributing

Pull requests welcome. There is no test target, so verification is manual and
has to be stated in the PR: `./build.sh`, then `--transcribe` on a real file,
then one dictation through the shortcut.

`CLAUDE.md` documents the traps in this codebase, all of which were found the
hard way. Read the one nearest your change before you make it.

- [RELEASING.md](RELEASING.md), how a release is cut
- [SECURITY.md](SECURITY.md), what Speak can reach and how to report a problem

## Credits

Made by [Maxime Goossens](https://maxgoespublic.com/).

Speech models are [Parakeet TDT](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2)
by NVIDIA (CC-BY-4.0), converted for Apple Silicon by
[mlx-community](https://huggingface.co/mlx-community) and run through
[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) and
[mlx-swift](https://github.com/ml-explore/mlx-swift). Apple Intelligence
transcription uses the Speech framework built into macOS.

## License

Copyright (C) 2026 Maxime Goossens.

Speak is free software under the [GNU Affero General Public License v3.0](LICENSE).
You may use, study, modify and redistribute it, and any distributed derivative
must also be AGPL 3.0 and ship its source.
