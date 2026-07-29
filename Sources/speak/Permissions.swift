import AppKit
import AVFoundation

enum Permissions {
    static var microphone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Note `prompt: false`: merely checking must not nag. Only an explicit
    /// button press should raise the system dialog.
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

    static func promptAccessibility() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                as CFDictionary)
        openAccessibilitySettings()
    }

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
