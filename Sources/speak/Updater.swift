import AppKit
import Sparkle

/// Sparkle wiring.
///
/// Speak is `LSUIElement`, so it has no Dock icon and no app-switcher entry.
/// Any window it opens can fall behind another app with no way to reach it,
/// which is the same trap Onboarding works around. Sparkle shows its own
/// windows and modal alerts, so every one of those callbacks has to activate
/// the app first or an update prompt becomes invisible and the app looks hung.
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    /// Built in `init`, not stored inline, because the controller needs `self`
    /// as its user driver delegate and that is not available until after
    /// `super.init()`.
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Sparkle disables its own menu item while a check is already running or
    /// the updater failed to start, so the menu mirrors that rather than
    /// offering a control that does nothing.
    var canCheck: Bool { controller.updater.canCheckForUpdates }

    /// Human-readable last check, for Settings.
    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(sender)
    }

    // MARK: - SPUStandardUserDriverDelegate

    func standardUserDriverWillShowModalAlert() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // A scheduled check that found something must not steal focus silently;
        // activating here is what makes the release-notes window reachable.
        if handleShowingUpdate { NSApp.activate(ignoringOtherApps: true) }
    }
}
