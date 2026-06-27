import Foundation
import AppKit
import Combine
import Sparkle

/// Thin SwiftUI-friendly wrapper around Sparkle's update controller.
/// Exposes the two pieces of state the rest of the app needs
/// (`updateAvailable`, `latestVersion`) and a single `checkForUpdates`
/// action that triggers Sparkle's native install dialog.
///
/// Sparkle handles the heavy lifting: appcast.xml polling, EdDSA
/// signature verification, download, drag-replace into /Applications,
/// and relaunch. The user clicks one button — that's it.
@MainActor
final class UpdateChecker: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {

    @Published private(set) var latestVersion: String?
    @Published private(set) var updateAvailable: Bool = false

    private var updaterController: SPUStandardUpdaterController!

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        // Force an in-background check ~8s after launch so users see
        // an available update on launch rather than waiting Sparkle's
        // default 24-hour scheduler.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.updaterController.updater.checkForUpdatesInBackground()
        }
    }

    /// Triggers Sparkle's native install dialog. If an update is
    /// already pending it shows "Install Update" immediately; if not,
    /// it shows the "Checking…" sheet then either the install dialog
    /// or "you're up to date" message.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Alias for `checkForUpdates`. Popover and About-tab banners
    /// call this so older names in those views keep working without
    /// duplicate logic.
    func openDownloadPage() {
        checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor [weak self] in
            self?.updateAvailable = true
            self?.latestVersion = item.displayVersionString
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor [weak self] in
            self?.updateAvailable = false
        }
    }
}
