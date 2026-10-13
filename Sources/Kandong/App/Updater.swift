import AppKit
import Observation
import Sparkle

/// Keeps Kandong up to date with Sparkle: checks GitHub Releases daily, downloads new versions in
/// the background and installs them when Kandong quits, or right away from Restart to Update.
/// See docs/adr/0007-self-update-with-sparkle.md.
@MainActor
@Observable
final class Updater: NSObject {
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    /// A downloaded update waiting for Kandong to quit, and how to install it now instead.
    private(set) var pendingVersion: String?
    @ObservationIgnored private var installNow: (() -> Void)?

    /// Sparkle runs only in a built Kandong.app, whose Info.plist names the feed; not from `swift run`.
    static var isAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    override init() {
        super.init()
        guard Self.isAvailable else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func restartToUpdate() {
        installNow?()
    }

    /// Sparkle keeps these in Kandong's user defaults itself.
    var automaticallyChecks: Bool {
        get { access(keyPath: \.automaticallyChecks); return controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            withMutation(keyPath: \.automaticallyChecks) { controller?.updater.automaticallyChecksForUpdates = newValue }
        }
    }

    var automaticallyDownloads: Bool {
        get { access(keyPath: \.automaticallyDownloads); return controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            withMutation(keyPath: \.automaticallyDownloads) { controller?.updater.automaticallyDownloadsUpdates = newValue }
        }
    }
}

extension Updater: SPUUpdaterDelegate {
    /// A downloaded update installs when Kandong quits; until then the menu offers to install it now.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            pendingVersion = version
            installNow = immediateInstallHandler
        }
        return true
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    /// Kandong lives in the menu bar: a scheduled check mustn't pop a window over the user's reading.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
