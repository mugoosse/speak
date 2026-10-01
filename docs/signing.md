# Code signing

What `make_app.sh` does when it signs the bundle, and why. Release-time signing, notarization and the Sparkle key are in `RELEASING.md`.

## Signing decides whether permissions survive a rebuild

Ad-hoc signing gives a designated requirement of `cdhash H"…"`, pinned to one build. TCC keys the Accessibility grant to it, so **every rebuild silently invalidates the permission** while System Settings still shows the toggle on. `make_app.sh` signs with a real certificate when one exists, producing a stable identity-based requirement. Do not "simplify" it back to `--sign -`.

Check with:

```sh
codesign -d -r- /Applications/Speak.app     # must not contain cdhash
```

## Hardened Runtime needs the entitlements file

Signing uses the Hardened Runtime, which notarization requires. That is why `Speak.entitlements` exists: without `com.apple.security.device.audio-input` the runtime blocks the microphone.

## Sparkle's nested code has to be signed inside-out

`Sparkle.framework` contains two XPC services, a helper binary and an updater app. Each needs its own signature with the hardened runtime, signed before the framework, which is signed before the app: sealing a container fixes whatever it holds.

They must not get `$COMMON`. That carries Speak's entitlements and bundle identifier, so applying it would grant the microphone to Sparkle's downloader and produce four bundles claiming to be `com.mgo.speak`.

The framework is copied with `ditto`, not `cp -R`, because a framework's version symlinks get flattened by `cp` and the result fails `codesign --verify --deep --strict`.

SwiftPM links Sparkle but never embeds it, so `Package.swift` adds an rpath of `@executable_path/../Frameworks` and `make_app.sh` copies the framework there. Remove either half and the app dies at launch with a dyld error.
