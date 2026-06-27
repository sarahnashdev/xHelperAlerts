import Foundation
import AppKit
import Combine
import Sparkle

/// Thin SwiftUI-friendly wrapper around Sparkle's update controller.
/// Exposes the two pieces of state the rest of the app needs
/// (`updateAvailable`, `latestVersion`) and the actions the UI calls
/// (`checkForUpdates`, `openDownloadPage`).
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
    }

    /// Trigger an immediate user-visible check — shows Sparkle's
    /// "Checking…" sheet, then the update dialog or "you're up to
    /// date" message.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Kept for API compat with the old in-house checker. Sparkle's
    /// own UI handles downloading + install; this just opens the
    /// release page in the browser as a fallback.
    func openDownloadPage() {
        let url = URL(string: "https://github.com/sarahnashdev/xHelperAlerts/releases/latest")!
        NSWorkspace.shared.open(url)
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
