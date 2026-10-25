import Foundation
import OrbitCore

/// Something that takes up space and can safely go to the Trash.
public struct CleanupItem: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case developer = "Developer leftovers"
        case downloads = "Old downloads"
        case caches = "App caches"
    }

    public let id: String
    public let title: String
    public let detail: String
    public let kind: Kind
    public let urls: [URL]
    public let size: Int64
    public let symbol: String
}

/// Folders that rebuild themselves when needed, so moving them to the Trash is safe.
struct CleanupTarget {
    let path: String
    let title: String
    let detail: String
    let kind: CleanupItem.Kind
    let symbol: String

    static let all: [CleanupTarget] = [
        CleanupTarget(path: "Library/Developer/Xcode/DerivedData", title: "Xcode build leftovers",
                      detail: "Rebuilt automatically the next time you build.", kind: .developer, symbol: "hammer.fill"),
        CleanupTarget(path: "Library/Developer/Xcode/iOS DeviceSupport", title: "iPhone debugging files",
                      detail: "Downloaded again when you connect a device.", kind: .developer, symbol: "iphone"),
        CleanupTarget(path: "Library/Developer/CoreSimulator/Caches", title: "Simulator caches",
                      detail: "Recreated when a simulator starts.", kind: .developer, symbol: "ipad.landscape"),
        CleanupTarget(path: ".npm/_cacache", title: "npm download cache",
                      detail: "Packages are downloaded again when needed.", kind: .developer, symbol: "shippingbox.fill"),
        CleanupTarget(path: "Library/pnpm/store", title: "pnpm package store",
                      detail: "Packages are downloaded again when needed.", kind: .developer, symbol: "shippingbox.fill"),
        CleanupTarget(path: "Library/Caches/Yarn", title: "Yarn cache",
                      detail: "Packages are downloaded again when needed.", kind: .developer, symbol: "shippingbox.fill"),
        CleanupTarget(path: ".cache/uv", title: "Python (uv) cache",
                      detail: "Packages are downloaded again when needed.", kind: .developer, symbol: "chevron.left.forwardslash.chevron.right"),
        CleanupTarget(path: "Library/Caches/pip", title: "Python (pip) cache",
                      detail: "Packages are downloaded again when needed.", kind: .developer, symbol: "chevron.left.forwardslash.chevron.right"),
        CleanupTarget(path: "Library/Caches/CocoaPods", title: "CocoaPods cache",
                      detail: "Pods are downloaded again when needed.", kind: .developer, symbol: "cube.fill"),
        CleanupTarget(path: ".gradle/caches", title: "Gradle cache",
                      detail: "Rebuilt on the next Android or Java build.", kind: .developer, symbol: "gearshape.2.fill"),
        CleanupTarget(path: "Library/Caches/Homebrew", title: "Homebrew downloads",
                      detail: "Old installers Homebrew keeps around.", kind: .caches, symbol: "mug.fill"),
        CleanupTarget(path: "Library/Caches/Google/Chrome", title: "Chrome cache",
                      detail: "Web pages are fetched again as you browse.", kind: .caches, symbol: "globe")
    ]
}

public struct CleanupScanner: Sendable {
    let ctx: SystemContext

    public init(_ ctx: SystemContext) { self.ctx = ctx }

    /// Measures every target in parallel. Downloads are only scanned when asked, because looking
    /// inside that folder makes macOS ask for permission.
    @concurrent public func scan(includeDownloads: Bool) async -> [CleanupItem] {
        await withTaskGroup(of: CleanupItem?.self) { group in
            for target in CleanupTarget.all {
                group.addTask {
                    let url = ctx.paths.at(target.path)
                    let size = Self.allocatedSize(url)
                    guard size > 0 else { return nil }
                    return CleanupItem(id: target.path, title: target.title, detail: target.detail, kind: target.kind,
                                       urls: [url], size: size, symbol: target.symbol)
                }
            }
            if includeDownloads {
                group.addTask { oldDownloads(olderThan: 30) }
            }
            var items: [CleanupItem] = []
            for await item in group { if let item { items.append(item) } }
            return items.sorted { $0.size > $1.size }
        }
    }

    func oldDownloads(olderThan days: Int) -> CleanupItem? {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .addedToDirectoryDateKey, .totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: ctx.paths.downloads, includingPropertiesForKeys: keys,
                                                                        options: [.skipsHiddenFiles]) else { return nil }
        var urls: [URL] = []
        var size: Int64 = 0
        for url in entries {
            let values = try? url.resourceValues(forKeys: Set(keys))
            // Both arrived and last changed over a month ago: an archive unpacked today keeps its old dates.
            guard let newest = [values?.addedToDirectoryDate, values?.contentModificationDate].compactMap({ $0 }).max(),
                  newest < cutoff else { continue }
            urls.append(url)
            size += values?.isDirectory == true ? Self.allocatedSize(url) : Int64(values?.totalFileAllocatedSize ?? 0)
        }
        guard !urls.isEmpty else { return nil }
        return CleanupItem(id: "downloads", title: "Downloads older than \(days) days",
                           detail: "\(urls.count) item\(urls.count == 1 ? "" : "s") you haven't touched in a month.",
                           kind: .downloads, urls: urls, size: size, symbol: "arrow.down.circle.fill")
    }

    static func allocatedSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                                              options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Moves an item's files to the Trash, recording how to put them back.
    public func trash(_ item: CleanupItem) -> ActionOutcome {
        let undo = UndoRecorder.forThisTask(ctx.store)
        var failed = 0
        for url in item.urls {
            do {
                if let trashed = try ctx.files.trash(url) {
                    undo.append(.moveBack(current: trashed.path(percentEncoded: false), original: url.path(percentEncoded: false)))
                }
            } catch {
                failed += 1
            }
        }
        let freed = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        return failed == 0
            ? ActionOutcome(ok: true, message: "Moved \(item.title.lowercased()) to the Trash. Empty the Trash to free \(freed).", undo: undo.actions)
            : ActionOutcome(ok: false, message: "\(failed) item\(failed == 1 ? "" : "s") couldn't be moved (in use?).", undo: undo.actions)
    }

    public func trashSize() -> Int64 { Self.allocatedSize(ctx.paths.trash) }
}
