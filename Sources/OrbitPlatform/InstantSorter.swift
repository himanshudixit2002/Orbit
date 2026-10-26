import Foundation
import OrbitCore

/// Sorts each new download as soon as it's finished (`DownloadSorter`), while Orbit runs: it watches
/// ~/Downloads, waits until a file has stopped changing, moves it through the change lane, adds it to
/// today's history entry (Undo puts the day's files back) and logs it where the hourly sorter does.
/// While it runs, its pid file tells the hourly sorter to stand down. Live mode only.
public actor InstantSorter {
    let ctx: SystemContext
    private var settings = DownloadSettings()
    private var watcher: FileWatcher?
    private var pending: Task<Void, Never>?
    public private(set) var running = false

    public init(ctx: SystemContext) { self.ctx = ctx }

    /// Starts watching ~/Downloads; what's already there is looked at after `firstLook`. Anything that
    /// arrives meanwhile is looked at as usual.
    public func start(_ settings: DownloadSettings, firstLook: Duration = .seconds(1)) {
        self.settings = settings
        guard !running else { return }
        running = true
        writePID(getpid())
        watcher = FileWatcher(folders: [ctx.paths.downloads]) { [weak self] _ in
            Task { await self?.lookSoon(after: .seconds(1)) }
        }
        lookSoon(after: firstLook)
    }

    public func update(_ settings: DownloadSettings) { self.settings = settings }

    public func stop() {
        guard running else { return }
        running = false
        watcher = nil
        pending?.cancel()
        writePID(0)
    }

    func lookSoon(after delay: Duration) {
        guard running else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.pass()
        }
    }

    /// One look: moves what's finished and comes back for what isn't yet. Returns what moved.
    @discardableResult
    public func pass(now: Date = Date()) async -> [DownloadSorter.Move] {
        let downloads = ctx.paths.downloads
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: downloads.path(percentEncoded: false)) else { return [] }
        let kept = DownloadsKeep.names(ctx.store.root)
        let items = names.filter { !kept.contains($0) }.map { name -> DownloadSorter.Item in
            let values = try? downloads.appending(path: name).resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            return DownloadSorter.Item(name: name, isFile: values?.isRegularFile == true, modified: values?.contentModificationDate ?? .distantPast)
        }
        let settings = settings
        let (moves, lookAgain) = DownloadSorter.plan(items, settings: settings, now: now, settle: TimeInterval(settings.settleSeconds)) { folder, name in
            fm.fileExists(atPath: downloads.appending(path: folder).appending(path: name).path(percentEncoded: false))
        }
        if let lookAgain { lookSoon(after: .seconds(max(1, lookAgain.timeIntervalSince(now)))) }
        guard !moves.isEmpty else { return [] }
        let ctx = ctx
        return await ctx.lane.run("Sort downloads") { Self.move(moves, ctx: ctx) }
    }

    static func move(_ moves: [DownloadSorter.Move], ctx: SystemContext) -> [DownloadSorter.Move] {
        let downloads = ctx.paths.downloads
        var undo: [UndoAction] = []
        var lines: [String] = []
        var done: [DownloadSorter.Move] = []
        for move in moves {
            let from = downloads.appending(path: move.name)
            let to = downloads.appending(path: move.folder).appending(path: move.destination)
            guard ctx.files.exists(from), !ctx.files.exists(to) else { continue }
            do {
                try ctx.files.move(from, to: to)
            } catch {
                continue
            }
            undo.append(.moveBack(current: to.path(percentEncoded: false), original: from.path(percentEncoded: false)))
            lines.append(DownloadSorter.logLine(move, at: Date()))
            done.append(move)
        }
        guard !done.isEmpty else { return [] }
        var entry = JournalEntry(title: "", actions: undo)
        entry.group = "downloads"
        ctx.store.appendOrMerge(entry) { "Sorted \($0) download\($0 == 1 ? "" : "s")" }
        ctx.activity.record(ActivityRecord(.change, done.count == 1 ? "Sorted \(done[0].name) into \(done[0].folder)" : "Sorted \(done.count) downloads"))
        appendToLog(lines, ctx.paths.sorterLog)
        return done
    }

    static func appendToLog(_ lines: [String], _ log: URL) {
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        if let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: log, options: .atomic)
        }
    }

    /// The hourly sorter reads this: a running pid means "Orbit is sorting, stand down"; 0 means it isn't.
    func writePID(_ pid: Int32) {
        let file = ctx.store.root.appending(path: "instant-sort.pid")
        try? FileManager.default.createDirectory(at: ctx.store.root, withIntermediateDirectories: true)
        try? Data("\(pid)\n".utf8).write(to: file, options: .atomic)
    }
}

/// Downloads the user put back: neither sorter moves them again while they're still there.
public enum DownloadsKeep {
    static func file(_ root: URL) -> URL { root.appending(path: "downloads-keep.txt") }

    public static func names(_ root: URL) -> Set<String> {
        guard let text = try? String(contentsOf: file(root), encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init))
    }

    /// Adds a name, and drops ones no longer in Downloads.
    public static func keep(_ name: String, root: URL, downloads: URL) {
        var names = names(root).filter { FileManager.default.fileExists(atPath: downloads.appending(path: $0).path(percentEncoded: false)) }
        names.insert(name)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data((names.sorted().joined(separator: "\n") + "\n").utf8).write(to: file(root), options: .atomic)
    }
}

extension Actions {
    /// Saves the Downloads rules and rewrites the hourly sorter from them.
    public func applyDownloads(_ downloads: DownloadSettings, policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        let script = SorterScript.render(downloads)
        try checkEdits([.sorterScript: script], policy: policy)
        return await steps { undo in
            undo += changeSettings { $0.downloads = downloads }
            undo += try write(.sorterScript, script, executable: true, backups: backupFolder("downloads rules"))
            return downloads.instant ? "Downloads are sorted as soon as they finish." : "Downloads are sorted every hour."
        }
    }

    /// Moves a sorted download back into Downloads (as "name (2)" if its name is taken there now), and
    /// keeps it there.
    public func putBack(_ entry: SorterLog.Entry) -> ActionOutcome {
        let downloads = paths.downloads
        let from = downloads.appending(path: entry.destination)
        guard ctx.files.exists(from) else { return ActionOutcome(ok: false, message: "\(entry.file) isn't in \(entry.folder) any more.") }
        let name = DownloadSorter.freeName(entry.file) { ctx.files.exists(downloads.appending(path: $0)) }
        let to = downloads.appending(path: name)
        do {
            try ctx.files.move(from, to: to)
        } catch {
            return ActionOutcome(ok: false, message: error.localizedDescription)
        }
        if ctx.mode == .live { DownloadsKeep.keep(name, root: ctx.store.root, downloads: downloads) }
        return ActionOutcome(ok: true, message: "Put \(name) back in Downloads.",
                             undo: [.moveBack(current: to.path(percentEncoded: false), original: from.path(percentEncoded: false))])
    }
}
