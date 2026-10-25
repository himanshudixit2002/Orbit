import Foundation
import OrbitCore

public enum FileStoreError: LocalizedError {
    case writeFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let path, let code): "Couldn't save \(path) (\(String(cString: strerror(code))))."
        }
    }
}

/// Reading, writing, moving and trashing files. Nothing is ever deleted for good.
public protocol FileStore: Sendable {
    func read(_ url: URL) -> Data?
    func exists(_ url: URL) -> Bool
    /// Writes atomically, follows symlinks, keeps the existing file mode (or sets 0755 when `executable`).
    func write(_ data: Data, to url: URL, executable: Bool) throws
    /// Moves to the Trash and returns where it went.
    func trash(_ url: URL) throws -> URL?
    func move(_ from: URL, to: URL) throws
    /// Copies a file into Orbit's backups and returns the copy.
    func backup(_ url: URL, into folder: URL) throws -> URL?
}

public struct LiveFileStore: FileStore {
    public init() {}

    public func read(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    public func write(_ data: Data, to url: URL, executable: Bool) throws {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        let folder = target.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let targetPath = target.path(percentEncoded: false)
        let oldMode = (try? fm.attributesOfItem(atPath: targetPath)[.posixPermissions] as? NSNumber)?.intValue
        let mode = executable ? 0o755 : (oldMode ?? 0o644)
        let temp = folder.appending(path: ".\(target.lastPathComponent).orbit-\(UUID().uuidString.prefix(8))")
        let tempPath = temp.path(percentEncoded: false)
        try data.write(to: temp)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: tempPath)
        if rename(tempPath, targetPath) != 0 {
            let code = errno
            unlink(tempPath)  // our own half-written temp file, never the user's
            throw FileStoreError.writeFailed(targetPath, code)
        }
    }

    public func trash(_ url: URL) throws -> URL? {
        guard exists(url) else { return nil }
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    public func move(_ from: URL, to: URL) throws {
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: from, to: to)
    }

    public func backup(_ url: URL, into folder: URL) throws -> URL? {
        guard exists(url) else { return nil }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        for n in 1... {
            let copy = folder.appending(path: n == 1 ? url.lastPathComponent : "\(stem) \(n)\(ext)")
            do {
                try FileManager.default.copyItem(at: url.resolvingSymlinksInPath(), to: copy)
                return copy
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue  // taken, perhaps a moment ago by another change
            }
        }
        return nil
    }
}

/// Practice mode: writes go to a shadow copy of the home folder, moves and trashing are only logged.
public struct PracticeFileStore: FileStore {
    let live = LiveFileStore()
    let paths: Paths
    let log: PracticeLog

    public init(paths: Paths, log: PracticeLog) {
        self.paths = paths
        self.log = log
    }

    /// Where practice mode puts its copy of `url`.
    public func shadow(_ url: URL) -> URL {
        let path = url.path(percentEncoded: false)
        let home = paths.home.path(percentEncoded: false)
        let relative = path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path
        return paths.practiceRoot.appending(path: "Files").appending(path: relative)
    }

    // Once practice mode has written a file, it reads its own copy back, so it sees its own changes
    // (and doesn't mistake the real file for a hand edit).
    public func read(_ url: URL) -> Data? { live.read(shadow(url)) ?? live.read(url) }

    public func exists(_ url: URL) -> Bool { live.exists(shadow(url)) || live.exists(url) }

    public func write(_ data: Data, to url: URL, executable: Bool) throws {
        let copy = shadow(url)
        try live.write(data, to: copy, executable: executable)
        log.record("Would update \(paths.tilde(url))", "practice copy: \(paths.tilde(copy))")
    }

    public func trash(_ url: URL) throws -> URL? {
        log.record("Would move \(paths.tilde(url)) to the Trash", url.path(percentEncoded: false))
        return paths.trash.appending(path: url.lastPathComponent)
    }

    public func move(_ from: URL, to: URL) throws {
        log.record("Would move \(paths.tilde(from)) to \(paths.tilde(to))", "")
    }

    public func backup(_ url: URL, into folder: URL) throws -> URL? {
        let copy = shadow(url)
        return try live.backup(live.exists(copy) ? copy : url, into: folder)
    }
}
