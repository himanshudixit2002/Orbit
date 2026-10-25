import Foundation
import OrbitCore

/// Something that takes up space, how safe it is to clear, and why it's there.
public struct CleanupItem: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case developer = "Developer leftovers"
        case projects = "Idle project build folders"
        case tools = "Developer tools"
        case downloads = "Old downloads"
        case caches = "App caches"
    }

    public enum Safety: Int, Sendable, Comparable {
        /// Rebuilt by itself the next time it's needed.
        case rebuilds
        /// Downloaded again when needed (takes a while, needs the internet).
        case downloadsAgain
        /// Might hold something you'd want: your call, not ticked for you.
        case yourCall
        /// Orbit can't clear it; it says how.
        case guideOnly

        public static func < (a: Safety, b: Safety) -> Bool { a.rawValue < b.rawValue }

        public var label: String {
            switch self {
            case .rebuilds: "Rebuilds itself"
            case .downloadsAgain: "Downloads again when needed"
            case .yourCall: "Your call"
            case .guideOnly: "Clear it yourself"
            }
        }
    }

    public let id: String
    public let title: String
    public let detail: String
    public let kind: Kind
    public let urls: [URL]
    public let size: Int64
    public let symbol: String
    public var safety: Safety = .rebuilds
    /// The longer story, for the details sheet.
    public var why: String = ""
    /// The app whose cache this is: it can only be cleared while that app is closed.
    public var appMustBeQuit: String?

    /// Ticked when the scan finishes: only things that come back by themselves.
    public var suggested: Bool { safety <= .downloadsAgain }
}

