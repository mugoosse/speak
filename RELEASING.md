# Releasing Speak

Speak is a notarized, Sparkle-updating macOS app distributed as a DMG and a
Homebrew cask. This file is the whole process, including the parts that only
have to be done once.

## Cutting a release

```sh
echo 1.0.1 > VERSION
git commit -am "1.0.1"
git tag v1.0.1
git push && git push --tags
```

That is it. The tag triggers `.github/workflows/release.yml`, which builds,
signs, notarizes, staples, packages, signs the appcast, publishes the release,
attests provenance, and opens a pull request against the Homebrew tap.

The tag has to agree with `VERSION`. `release.sh` refuses to publish otherwise,
because a release named `v1.0.1` containing `Speak-1.0.0.dmg` is worse than a
failed build.

### Doing it locally instead

```sh
./release.sh              # build and package into dist/, publish nothing
./release.sh --publish    # also tag, create the GitHub release and upload
```

Same script CI runs, so a local release and a CI release cannot diverge.
`--publish` additionally refuses to run against a dirty working tree, since a
tag that points at uncommitted work cannot be rebuilt.

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
| `Speak.dmg` | the same file under a name that never changes, so `/releases/latest/download/Speak.dmg` is a permanent direct link for the README and the website. The versioned name has to stay: the cask pins a sha256 to it, which only means something while that URL is immutable |
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

Needed for CI to sign and publish. Without them the build still runs and
produces unsigned artifacts, so a fork works with no setup at all.

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

`homebrew-tap.yml` opens the version bump as a pull request rather than pushing
to main, so a broken cask needs a merge to reach users. Run it by hand if the
automatic dispatch failed:

```sh
gh workflow run homebrew-tap.yml -f tag=v1.0.1
```

It rewrites only the `version` and `sha256` lines. The caveats and zap stanzas
are hand-written and are not derivable from a release, so they survive.

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
