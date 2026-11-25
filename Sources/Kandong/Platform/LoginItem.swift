import AppKit
import Observation
import ServiceManagement
import KandongKit

/// Opening Kandong at login. macOS keeps whether it does, and the user can also change it in System
/// Settings → Login Items, so Kandong reads it from there and never turns it back on by itself.
@MainActor
@Observable
final class LoginItem {
    enum State {
        case off, on
        /// Turned off in System Settings, where only the user can allow it again.
        case blocked
        /// This copy of Kandong isn't in an Applications folder.
        case unavailable
    }

    private(set) var state: State
    /// Why macOS refused the last change.
    var errorMessage: String?
    /// For rendering previews: a fixed state, without asking macOS.
    @ObservationIgnored private let isPreview: Bool

    init() {
        isPreview = false
        state = Self.current
    }

    init(preview state: State, errorMessage: String? = nil) {
        isPreview = true
        self.state = state
        self.errorMessage = errorMessage
    }

    /// Re-reads the state, which may have changed in System Settings.
    func refresh() {
        guard !isPreview else { return }
        let current = Self.current
        guard current != state else { return }
        state = current
        errorMessage = nil
    }

    func setEnabled(_ enabled: Bool) {
        guard !isPreview, state != .unavailable else { return }
        errorMessage = nil
        var failure: Error?
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            failure = error
        }
        refresh()
        // E.g. already registered is no failure, and blocked says why by itself.
        if let failure, state == (enabled ? .off : .on) { errorMessage = failure.localizedDescription }
    }

    /// System Settings → General → Login Items.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static var current: State {
        guard AppLocation.isInApplications(Bundle.main.bundleURL) else { return .unavailable }
        return switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .blocked
        // macOS can also say "not found" for an app that was never registered.
        case .notRegistered, .notFound: .off
        @unknown default: .off
        }
    }

    /// Whether macOS opened Kandong at login, rather than the user. Only known while the app is
    /// handling the event that opened it, i.e. in `applicationDidFinishLaunching`.
    static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
