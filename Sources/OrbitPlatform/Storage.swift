import AppKit
import CoreServices
import Foundation
import OrbitCore

/// Measures where the disk goes, lists the apps by size and finds big files. Read-only. Without Full
/// Disk Access it stays out of the folders where looking would bring up macOS's questions.
public struct StorageProbe: Sendable {
    let ctx: SystemContext
    /// Where absolute paths ("/Applications") are looked for: the Mac itself, or a test's folder.
    let systemRoot: URL

    public init(_ ctx: SystemContext, systemRoot: URL = URL(fileURLWithPath: "/")) {
        self.ctx = ctx
        self.systemRoot = systemRoot
    }

    var home: URL { ctx.paths.home }

    func url(_ path: String) -> URL {
        path.hasPrefix("~/") ? home.appending(path: String(path.dropFirst(2))) : systemRoot.appending(path: String(path.dropFirst()))
    }

    /// What one look at the disk found.
    public struct Scan: Sendable {
        public var areas: [StorageArea]
        public var largeFiles: [LargeFile]
        /// Each app's size (by its path), measured on the same walk.
        public var appSizes: [String: Int64]
    }

    /// Each area's size, the disk's used and free space, and the big files found along the way. Each
    /// folder's contents are walked side by side: the disk answers several at once.
    @concurrent public func measure(fullAccess: Bool) async -> Scan {
        let hidden = fullAccess ? [] : StorageMap.needsFullAccess
        let roots = Dictionary(uniqueKeysWithValues: StorageArea.Kind.allCases.map { ($0, roots(for: $0, fullAccess: fullAccess)) })
        let results = await withTaskGroup(of: (StorageArea.Kind, URL, Walked).self) { group in
            for (kind, urls) in roots where !hidden.contains(kind) && !urls.isEmpty {
                // Big files only where they're yours: not inside apps or developer tools.
                let collect = ![.apps, .developer].contains(kind)
                for piece in urls.flatMap(Self.pieces) {
                    group.addTask { (kind, piece, Self.walk(piece, collectingFrom: collect ? LargeFiles.atLeast : nil)) }
                }
            }
            var sizes: [StorageArea.Kind: Int64] = [:]
            var files: [LargeFile] = []
            var apps: [String: Int64] = [:]
            for await (kind, piece, walked) in group {
                sizes[kind, default: 0] += walked.size
                files += walked.large
                // Each app is a piece of its own: the list of apps takes its size from this walk.
                if kind == .apps { apps[piece.path(percentEncoded: false)] = walked.size }
            }
            return (sizes, files, apps)
        }
        let (free, total) = Self.volume(systemRoot)
        let areas = StorageMap.areas(measured: results.0, hidden: hidden, used: max(0, total - free), free: free)
        let files = Array(Dictionary(grouping: results.1, by: \.path).compactMap(\.value.first).sorted { $0.size > $1.size }.prefix(25))
        return Scan(areas: areas, largeFiles: files, appSizes: results.2)
    }

