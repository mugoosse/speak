import AppKit
import AVFoundation

enum Permissions {
    static var microphone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Note `prompt: false`: merely checking must not nag.
    ///
    /// Checking is also what puts Speak into the Accessibility list, which is
    /// why nothing here ever passes `prompt: true`. See
    /// `openAccessibilitySettings`.
    static var accessibility: Bool {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
                as CFDictionary)
    }

    static var allGranted: Bool { microphone && accessibility }

    static func requestMicrophone(_ done: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { g in
            DispatchQueue.main.async { done(g) }
        }
    }

    /// Deliberately does not raise the system Accessibility dialog first, the
    /// way `requestMicrophone` raises the microphone one.
    ///
    /// The two are not equivalent. Allow in the microphone dialog grants the
    /// permission, so that dialog is the only way to get it. The Accessibility
    /// dialog cannot grant anything: its useful button just opens the pane
    /// this opens directly, and its default, highlighted button is Deny.
    /// Calling both, which is what shipped in 1.0.0, put a dialog whose Return
    /// key refuses Speak on top of the Settings window already showing the
    /// right toggle.
    ///
    /// It is not needed to get Speak listed in Accessibility either. The
    /// `prompt: false` check above registers the app on its own: verified on
    /// macOS 26 by resetting the grant, launching Speak, touching nothing, and
    /// watching the row appear in the system TCC database.
    static func openAccessibilitySettings() {
        openPane("com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        openPane("com.apple.preference.security?Privacy_Microphone")
    }

    private static func openPane(_ path: String) {
        if let url = URL(string: "x-apple.systempreferences:" + path) {
            NSWorkspace.shared.open(url)
        }
    }
}
