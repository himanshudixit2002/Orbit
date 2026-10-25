import Foundation
import OrbitCore

/// The snapshot Orbit's widgets and Control Center switches read. It lives in a folder of Orbit's that
/// the sandboxed widget extension is allowed to read, and only read: ~/Library/Application
/// Support/Orbit/Shared (Practice/Shared for Orbit Dev).
public struct SharedStore: Sendable {
    public let folder: URL
    public var file: URL { folder.appending(path: "snapshot.json") }

    public init(practice: Bool, home: URL = SharedStore.realHome) {
        let support = home.appending(path: "Library/Application Support/Orbit")
        folder = (practice ? support.appending(path: "Practice") : support).appending(path: "Shared")
    }

    /// The store for this copy of Orbit (or its widget extension): Orbit Dev's ids contain ".orbit.dev".
    public static var forThisApp: SharedStore {
        SharedStore(practice: Bundle.main.bundleIdentifier?.contains(".orbit.dev") == true)
    }

    /// The user's home folder, also from inside the sandbox (where NSHomeDirectory() is the container).
    public static var realHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public func load() -> OrbitSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OrbitSnapshot.self, from: data)
    }

    /// Writes the snapshot whole (readers never see half of one). Returns whether it worked.
    @discardableResult
    public func save(_ snapshot: OrbitSnapshot) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
