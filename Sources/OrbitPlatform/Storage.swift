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

    /// Each area's size, the disk's used and free space, and the big files found along the way.
    @concurrent public func measure(fullAccess: Bool) async -> (areas: [StorageArea], largeFiles: [LargeFile]) {
        let hidden = fullAccess ? [] : StorageMap.needsFullAccess
        let roots = Dictionary(uniqueKeysWithValues: StorageArea.Kind.allCases.map { ($0, roots(for: $0, fullAccess: fullAccess)) })
        let results = await withTaskGroup(of: (StorageArea.Kind, Int64, [LargeFile]).self) { group in
            for (kind, urls) in roots where !hidden.contains(kind) && !urls.isEmpty {
                // Big files only where they're yours: not inside apps or developer tools.
                let collect = ![.apps, .developer].contains(kind)
                for url in urls { group.addTask { Self.walk(url, collectingFrom: collect ? LargeFiles.atLeast : nil).with(kind) } }
            }
            var sizes: [StorageArea.Kind: Int64] = [:]
            var files: [LargeFile] = []
            for await (kind, size, found) in group {
                sizes[kind, default: 0] += size
                files += found
            }
            return (sizes, files)
        }
        let (free, total) = Self.volume(systemRoot)
        let areas = StorageMap.areas(measured: results.0, hidden: hidden, used: max(0, total - free), free: free)
        let files = Array(Dictionary(grouping: results.1, by: \.path).compactMap(\.value.first).sorted { $0.size > $1.size }.prefix(25))
        return (areas, files)
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

    /// The space a folder (or file) takes on disk, and its files of at least `collectingFrom` bytes. Another
    /// disk mounted inside (a simulator's runtime, say) isn't this disk's space, so it's left out.
    static func walk(_ url: URL, collectingFrom limit: Int64?) -> Walked {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey, .isVolumeKey]
        if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            let large = limit.map { size >= $0 } == true ? [LargeFile(path: url.path(percentEncoded: false), size: size, modified: values.contentModificationDate)] : []
            return Walked(size: size, large: large)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, _ in true }) else { return Walked(size: 0, large: []) }
        var total: Int64 = 0
        var large: [LargeFile] = []
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isVolume == true {
                enumerator.skipDescendants()
                continue
            }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            total += size
            if let limit, size >= limit, values.isRegularFile == true {
                large.append(LargeFile(path: file.path(percentEncoded: false), size: size, modified: values.contentModificationDate))
            }
        }
        return Walked(size: total, large: large)
    }

    /// Free space as Finder counts it (purgeable space counts as free) and the disk's size.
    static func volume(_ url: URL) -> (free: Int64, total: Int64) {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
    }

    /// The apps in Applications, biggest first, with when each was last opened.
    @concurrent public func apps() async -> [InstalledAppSize] {
        let folders = ["/Applications", "~/Applications"].map(url)
        let bundles = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
                .filter { $0.hasSuffix(".app") }.map { folder.appending(path: $0) }
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path(percentEncoded: false) })
        let me = getuid()
        return await withTaskGroup(of: InstalledAppSize.self) { group in
            for bundle in bundles {
                group.addTask {
                    let path = bundle.path(percentEncoded: false)
                    let owner = (try? FileManager.default.attributesOfItem(atPath: path))?[.ownerAccountID] as? NSNumber
                    let item = MDItemCreateWithURL(nil, bundle as CFURL)
                    let lastUsed = item.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
                    return InstalledAppSize(name: bundle.deletingPathExtension().lastPathComponent, path: path,
                                            bundleID: Bundle(url: bundle)?.bundleIdentifier, size: Self.walk(bundle, collectingFrom: nil).size,
                                            lastUsed: lastUsed, removable: owner?.uint32Value == me,
                                            running: running.contains(bundle.standardizedFileURL.path(percentEncoded: false)))
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
