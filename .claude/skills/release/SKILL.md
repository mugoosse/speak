---
name: release
description: Cut and publish a Speak release. Commits and pushes outstanding work, bumps VERSION, writes the CHANGELOG.md entry, then builds, signs, notarizes and publishes through release.sh, and updates the Homebrew cask. Use when the user says /release, "cut a release", "ship a version", "publish 1.4.0", or asks to put a new build out.
---

# Cutting a release

`release.sh` is the only thing that publishes, and CI calls the same script, so
nothing here may reimplement any part of it. A second publisher is a second
thing to keep in agreement, and the two would come apart on the release where
it mattered. Everything below is the work that happens *before* that script
runs, plus the one thing that has to happen after it. `RELEASING.md` is the
reference for the pipeline itself and for one-time setup; read it if something
fails rather than improvising a way past the failure.

Steps 1 to 4 run without asking. Step 5 is the only gate. Do not add gates the
user did not ask for, and do not skip the one that is here.

If the user named a version in the invocation (`/release 1.4.0`), that is the
version. Otherwise propose one in step 3.

## 1. Orient

```sh
git status --short
git rev-parse --abbrev-ref HEAD
cat VERSION
git log "$(git describe --tags --abbrev=0)"..HEAD --format='%s'
```

Stop and say so, rather than continuing, if:

- The branch is not `main`. A release is cut from `main`.
- There are no commits since the last tag **and** nothing is uncommitted.
  There is nothing to release.
- The working tree holds something that should not be committed: credentials,
  an exported Sparkle key, a `history.jsonl` with real dictations in it, a
  large binary, debug leftovers. Say what you found and wait.

## 2. Commit and push

Read the diff before writing anything. Unrelated changes go in separate
commits rather than one omnibus commit.

