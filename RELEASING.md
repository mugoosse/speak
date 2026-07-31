# Releasing Speak

Speak is a notarized, Sparkle-updating macOS app distributed as a DMG and a
Homebrew cask. This file is the whole process, including the parts that only
have to be done once.

## Cutting a release

Releases are cut locally, from a machine holding the signing certificate, the
notarytool profile and the Sparkle key. This is the whole procedure:

```sh
echo 1.0.3 > VERSION
# edit RELEASE_NOTES.md only if the boilerplate changed; the changelog itself
# is generated from the commits since the last tag
git commit -am "what changed"          # becomes the changelog line
./release.sh --publish
```

`--publish` tags, pushes the tag, builds, signs, notarizes and staples both the
app and the DMG, signs the appcast, creates the GitHub release and uploads
every asset. Without it, `./release.sh` builds and packages into `dist/` and
publishes nothing, which is the way to check a build before committing to it.

Two things it refuses to do, both deliberate: publish from a dirty working
tree, since a tag pointing at uncommitted work cannot be rebuilt, and publish
when the tag and `VERSION` disagree, because a release named `v1.0.3`
containing `Speak-1.0.2.dmg` is worse than a failed build.

Then update the Homebrew cask, which is a separate repository. See
[Homebrew](#homebrew) below.

### Why not CI

`.github/workflows/release.yml` is complete and does the same work by calling
the same script, so the two cannot diverge. It is `workflow_dispatch`-only and
the repository has **no secrets set**, so it will not sign, notarize or publish
anything as things stand.

That is a choice, not an oversight: it keeps the Developer ID certificate, the
notarization password and the Sparkle private key off GitHub. The cost is that
releasing needs the right Mac. To move to CI, set the seven secrets listed
under [Repository secrets](#repository-secrets) and dispatch the workflow with
an existing tag.

### When notarization stalls

Apple's queue is unpredictable; over an hour on a first submission from a new
Developer ID account is normal, and the connection can drop while waiting.
`release.sh` splits submit from wait for exactly this reason, so a dropped
connection costs a retry of the wait rather than the whole upload.

```sh
xcrun notarytool history --keychain-profile speak-notary   # find the id
./release.sh --resume <submission-id>
```

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

**None of these are set, and a local release needs none of them.** They are
listed for whoever decides to move releasing into CI. Without them the workflow
still builds and produces unsigned artifacts rather than failing, which is what
lets a fork build with no setup at all.

| Secret | How to get it |
|---|---|
| `SIGNING_CERTIFICATE_P12` | export the Developer ID cert (below), then `base64 -i cert.p12 \| pbcopy` |
| `SIGNING_CERTIFICATE_PWD` | the password you chose when exporting the `.p12` |
| `NOTARY_APPLE_ID` | your Apple ID email |
| `NOTARY_TEAM_ID` | `BUZ45YDWYN` |
| `NOTARY_PASSWORD` | the app-specific password |
| `SPARKLE_PRIVATE_KEY` | contents of `generate_keys -x` |
| `HOMEBREW_TAP_TOKEN` | fine-grained PAT with contents:write and pull-requests:write on `mugoosse/homebrew-tap` |

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

The bump is two lines, `version` and `sha256`, and it is done by hand. The tap
is normally already checked out beside this repository, so there is nothing to
clone:

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

`homebrew-tap.yml` automates the same two lines as a pull request, but it needs
`HOMEBREW_TAP_TOKEN`, which is not set. Until it is, `gh workflow run
homebrew-tap.yml` fails on its first step.

Nothing rewrites the caveats or zap stanzas: they are hand-written and not
derivable from a release, so they survive either way.

## Verifying a release

The DMG that matters is the one a user downloads, which carries a quarantine
flag the local build never has:

```sh
gh release download v1.0.1 --pattern "*.dmg" --dir /tmp
xattr -p com.apple.quarantine /tmp/Speak-1.0.1.dmg   # should exist
spctl -a -vvv -t open --context context:primary-signature /tmp/Speak-1.0.1.dmg
```

`accepted` means it opens with no Gatekeeper dialog. Also worth checking:

```sh
gh attestation verify /tmp/Speak-1.0.1.dmg --repo mugoosse/speak
shasum -a 256 /tmp/Speak-1.0.1.dmg    # against SHA256SUMS.txt
```

## Delta updates

Not enabled. `generate_appcast` produces binary diffs when previous releases'
archives are present in the working directory, which turns a 14 MB update into
a few hundred KB. Speak is small enough that this is not yet worth the extra
step of keeping old archives around, but it is the obvious next improvement if
releases get frequent.
