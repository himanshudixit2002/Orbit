import Foundation
import OrbitCore

extension Actions {
    var backupsFolder: URL { ctx.store.root.appending(path: "Backups") }

    /// Backup folders Undo and "Back to before Orbit" can no longer use: no step in the undo history
    /// (which keeps the last 200 changes) and nothing in the before-Orbit snapshot points into them.
    /// Only folders older than `days` count, so nothing from a change made a moment ago is in question.
    public func unneededBackups(olderThan days: Double = 7, now: Date = Date()) -> [URL] {
        var pointedTo = ctx.store.baseline.map { Array($0.files.values) } ?? []
        for action in ctx.store.journal.flatMap(\.actions) {
            switch action {
            case .restoreFile(_, let backup?): pointedTo.append(backup)
            case .moveBack(let current, _): pointedTo.append(current)
            default: break
            }
        }
        let needed = Set(pointedTo.map { Self.plainPath(URL(fileURLWithPath: $0)) })
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let folders = try? FileManager.default.contentsOfDirectory(at: backupsFolder, includingPropertiesForKeys: keys,
                                                                         options: [.skipsHiddenFiles]) else { return [] }
        return folders.filter { folder in
            guard folder.lastPathComponent != "Before Orbit",
                  let values = try? folder.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) > days * 86_400 else { return false }
            let inside = Self.plainPath(folder) + "/"
            return !needed.contains { $0.hasPrefix(inside) }
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// One spelling per file: links resolved (/var is really /private/var) and no trailing slash, which
    /// folder URLs carry.
    static func plainPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Moves the backups nothing needs any more to the Trash, gathered into one folder so the Trash
    /// gets a single item. Returns how many backup folders went.
    @discardableResult
    public func clearUnneededBackups() -> Int {
        let unneeded = unneededBackups()
        guard !unneeded.isEmpty else { return 0 }
        let gathered = ctx.store.root.appending(path: "Orbit backups no longer needed")
        do {
            for folder in unneeded { try ctx.files.move(folder, to: gathered.appending(path: folder.lastPathComponent)) }
            _ = try ctx.files.trash(gathered)
        } catch {
            return 0  // Whatever was gathered goes to the Trash with the next batch.
        }
        return unneeded.count
    }

    /// The space Orbit's settings, undo history and backups take up.
    public func storageUsed() -> Int64 {
        CleanupScanner.allocatedSize(ctx.store.root)
    }
}
