# Changelog

Newest first. The top section is the release being cut, and it is the **only**
place its notes are written: `release.sh` reads it for the GitHub release body
and for the "what's new" pane Sparkle shows before an update, and refuses to
publish when its version disagrees with `VERSION`.

A section starts at a heading that is `##` followed by a version number, so
headings inside an entry can be anything that is not one of those.

## 1.5.0 (2026-08-07)

### The recording indicator now shows what the microphone is hearing

The pill used to blink a red dot on a timer. That said Speak was switched on
and nothing more, and it looked exactly the same into a muted input, a headset
that had gone back in its case, or a microphone pointed at the wrong edge of
the laptop. Recording and hearing you are different claims, and only the second
one goes wrong.

It now draws the sound instead. The default is a waveform of the last two
seconds, scrolling, which is the only version that still shows a gap after it
has passed: if it missed the start of a sentence, that is visible a beat later,
when you actually think to check. **Settings → General** offers a quieter orb
instead, one dot that grows and brightens with your voice on a narrower pill,
or turns the indicator off as before.

The waveform takes the pill over while you talk, so the word "Listening" is
gone from it. A waveform moving with your own voice says that more precisely
than the word did.

Neither style freezes once you let go. The waveform stops scrolling and a
highlight sweeps across what it captured while the transcript is being made;
the orb changes to a slow pulse. Both are deliberately different from how they
look while the microphone is open, because by then it is closed.

### Cancel is now a trash button

The **Cancel** button added in 1.4.0 is a trash icon at the right-hand end of
the pill. It does the same thing, stops the dictation without transcribing it
or changing the clipboard, and it still works when another app is holding
secure input and Escape cannot reach Speak. It is dim until you point at it.

The word was worth about a third of the pill's width, and the waveform wanted
it. Hover it, or read the tooltip, if the icon alone is not enough.

## 1.4.0 (2026-08-06)

### Cancel a recording even when Escape cannot reach Speak

The recording indicator now has a **Cancel** button. It stops the current
dictation without transcribing it or changing the clipboard.

This matters when another app has turned on secure input. macOS can still let a
modifier-only shortcut start recording while withholding ordinary keys such as
Escape from Speak. Escape works again after the responsible app releases secure
input. Until then, the on-screen Cancel button uses the mouse, which secure
input does not block.

Speak still does not try to bypass macOS keyboard protection. The menu names the
app holding secure input and now says that keyboard input may not reach Speak,
rather than promising that every part of the shortcut is unavailable.

## 1.3.1 (2026-08-06)

### Speak now says when something else is swallowing your keyboard

If the shortcut suddenly does nothing, open the Speak menu. When another app
has turned on secure input, the menu now names it and says the chord cannot
reach Speak until it is off.

Secure input is the macOS feature that keeps keyloggers away from the keyboard,
and at the level it works on, a shortcut listener is a keylogger. Measured with
a test tap and a synthesized keystroke: seen once with secure input off, and not
at all with it on. So the shortcut was not failing, it was never arriving, and
Speak had no way to know it had been pressed. The icon stayed ready, the menu
went on saying the chord toggles dictation, and nothing happened.

Terminal has it as a setting, Secure Keyboard Entry, which stays on until you
untick it. More often it is an app that turns it on for a password field and
does not turn it off again, and then holds it until you quit that app.

Speak cannot work around this and should not: an app that could read your
keystrokes through secure input would be the thing the feature exists to stop.
Naming it is the whole fix, and it is enough, because the hard part was never
turning it off, it was knowing that was what happened.

The menu is checked only when you open it. Secure input goes on for a moment
every time anybody types a password, so an app that watched it continuously
would spend most of its time warning you about nothing.

## 1.3.0 (2026-08-05)

An appearance release. Dictation, the engines and the dictionary are untouched,
so a transcript from this build is the same transcript 1.2.0 produced.

### The menu bar icon is Speak's own

The steady states, ready and idle and recording, are now Speak's monkey drawn
as a monochrome template rather than a stock microphone symbol. A microphone in
the menu bar says a microphone is involved, which is true of several things
running up there; this says which app it is.

The exceptional states stay on system symbols on purpose. A download arrow and
a warning triangle are understood instantly, and branding them would trade a
legible meaning for a recognisable one, which is the wrong way round when
something has gone wrong or somebody is waiting.

### The mascot appears where the app is otherwise empty

The welcome and finish steps of setup, and the History pane before there is any
history in it. Nowhere persistent: a status item is about status.

Everything else was the website and the README.
