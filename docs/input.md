# Keyboard input and the event tap

The global shortcut lives in `AppDelegate.installHotkey` (a `CGEventTap`); `Config.swift` holds `Shortcut`, `Modifier` and `KeyName`; `SecureInput.swift` detects secure input. `SPEAK_DEBUG=1` traces every modifier change and keyDown to stderr.

## The event tap must stay ordered and synchronous

`installHotkey` dispatches with `DispatchQueue.main.async`, not `Task {}`. Independent Tasks have no ordering guarantee, and an all-released event overtaking the key-downs truncates a chord being recorded (this shipped once as "3-key shortcuts don't work").

The tap is `.defaultTap`, not `.listenOnly`, because a shortcut containing a character key has to swallow that keystroke. Only an exact match is consumed; everything else passes through. Handle `tapDisabledByTimeout` or the tap dies silently.

## fn is invisible to NSEvent on Apple Silicon

`NSEvent.addGlobalMonitorForEvents` never sees the Globe/fn key; the system consumes it first. Hence the `CGEventTap`. Also: `.function` is set by arrow and F-keys too, and `NSEvent.shift` cannot distinguish left from right, which is why `Modifier` uses device-dependent bits (`0x02` for left shift, and so on).

## Secure input takes character key events away

While any app holds secure input, a `.cgSessionEventTap` is not handed ordinary key events. Measured with a tap of the same shape as `installHotkey`'s and a synthesized F13: seen once with secure input off, and not at all with it on. Modifier changes can still arrive on some paths. That means the default modifier-only chord can start a recording while the Escape keyDown needed to cancel it never reaches `handleKeyDown`.

So a character-key shortcut does not fail, it never fires, while a modifier-only shortcut may fail only after recording starts. There is no error to catch and no callback to miss. Terminal's Secure Keyboard Entry is the deliberate case; the common accidental one is an app that turns it on for a password field and does not turn it off.

`SecureInput.isOn` is asked in `menuWillOpen` and nowhere else. Do not poll it and do not drive the menu bar icon from it: it goes on for a second or two whenever anybody types a password anywhere, so anything reacting continuously would spend its life crying wolf at people who are only logging in. The menu is also the only channel that still works, since mouse events are unaffected.

Do not try to recover Escape by polling `CGEventSource.keyState` or through an `IOHIDManager`. Both reported no physical Escape while secure input was held, even though synthesized Quartz input made `keyState` look viable. Secure input has to be released by the responsible app before Escape can reach Speak. The recording indicator's Cancel button is the fallback because mouse events still work. Keep the panel nonactivating so using it does not move keyboard focus.

`SecureInput.holder()` reads `kCGSSessionSecureInputPID` out of the IO registry, and the pid it finds is the **responsible** app's, not the caller's: a bare command-line binary that enables secure input is published under the pid of the terminal it was run from. That is the more useful answer, since it names something the user can see and quit, but it means the name is not always the process that made the call.
