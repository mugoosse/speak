# Releasing Speak

Speak is a notarized, Sparkle-updating macOS app distributed as a DMG and a
Homebrew cask. This file is the whole process, including the parts that only
have to be done once.

## Cutting a release

Releases are cut locally, from a machine holding the signing certificate, the
notarytool profile and the Sparkle key.

`/release` is the shortcut, and it does all of the below: commits and pushes
what is outstanding, bumps `VERSION`, writes the changelog entry, asks once,
then publishes and dispatches the cask. It lives in
`.claude/skills/release/SKILL.md`. By hand:

```sh
$EDITOR CHANGELOG.md                   # a '## 1.0.3 (2026-08-12)' section on top
echo 1.0.3 > VERSION
git commit -am "Speak 1.0.3"
git push
./release.sh --publish
gh workflow run homebrew-tap.yml -f tag=v1.0.3
```

`--publish` tags, pushes the tag, builds, signs, notarizes and staples both the
app and the DMG, signs the appcast, creates the GitHub release and uploads
every asset. Without it, `./release.sh` builds and packages into `dist/` and
publishes nothing, which is the way to check a build before committing to it.

Do not tag by hand. `release.sh` tags and pushes the tag itself, and it refuses
to publish when the tag and `VERSION` disagree, because a release named
`v1.0.3` containing `Speak-1.0.2.dmg` is worse than a failed build. It also
refuses a dirty working tree, since a tag pointing at uncommitted work cannot
be rebuilt.