    /// A folder's contents, each to be walked on its own; a file, a link or a folder that can't be read
    /// as itself. Another disk mounted inside (a simulator's runtime) isn't this disk's space.
    static func pieces(of url: URL) -> [URL] {
        let path = url.path(percentEncoded: false)
        var root = stat()
        guard lstat(path, &root) == 0, Int32(root.st_mode) & Int32(S_IFMT) == Int32(S_IFDIR),
              let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [url] }
        return names.compactMap { name in
            let child = url.appending(path: name)
            var info = stat()
            guard lstat(child.path(percentEncoded: false), &info) == 0, info.st_dev == root.st_dev else { return nil }
            return child
        }
    }

    /// The folders that make up an area, as they are on this Mac.
    func roots(for kind: StorageArea.Kind, fullAccess: Bool) -> [URL] {
        let fm = FileManager.default
        switch kind {
        case .appData:
            let library = home.appending(path: "Library")
            let names = (try? fm.contentsOfDirectory(atPath: library.path(percentEncoded: false))) ?? []
            return names.filter { fullAccess ? !StorageMap.libraryCountedElsewhere.contains($0) : StorageMap.libraryWithoutFullAccess.contains($0) }
                .map { library.appending(path: $0) }
        case .home:
            // Everything else in the home folder: the folders no other area takes.
            let taken = Set(StorageArea.Kind.allCases.flatMap(StorageMap.paths).filter { $0.hasPrefix("~/") }.map { String($0.dropFirst(2)) })
                .union(["Library", ".Trash"])
            let names = (try? fm.contentsOfDirectory(atPath: home.path(percentEncoded: false))) ?? []
            return names.filter { !taken.contains($0) }.map { home.appending(path: $0) }
        default:
            return StorageMap.paths(kind).map(url).filter { fm.fileExists(atPath: $0.path(percentEncoded: false)) }
        }
    }

    struct Walked {
        var size: Int64
        var large: [LargeFile]
        func with(_ kind: StorageArea.Kind) -> (StorageArea.Kind, Int64, [LargeFile]) { (kind, size, large) }
    }

    /// The space a folder (or file) takes on disk, and its files of at least `collectingFrom` bytes. Walked
    /// the way `du` does (fts, staying on this disk, so a simulator's mounted runtime isn't counted twice):
    /// about four times quicker than FileManager's enumerator, with the same totals.
    static func walk(_ url: URL, collectingFrom limit: Int64?) -> Walked {
        var total: Int64 = 0
        var large: [LargeFile] = []
        url.withUnsafeFileSystemRepresentation { root in
            guard let root, let copy = strdup(root) else { return }
            defer { free(copy) }
            var paths: [UnsafeMutablePointer<CChar>?] = [copy, nil]
            // No chdir: fts would otherwise move the whole app's working folder while it walks.
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return }
            defer { fts_close(fts) }
            while let entry = fts_read(fts) {
                let info = Int32(entry.pointee.fts_info)
                guard info == FTS_F || info == FTS_SL || info == FTS_DEFAULT, let stat = entry.pointee.fts_statp?.pointee else { continue }
                let size = Int64(stat.st_blocks) * 512
                total += size
                if let limit, size >= limit, info == FTS_F {
                    large.append(LargeFile(path: String(cString: entry.pointee.fts_path), size: size,
                                           modified: Date(timeIntervalSince1970: Double(stat.st_mtimespec.tv_sec))))
                }
            }
        }
        return Walked(size: total, large: large)
    }

    /// Free space as Finder counts it (purgeable space counts as free) and the disk's size.
    static func volume(_ url: URL) -> (free: Int64, total: Int64) {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
    }

    /// The apps in Applications, biggest first, with when each was last opened. `sizes` from a scan
    /// spares walking each app again.
    @concurrent public func apps(sizes: [String: Int64] = [:]) async -> [InstalledAppSize] {
        let folders = ["/Applications", "~/Applications"].map(url)
        let bundles = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
                .filter { $0.hasSuffix(".app") }.map { folder.appending(path: $0) }
        }
        // macOS gives running apps' folders with a slash at the end: compared without it.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL.map { AppUsageTracker.trimmed($0.standardizedFileURL.path(percentEncoded: false)) } })
        let me = getuid()
        return await withTaskGroup(of: InstalledAppSize.self) { group in
            for bundle in bundles {
                group.addTask {
                    let path = bundle.path(percentEncoded: false)
                    let owner = (try? FileManager.default.attributesOfItem(atPath: path))?[.ownerAccountID] as? NSNumber
                    let item = MDItemCreateWithURL(nil, bundle as CFURL)
                    let lastUsed = item.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
                    return InstalledAppSize(name: bundle.deletingPathExtension().lastPathComponent, path: path,
                                            bundleID: Bundle(url: bundle)?.bundleIdentifier, size: sizes[path] ?? Self.walk(bundle, collectingFrom: nil).size,
                                            lastUsed: lastUsed, removable: owner?.uint32Value == me,
                                            running: running.contains(AppUsageTracker.trimmed(bundle.standardizedFileURL.path(percentEncoded: false))))
                }
            }
            var apps: [InstalledAppSize] = []
            for await app in group { apps.append(app) }
            return apps.sorted { ($0.size, $0.name) > ($1.size, $1.name) }
        }
    }
}

extension CleanupItem {
    /// An app to move to the Trash (it must be closed first); Undo puts it back.
    public static func app(_ app: InstalledAppSize) -> CleanupItem {
        var item = CleanupItem(id: app.path, title: app.name, detail: app.lastUsedText(), kind: .tools,
                               urls: [URL(fileURLWithPath: app.path)], size: app.size, symbol: "square.grid.2x2.fill")
        item.safety = .yourCall
        item.appMustBeQuit = app.bundleID
        return item
    }

    /// A big file of yours to move to the Trash; Undo puts it back.
    public static func file(_ file: LargeFile) -> CleanupItem {
        var item = CleanupItem(id: file.path, title: file.name, detail: file.path, kind: .downloads,
                               urls: [URL(fileURLWithPath: file.path)], size: file.size, symbol: "doc.fill")
        item.safety = .yourCall
        return item
    }
}
