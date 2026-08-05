# Changelog

Newest first. The top section is the release being cut, and it is the **only**
place its notes are written: `release.sh` reads it for the GitHub release body
and for the "what's new" pane Sparkle shows before an update, and refuses to
publish when its version disagrees with `VERSION`.

A section starts at a heading that is `##` followed by a version number, so
headings inside an entry can be anything that is not one of those.

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