The Homebrew cask lives in a separate repository and is updated after the
release exists. See [Homebrew](#homebrew) below.

### Why not CI

`.github/workflows/release.yml` is complete and does the same work by calling
the same script, so the two cannot diverge. It is `workflow_dispatch`-only and
**none of the signing secrets are set**, so it will not sign, notarize or
publish anything as things stand. The one secret the repository does hold is
`HOMEBREW_TAP_TOKEN`, which the cask workflow needs and which grants nothing
here.

That is a choice, not an oversight: it keeps the Developer ID certificate, the
notarization password and the Sparkle private key off GitHub. The cost is that
releasing needs the right Mac. To move to CI, set the six remaining secrets
listed under [Repository secrets](#repository-secrets) and dispatch the
workflow with an existing tag.

### When notarization stalls

Apple's queue is unpredictable; over an hour on a first submission from a new
Developer ID account is normal, and the connection can drop while waiting.
`release.sh` splits submit from wait for exactly this reason, so a dropped
connection costs a retry of the wait rather than the whole upload.

```sh
xcrun notarytool history --keychain-profile speak-notary   # find the id
./release.sh --resume <submission-id>
```

## The changelog is the only place release notes are written

`CHANGELOG.md`, newest section first, each section starting `##` followed by a
version number. `release.sh` extracts the top one and uses it twice: as the
GitHub release body, and as the description embedded in the appcast, which is
the "what's new" pane Sparkle shows before an update. There is no second file
to keep in agreement.

That is what `RELEASE_NOTES.md` used to be, and it was overwritten rather than
appended to, so nothing accumulated and its boilerplate went out unchanged with
every release. `git log --follow CHANGELOG.md` reaches back through it.

Three things `release.sh` refuses in preflight, before a ten-minute build
rather than after it: no `CHANGELOG.md`, a top section whose version is not
`VERSION`, and a top section that is empty. The middle one is the one that
matters. A changelog left at the previous version publishes the previous
release's notes under this one's name, and nothing anywhere reports it: the
release page reads perfectly well, it just describes a different build, and so
does the pane every user decides on.

A section ends at the next heading that is `##` followed by a version number,
rather than at the next `##` of any kind, so an entry can carry sub-headings at
whatever level reads best, `##` included. The boilerplate this replaced had
four of them at `##`, and a parser keyed on heading level would have published
its first paragraph and dropped the rest.

### Sparkle needs the notes embedded, not linked

`generate_appcast` embeds a release-notes file only when it is HTML. Given the
`.md` a changelog produces it emits a `<sparkle:releaseNotesLink>` instead,
and, measured against Speak's own 1.3.0 archive, that link is
`releases/latest/download/Speak-1.3.0.md`, a file no release uploads. Every
updater would have fetched a 404 into the pane. With `--embed-release-notes` it
becomes `<description sparkle:format="markdown">` inside the feed, and there is
no second file to keep published.

Every feed up to and including 1.3.0 carried no description at all, so the only
thing an updater was given to decide on was a version number.

### An unsigned or absent feed is not a warning

`--publish` refuses three things about the appcast, all of which used to print
a warning and publish anyway: `generate_appcast` missing, `generate_appcast`
failing, and a feed that comes back with no `edSignature`. The first two end
with no `appcast.xml` among the release assets, so
`/releases/latest/download/appcast.xml` answers 404 to every installed copy
that checks. The third publishes a feed every copy refuses, since an unsigned
update is an arbitrary-code-execution channel and Sparkle treats it as one.
None of the three is visible from here: the release page looks complete, and
the only symptom is nobody updating.

`generate_appcast` is looked for under `.xcbuild/SourcePackages/artifacts`
before `.build/artifacts`. `build.sh` fills the first; the second only exists
if someone ran `swift build`, which this project tells people not to do. A
machine that has only ever followed the documented path has no
`.build/artifacts` at all, which is precisely when the missing-tool warning
used to fire.

## Two version numbers

| Field | Value | Source |
|---|---|---|
| `CFBundleShortVersionString` | `1.0.1` | the `VERSION` file |
| `CFBundleVersion` | `12` | `git rev-list --count HEAD` |

The build number is derived from the commit count, so it always increases
without anyone maintaining it. Sparkle compares `CFBundleVersion` to decide
whether an update exists, so it going backwards would strand every user.

## What ships

| Asset | Why |
|---|---|
| `Speak-x.y.z.dmg` | drag-to-Applications install, what the cask downloads |
| `Speak.dmg` | the same file under a fixed name, so `/releases/latest/download/Speak.dmg` is a permanent link. The versioned name stays: the cask pins a sha256 to it |
| `Speak-x.y.z.zip` | the Sparkle update archive, no mounting step |
| `appcast.xml` | the Sparkle feed, signed |
| `SHA256SUMS.txt` | so a download can be verified without trusting a terminal |

The Sparkle feed URL is
`https://github.com/mugoosse/speak/releases/latest/download/appcast.xml`.
`/releases/latest/download/` always redirects to the newest published release,
so there is nothing separate to deploy and the feed can never describe a
release that does not exist.

## One-time setup

### Developer ID certificate

Notarization needs a **Developer ID Application** certificate, not the Apple
Development one Xcode creates by default. Xcode, Settings, Accounts, Manage
Certificates, +, Developer ID Application.

On an organization team only the Account Holder can create one. If the button
errors with "Unable to process request - PLA Update available", the Account
Holder has to accept the updated Program License Agreement at
[developer.apple.com/account](https://developer.apple.com/account) first; every
certificate operation fails until they do.

Check it took:

```sh
security find-identity -v -p codesigning | grep "Developer ID"
```

### Notarization credentials

```sh
xcrun notarytool store-credentials speak-notary \
  --apple-id you@example.com --team-id BUZ45YDWYN --password <app-specific-password>
```

The password is an app-specific one from
[account.apple.com](https://account.apple.com), Sign-In and Security,
App-Specific Passwords. Not the Apple ID password. The profile name must be
`speak-notary`; `release.sh` looks for exactly that.

### Sparkle signing key

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

Stores the private key in the login keychain and prints the public key, which
goes in `make_app.sh` as `SPARKLE_PUBLIC_KEY` and ends up in `Info.plist` as
`SUPublicEDKey`.

**Losing the private key ends the update channel.** Every installed copy will
only accept updates signed by the key it shipped with, so a new key means every
existing user has to reinstall by hand. Back it up:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.txt
```

Store that in a password manager, then delete the file.

### Repository secrets

`HOMEBREW_TAP_TOKEN` is set. **None of the other six are, and a local release
needs none of them.** They are listed for whoever decides to move releasing
into CI. Without them the workflow still builds and produces unsigned artifacts
rather than failing, which is what lets a fork build with no setup at all.

| Secret | Set | How to get it |
|---|---|---|
| `HOMEBREW_TAP_TOKEN` | yes | fine-grained PAT with contents:write and pull-requests:write on `mugoosse/homebrew-tap`, and nothing else |
| `SIGNING_CERTIFICATE_P12` | no | export the Developer ID cert (below), then `base64 -i cert.p12 \| pbcopy` |
| `SIGNING_CERTIFICATE_PWD` | no | the password you chose when exporting the `.p12` |
| `NOTARY_APPLE_ID` | no | your Apple ID email |
| `NOTARY_TEAM_ID` | no | `BUZ45YDWYN` |
| `NOTARY_PASSWORD` | no | the app-specific password |
| `SPARKLE_PRIVATE_KEY` | no | contents of `generate_keys -x` |

`HOMEBREW_TAP_TOKEN` is the only one a local release uses, and only after the
release exists. It expires, unlike the rest, so `gh secret list` is worth a
look before dispatching the cask workflow rather than after.

Exporting the certificate: Keychain Access, My Certificates, right-click
**Developer ID Application: JACARANDA LABS LTD EOOD**, Export, `.p12`, choose a
password. Export the certificate row, not the bare private key, or CI imports
something it cannot sign with.

`HOMEBREW_TAP_TOKEN` has to be a personal access token. The default
`GITHUB_TOKEN` is scoped to this repository and cannot open a pull request on
the tap.

## Homebrew

The cask lives in [mugoosse/homebrew-tap](https://github.com/mugoosse/homebrew-tap),
not in `homebrew-cask`. The main repository has notability requirements, roughly
30+ stars or 75+ days of history, which Speak does not meet yet.

The bump is two lines, `version` and `sha256`. `homebrew-tap.yml` writes them
as a pull request, and that is the route: it re-downloads the published DMG,
checks its hash against the `SHA256SUMS.txt` in the same release rather than
trusting one download of its own, and asserts both edited lines are what it
just wrote before committing anything.

```sh
gh workflow run homebrew-tap.yml -f tag=v1.0.3
gh pr list --repo mugoosse/homebrew-tap
```

It opens a pull request, so the cask is not updated until that is merged.

By hand, if the token has expired or the run fails. The tap is normally already
checked out beside this repository, so there is nothing to clone:

```sh
cd ../homebrew-tap
git pull
# take the hash from dist/SHA256SUMS.txt, which release.sh just wrote
grep '\.dmg' ../speak/dist/SHA256SUMS.txt
$EDITOR Casks/speak.rb          # version "1.0.3", sha256 "…"
git commit -am "speak 1.0.3" && git push
```

Use the hash of `Speak-x.y.z.dmg`, the versioned name, not `Speak.dmg`. They are
the same bytes today, but the versioned URL is the immutable one, and pinning a
hash to a moving URL is worse than not pinning at all.

Verify what users will actually get:

```sh
brew update && brew info --cask mugoosse/tap/speak
```

Nothing rewrites the caveats or zap stanzas: they are hand-written and not
derivable from a release, so they survive either way.

## Verifying a release

The DMG that matters is the one a user downloads, which carries a quarantine
flag the local build never has. `gh release download` does **not** set that
flag, so it has to be applied by hand or the check passes without testing
anything:

```sh
gh release download v1.0.1 --pattern "*.dmg" --dir /tmp
xattr -w com.apple.quarantine "0083;00000000;Safari;" /tmp/Speak-1.0.1.dmg
spctl -a -vvv -t open --context context:primary-signature /tmp/Speak-1.0.1.dmg
shasum -a 256 /tmp/Speak-1.0.1.dmg    # against SHA256SUMS.txt
```

`accepted`, with `source=Notarized Developer ID`, means it opens with no
Gatekeeper dialog.

`gh attestation verify` does **not** work on a release cut this way and returns
a 404. Provenance attestations come from `actions/attest-build-provenance` in
`release.yml`, which needs the repository secrets and has never run, so no
release has one. It is worth running only against a release published by CI.

### Installing a release to test it

Copying the app out of the mounted DMG is not the same as dragging it in
Finder, and the difference is not cosmetic. `ditto` and `cp -R` preserve the
quarantine flag, and macOS then runs the app from a randomised read-only path
under `/private/var/folders/…/AppTranslocation/` rather than from
`/Applications`. Finder marks its copy as user-installed, which is what stops
that happening.

So either drag it in Finder, or copy it and then clear the flag:

```sh
ditto "/Volumes/Speak 1.0.1/Speak.app" /Applications/Speak.app
xattr -dr com.apple.quarantine /Applications/Speak.app
```

Clearing it disturbs neither the signature nor the stapled ticket; both still
pass `codesign --verify --deep --strict` and `stapler validate`. Check where it
actually ended up, because a translocated copy looks fine until something
depends on its path:

```sh
pgrep -fl Speak.app     # must print /Applications/..., not /private/var/folders/...
```

To confirm the installed app *is* the published one rather than a local build
that happens to share a version number, compare the signed hash of the bundle's
contents. A rebuild is never byte-identical, so this is the check that
distinguishes them:

```sh
codesign -dvvv /Applications/Speak.app 2>&1 | grep CDHash
```

## Delta updates

Not enabled. `generate_appcast` produces binary diffs when previous releases'
archives are present in the working directory, which turns a 14 MB update into
a few hundred KB. Speak is small enough that this is not yet worth the extra
step of keeping old archives around, but it is the obvious next improvement if
releases get frequent.