House style, from `git log`: sentence case, imperative, saying what the change
is for rather than which file moved ("Wait for the microphone to go live
before saying so", not "Update Recorder.swift"). No conventional-commit
prefixes, no `Co-Authored-By`, no generated-with trailer, no em dashes.

Then `git push`. The tree has to be clean before step 6: `release.sh` refuses
to publish a dirty tree, because the tag would otherwise point at something
nobody can rebuild.

## 3. Choose the version

Semver, and Speak is past 1.0, so the major number means something:

- Fixes and copy only: patch.
- Any new behaviour a user would notice: minor.
- Something that stops working the way it did, a setting removed or the macOS
  floor raised: major.

Do not write the file yet. `VERSION` and the changelog entry are written
together in the next step, because a version with no matching changelog
section is a release `release.sh` refuses to publish.

## 4. Write the changelog entry

Add a section to the top of `CHANGELOG.md`, under the preamble and above the
previous version:

```markdown
## 1.4.0 (2026-08-12)
```

Use today's date. A section runs from one version heading to the next, so
headings inside the entry can be anything that is not `##` followed by a
version number.

This text is read twice, both times by somebody who has not seen the commits:
it is the GitHub release body, and it is the pane Sparkle puts in front of a
user deciding whether to take the update. Write it for them.

- Say what changed and what it costs. Every release that touches polishing or
  the dictionary changes the user's own words, and the notes are where that is
  admitted, in the same register the Settings copy uses.
- Measured numbers where there are any, said as measured. "About a second
  before pasting" is worth more than "faster".
- Known limitations belong in it. Something the model still cannot repair is
  more useful to a reader than the list of things it now can.
- No marketing voice, no emoji, no "we are excited to", no em dashes.
- Commits are the input, not the output. Do not paste a list of subject lines:
  `--generate-notes` appends the full commit list under whatever you write.

The 1.3.0 entry is not the model to copy. It is the boilerplate that used to
be re-shipped verbatim as every release's notes, kept because it is what that
release page actually said. From 1.3.1 onwards an entry says what changed in
that build; install instructions live in the README and on the download page,
and repeating them here costs the reader the one thing they came for.

Then write the version:

```sh
echo 1.4.0 > VERSION
```

Commit both together, and push:

```sh
git commit -am "Speak 1.4.0" && git push
```

Do **not** create the tag. `release.sh` tags and pushes the tag itself, and a
tag created here that disagrees with `VERSION` is a failure the script has to
refuse in preflight.

## 5. Confirm, once

Show the user, in one message, before anything is published:

- the version, and the last one
- the changelog entry, in full
- what will be published: the zip, both DMG names, `SHA256SUMS.txt`,
  `appcast.xml`
- that notarization is Apple's queue and has taken over an hour

Then ask whether to publish. This is the only confirmation in the skill, and it
covers steps 6 and 7, so do not ask again inside them. The one exception is
pushing the Homebrew tap, which is a different public repository and is asked
for separately in step 7.

## 6. Publish

```sh
./release.sh --publish
```

**Run it in the background.** The build alone runs about ten minutes and
Apple's notarization queue has taken over an hour, so a foreground call hits
the ten minute tool timeout and looks like a hang. Report progress from the
output rather than starting anything else against the same tree while it runs.

Do not kill it during the notarization wait. If it dies there, the submission
is usually still accepted server-side and the recovery is `./release.sh
--resume <id>`, which the script prints. `--resume` deliberately does not
rebuild: the ticket is keyed to the bundle's cdhash, so a rebuilt bundle
cannot be stapled with it.

Everything it refuses to do is deliberate and none of it should be worked
around. In particular it will not publish a build Gatekeeper rejects, or one
whose changelog does not open on this version.

## 7. Update the Homebrew cask

Two lines change per release, the version and the sha256 of the versioned DMG,
so this cannot happen until the DMG exists. The hash is already in
`dist/SHA256SUMS.txt`; take it from there rather than recomputing it.

The workflow is the route. It needs `HOMEBREW_TAP_TOKEN`, which is set, though
it is a token with an expiry rather than a permanent fact, so check before
dispatching rather than reporting a dispatch that is already dead:

```sh
gh secret list | grep HOMEBREW_TAP_TOKEN
gh workflow run homebrew-tap.yml -f tag=v1.4.0
```

**Watch the run rather than assuming it worked**, and read what it actually
did. It verifies its download against `SHA256SUMS.txt` and asserts both edited
lines are what it just wrote, so a green run means something; but the useful
line is whether it opened a pull request or found nothing to do, and only one
of those is right after a version bump:

```sh
gh run watch <id> --exit-status
gh pr list --repo mugoosse/homebrew-tap
```

It opens a pull request, so **the cask is not updated until that is merged**.
Say so in step 8 with the link. Do not merge it without asking.

If the token has expired, or the run fails, edit the cask by hand instead. The
tap is cloned at `../homebrew-tap`, and `Casks/speak.rb` is the file:

```sh
grep "Speak-1.4.0.dmg" dist/SHA256SUMS.txt
```

Change only `version` and `sha256`. Everything else in that file, the caveats
and the zap stanza in particular, is hand-written and not derivable from a
release. Then verify before pushing, because a wrong hash there is an install
that fails for everyone and nothing local would have caught it:

```sh
cd ../homebrew-tap                           # where the edit was made
TAP="$(brew --repository)/Library/Taps/mugoosse/homebrew-tap"
cp Casks/speak.rb "$TAP/Casks/speak.rb"
brew style mugoosse/tap/speak && brew audit --cask --strict mugoosse/tap/speak
brew fetch --cask mugoosse/tap/speak         # downloads and checks the pinned hash
git -C "$TAP" checkout -- Casks/speak.rb 2>/dev/null || rm -f "$TAP/Casks/speak.rb"
git -C "$TAP" status --short                 # must be empty
```

**Put the tapped clone back, and do not assume which way.** That second-to-last
line is two cases and picking one is wrong half the time. Before the cask has
ever been pushed the copy is untracked there and has to be deleted, because
`brew update` refuses to pull over an untracked file. Once it has been pushed
and any `brew update` has run, the file is tracked, and deleting it stages a
deletion of somebody's tap. `git checkout --` restores the tracked copy and
fails harmlessly when there is nothing to restore, which is why it is tried
first and `rm` is the fallback.

Check the status line is empty either way. A dirty tapped clone is a broken
`brew update` for the user, and nothing else reports it.

Commit as `speak 1.4.0`, matching the tap's history. Ask before pushing the
tap: it is a public repository, and a different one from the release.

## 8. Report

- the release URL
- whether the cask went by workflow or by hand, and whether it is pushed
- anything the run warned about

The download page needs no change: `docs/index.html` links
`releases/latest/download/Speak.dmg`, which is why `release.sh` publishes an
unversioned copy of the DMG beside the versioned one.

## Things that will bite you

- **Never run `swift build`.** It links and then dies at runtime looking for
  the default metallib, because SwiftPM never compiles MLX's Metal kernels.
  `release.sh` calls `build.sh`, which is the xcodebuild wrapper.
- **`CFBundleVersion` is `git rev-list --count HEAD`.** Sparkle compares it to
  decide an update exists, so anything that makes the commit count go backwards
  strands every installed copy. Do not rewrite published history.
- **The Sparkle private key lives in the login keychain.** Losing it ends the
  update channel: an installed copy only accepts updates signed by the key it
  shipped with, so a new key means everyone reinstalls by hand. The backup
  procedure is in `RELEASING.md`.
- **`.github/workflows/release.yml` is dispatch-only on purpose.** Pushing the
  tag does not start CI, and it should not: a local release would otherwise
  start a job that builds for ten minutes, finds no signing secrets and mails a
  failure for a release that succeeded.
- **Do not hand-write notes anywhere but `CHANGELOG.md`.** The GitHub release
  body and the appcast description both come from its top section, and a second
  copy is the bug the old `RELEASE_NOTES.md` had: it was carried into every
  release unchanged, so the update pane described the app rather than the build.
