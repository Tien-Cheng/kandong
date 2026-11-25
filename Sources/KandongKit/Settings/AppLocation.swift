import Foundation

/// Where the app runs from. Only a copy in an Applications folder can open at login: one opened from
/// Downloads may run from a temporary path (App Translocation), and a build folder's is throwaway.
public enum AppLocation {
    /// Whether the app is in /Applications or the user's own Applications folder, or a folder inside them.
    public static func isInApplications(_ app: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let folder = app.resolvingSymlinksInPath().deletingLastPathComponent().pathComponents
        return [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")].contains {
            folder.starts(with: $0.resolvingSymlinksInPath().pathComponents)
        }
    }
}
