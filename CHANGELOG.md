# Changelog

Newest first. The top section is the release being cut, and it is the **only**
place its notes are written: `release.sh` reads it for the GitHub release body
and for the "what's new" pane Sparkle shows before an update, and refuses to
publish when its version disagrees with `VERSION`.

A section starts at a heading that is `##` followed by a version number, so
headings inside an entry can be anything that is not one of those.

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
