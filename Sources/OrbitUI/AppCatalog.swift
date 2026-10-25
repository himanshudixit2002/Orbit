import AppKit
import Foundation

/// An app on this Mac, for pickers.
nonisolated struct InstalledApp: Hashable, Sendable {
    let name: String
    let path: String
}

/// The apps on this Mac, for pickers: found off the main thread and kept, and looked for again each
/// time a picker appears, so one installed meanwhile shows up.
@Observable
final class AppCatalog {
    private(set) var apps: [InstalledApp] = []
    @ObservationIgnored private var scanning = false

    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { AppCatalog.scan() }.value
            if found != apps { apps = found }
            scanning = false
        }
    }

    nonisolated static func scan(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [InstalledApp] {
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       home.appending(path: "Applications").path(percentEncoded: false)]
        var found = [InstalledApp(name: "Finder", path: "/System/Library/CoreServices/Finder.app")]
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where name.hasSuffix(".app") {
                found.append(InstalledApp(name: String(name.dropLast(4)), path: folder + "/" + name))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// App and file icons, each looked up once: NSWorkspace asks the icon service every time, and lists
/// of apps draw them again on every change.
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func of(_ path: String) -> NSImage {
        if let icon = cache[path] { return icon }
        if cache.count > 500 { cache.removeAll() }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}