/// Folders that rebuild themselves when needed, so moving them to the Trash is safe.
struct CleanupTarget {
    let path: String
    let title: String
    let detail: String
    let kind: CleanupItem.Kind
    let symbol: String
    var app: String?

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
                      detail: "Web pages are fetched again as you browse.", kind: .caches, symbol: "globe", app: "com.google.Chrome"),
        CleanupTarget(path: "Library/Caches/com.spotify.client", title: "Spotify cache",
                      detail: "Songs stream again as you play them.", kind: .caches, symbol: "music.note", app: "com.spotify.client"),
        CleanupTarget(path: "Library/Application Support/Code/Cache", title: "VS Code cache",
                      detail: "Rebuilt as you work.", kind: .caches, symbol: "chevron.left.forwardslash.chevron.right", app: "com.microsoft.VSCode")
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
                    var item = CleanupItem(id: url.path(percentEncoded: false), title: target.title, detail: target.detail, kind: target.kind,
                                           urls: [url], size: size, symbol: target.symbol)
                    item.safety = target.kind == .caches || target.path.contains("Cache") || target.path.contains("store") ? .downloadsAgain : .rebuilds
                    item.appMustBeQuit = target.app
                    item.why = "\(target.detail) Moving it to the Trash is safe: \(item.safety == .rebuilds ? "it's rebuilt" : "what's needed is fetched again") the next time something asks for it."
                    return item
                }
            }
            if includeDownloads {
                group.addTask { oldDownloads(olderThan: 30) }
            }
            var items: [CleanupItem] = []
            for await item in group { if let item { items.append(item) } }
            // The newer kinds of leftovers: each is quick to look for.
            items += idleBuildFolders() + gradleVersions() + androidTools() + dockerLeftovers() + taggedCaches() + flutterAndSimulators()
            let shown = Dictionary(grouping: items, by: \.id).compactMap(\.value.first)
            return shown.filter { $0.size >= Self.worthShowing || $0.safety == .guideOnly }.sorted { $0.size > $1.size }
        }
    }

    /// Below this, an item isn't worth a line.
    static let worthShowing: Int64 = 10_000_000

    /// Build folders in projects nobody has touched for 30 days, never while something runs in them
    /// (a dev server, say).
    func idleBuildFolders(now: Date = Date()) -> [CleanupItem] {
        let names: [String: String] = ["node_modules": "npm install", ".venv": "creating the environment again", "venv": "creating the environment again",
                                       ".build": "the next build", "Pods": "pod install", "build": "the next build", ".dart_tool": "flutter pub get",
                                       "target": "the next cargo build"]
        let busy = Self.workingFolders()
        var items: [CleanupItem] = []
        for project in DoctorProbe.projects(in: ctx.paths.developer) {
            let touched = Self.lastTouched(project.url, ignoring: Set(names.keys))
            guard now.timeIntervalSince(touched) > 30 * 86_400,
                  !busy.contains(where: { $0.hasPrefix(project.url.path(percentEncoded: false)) }) else { continue }
            let candidates = names.keys.flatMap { name in
                [name, "ios/\(name)", "macos/\(name)", "android/\(name)"].map { project.url.appending(path: $0) }
            }
            for url in candidates where FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                let name = url.lastPathComponent
                var item = CleanupItem(id: url.path(percentEncoded: false), title: "\(project.name): \(name)",
                                       detail: "Not touched since \(touched.formatted(date: .abbreviated, time: .omitted)). Comes back with \(names[name] ?? "the next build").",
                                       kind: .projects, urls: [url], size: Self.allocatedSize(url), symbol: "folder.badge.gearshape")
                item.why = "The project hasn't changed in over a month. Its \(name) folder holds downloaded or built files, not your code, and \(names[name] ?? "the next build") puts it back."
                items.append(item)
            }
        }
        return items
    }

    /// When a project last changed: its own files and git, not its build folders.
    static func lastTouched(_ project: URL, ignoring: Set<String>) -> Date {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dates = entries.filter { !ignoring.contains($0.lastPathComponent) }.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        let git = ["index", "HEAD"].compactMap {
            (try? project.appending(path: ".git/\($0)").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        return (dates + git).max() ?? .distantPast
    }

    /// The folders processes are working in now (a dev server's project, say).
    static func workingFolders() -> [String] {
        RunningProcess.all().compactMap { process in
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(process.pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
            return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
        }
    }

    /// Gradle versions no project asks for any more.
    func gradleVersions() -> [CleanupItem] {
        let dists = ctx.paths.at(".gradle/wrapper/dists")
        let installed = ((try? FileManager.default.contentsOfDirectory(atPath: dists.path(percentEncoded: false))) ?? []).filter { $0.hasPrefix("gradle-") }
        guard !installed.isEmpty else { return [] }
        let wanted = Set(Self.gradleVersionsInUse(ctx.paths.developer))
        return installed.filter { !wanted.contains($0) }.map { name in
            let url = dists.appending(path: name)
            var item = CleanupItem(id: url.path(percentEncoded: false), title: "Gradle \(name.dropFirst(7))",
                                   detail: "No project of yours uses this version now.", kind: .tools, urls: [url],
                                   size: Self.allocatedSize(url), symbol: "gearshape.2.fill")
            item.safety = .downloadsAgain
            item.why = "Android and Java projects say which Gradle they want; none of yours wants this one. A project that does gets it again automatically."
            return item
        }
    }

    /// "gradle-8.14-all" for each project's wrapper.
    static func gradleVersionsInUse(_ developer: URL) -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: developer, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [String] = []
        for case let url as URL in walker {
            if ["node_modules", "Pods", "build", ".build"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if walker.level > 6 { walker.skipDescendants(); continue }
            guard url.lastPathComponent == "gradle-wrapper.properties",
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("distributionUrl") }),
                  let file = line.split(separator: "/").last else { continue }
            found.append(String(file.replacingOccurrences(of: ".zip", with: "")))
        }
        return found
    }

    /// The Android emulator when there are no virtual devices, and NDKs (your call: native builds need them).
    func androidTools() -> [CleanupItem] {
        let sdk = ctx.paths.at("Library/Android/sdk")
        var items: [CleanupItem] = []
        let avds = ((try? FileManager.default.contentsOfDirectory(atPath: ctx.paths.at(".android/avd").path(percentEncoded: false))) ?? [])
            .filter { $0.hasSuffix(".avd") }
        let emulator = sdk.appending(path: "emulator")
        if avds.isEmpty, FileManager.default.fileExists(atPath: emulator.path(percentEncoded: false)) {
            var item = CleanupItem(id: emulator.path(percentEncoded: false), title: "Android emulator", detail: "You have no virtual Android devices.",
                                   kind: .tools, urls: [emulator], size: Self.allocatedSize(emulator), symbol: "smartphone")
            item.safety = .downloadsAgain
            item.why = "The emulator runs virtual Android phones, and you have none set up. Android Studio's SDK Manager installs it again if you make one."
            items.append(item)
        }
        let ndk = sdk.appending(path: "ndk")
        for version in (try? FileManager.default.contentsOfDirectory(atPath: ndk.path(percentEncoded: false))) ?? [] where !version.hasPrefix(".") {
            let url = ndk.appending(path: version)
            var item = CleanupItem(id: url.path(percentEncoded: false), title: "Android NDK \(version)",
                                   detail: "Only needed to build apps with native (C or C++) code.", kind: .tools, urls: [url],
                                   size: Self.allocatedSize(url), symbol: "cpu")
            item.safety = .yourCall
            item.why = "Flutter and React Native apps can need it for their native parts. If a project needs it again, Android Studio or Gradle downloads it (a few gigabytes)."
            items.append(item)
        }
        return items
    }

    /// Docker Desktop's data, when Docker Desktop itself is gone.
    func dockerLeftovers() -> [CleanupItem] {
        let data = ctx.paths.at("Library/Containers/com.docker.docker")
        guard FileManager.default.fileExists(atPath: data.path(percentEncoded: false)),
              !FileManager.default.fileExists(atPath: "/Applications/Docker.app") else { return [] }
        var item = CleanupItem(id: data.path(percentEncoded: false), title: "Docker Desktop's leftover data",
                               detail: "Docker Desktop isn't installed any more.", kind: .tools, urls: [data],
                               size: Self.allocatedSize(data), symbol: "shippingbox")
        item.safety = .yourCall
        item.why = "Images, containers and volumes from when Docker Desktop was installed. If you put Docker back and need them, they'd be gone: only clear it if you're done with them."
        return [item]
    }

    /// Folders that say they're caches (a CACHEDIR.TAG file inside), outside projects and app containers.
    func taggedCaches() -> [CleanupItem] {
        let home = ctx.paths.home
        let fm = FileManager.default
        var items: [CleanupItem] = []
        func look(_ url: URL, depth: Int) {
            guard depth <= 3 else { return }
            let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
            for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true {
                let name = child.lastPathComponent
                if ["Library", "Developer", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", ".Trash", ".gradle"].contains(name) && depth == 0 { continue }
                if fm.fileExists(atPath: child.appending(path: "CACHEDIR.TAG").path(percentEncoded: false)) {
                    var item = CleanupItem(id: child.path(percentEncoded: false), title: "\(child.deletingLastPathComponent().lastPathComponent)/\(name) cache",
                                           detail: "Marked as a cache by the tool that made it.", kind: .developer, urls: [child],
                                           size: Self.allocatedSize(child), symbol: "archivebox")
                    item.safety = .downloadsAgain
                    item.why = "The tool that made this folder marked it as a cache (CACHEDIR.TAG): it fills it again when it needs to."
                    items.append(item)
                } else {
                    look(child, depth: depth + 1)
                }
            }
        }
        look(home, depth: 0)
        return items
    }

    /// Big things Orbit doesn't clear but explains: Flutter (you build Flutter apps) and simulator runtimes.
    func flutterAndSimulators() -> [CleanupItem] {
        var items: [CleanupItem] = []
        // Homebrew's `flutter` points into the SDK (…/share/flutter/bin/flutter): the SDK is two folders up.
        let command = URL(fileURLWithPath: Tool.homebrew).appending(path: "bin/flutter")
        if FileManager.default.fileExists(atPath: command.path(percentEncoded: false)) {
            let sdk = command.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            var item = CleanupItem(id: sdk.path(percentEncoded: false), title: "Flutter", detail: "You have Flutter projects, so it stays.",
                                   kind: .tools, urls: [], size: Self.allocatedSize(sdk), symbol: "bird")
            item.safety = .guideOnly
            item.why = "Flutter itself, installed with Homebrew. If you stop building Flutter apps, `brew uninstall --cask flutter` removes it."
            items.append(item)
        }
        if let runtimes = Self.simulatorRuntimes() {
            var item = CleanupItem(id: "simulator-runtimes", title: "iPhone simulator systems", detail: runtimes.detail,
                                   kind: .tools, urls: [], size: runtimes.size, symbol: "iphone.gen3")
            item.safety = .guideOnly
            item.why = "Each simulator system is a whole copy of iOS that macOS keeps for Xcode. Remove ones you don't use in Xcode › Settings › Components."
            items.append(item)
        }
        return items
    }

    /// "iOS 26.1" and the total size, from `xcrun simctl runtime list`'s text.
    static func simulatorRuntimes() -> (detail: String, size: Int64)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "runtime", "list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return SimulatorRuntimes.parse(String(decoding: data, as: UTF8.self))
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
        var item = CleanupItem(id: "downloads", title: "Downloads older than \(days) days",
                               detail: "\(urls.count) item\(urls.count == 1 ? "" : "s") you haven't touched in a month.",
                               kind: .downloads, urls: urls, size: size, symbol: "arrow.down.circle.fill")
        item.safety = .yourCall
        item.why = "Files you downloaded over a month ago and haven't opened since. They're yours, so look before clearing; the Trash keeps them until you empty it."
        return item
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

    /// Moves items' files to the Trash in one change, recording how to put them back. An app's cache
    /// waits while that app is open.
    public func trash(_ items: [CleanupItem]) -> ActionOutcome {
        let undo = UndoRecorder.forThisTask(ctx.store)
        var failed = 0
        let running = ctx.readings.runningApps()
        let open = items.filter { $0.appMustBeQuit.map(running.contains) ?? false }
        let size = items.filter { !open.contains($0) }.reduce(0) { $0 + $1.size }
        for url in items.filter({ !open.contains($0) && $0.safety != .guideOnly }).flatMap(\.urls) {
            do {
                if let trashed = try ctx.files.trash(url) {
                    undo.append(.moveBack(current: trashed.path(percentEncoded: false), original: url.path(percentEncoded: false)))
                }
            } catch {
                failed += 1
            }
        }
        let freed = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        if !open.isEmpty {
            return ActionOutcome(ok: failed == 0 && open.count < items.count,
                                 message: "Quit \(open.map(\.title).joined(separator: ", ")) first, then clear \(open.count == 1 ? "it" : "them")."
                                    + (open.count < items.count ? " The rest went to the Trash (\(freed))." : ""),
                                 undo: undo.actions)
        }
        let what = items.count == 1 ? items[0].title.lowercased() : "\(items.count) items"
        return failed == 0
            ? ActionOutcome(ok: true, message: "Moved \(what) to the Trash. Empty the Trash to free \(freed).", undo: undo.actions)
            : ActionOutcome(ok: false, message: "\(failed) item\(failed == 1 ? "" : "s") couldn't be moved (in use?).", undo: undo.actions)
    }

    public func trash(_ item: CleanupItem) -> ActionOutcome { trash([item]) }

    public func trashSize() -> Int64 { Self.allocatedSize(ctx.paths.trash) }
}
