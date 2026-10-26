import Foundation
import OrbitCore

public enum RunMode: String, Sendable {
    /// Changes the Mac for real.
    case live
    /// Runs only commands that change nothing and logs the rest: safe to click anything.
    case practice
}

/// Orbit's saved state: settings, the undo journal, the before-Orbit baseline and the file registry.
/// Practice mode keeps a separate copy so experiments never touch the real one.
public final class StateStore: Sendable {
    public let root: URL
    /// The real store's folder, for practice mode's copy: its record of written files counts too.
    let liveRoot: URL?
    private struct State {
        var settings = OrbitSettings()
        var registry = FileRegistry()
        var journal: [JournalEntry] = []
        var baseline: Baseline?
        var inflight: [InflightChange] = []
        var activeMode: ModeRecord?
        var paused: PausedState?
        var linkToken: String?
    }
    private let state: Locked<State>
    /// baseline.json was there but couldn't be read: taking a new one now would record Orbit's own changes.
    public let baselineUnreadable: Bool

    public init(root: URL, liveRoot: URL? = nil) {
        self.root = root
        self.liveRoot = liveRoot
        var loaded = State()
        let settingsFile = root.appending(path: "settings.json")
        if let data = try? Data(contentsOf: settingsFile) {
            if let settings = try? OrbitSettings.decode(data) { loaded.settings = settings } else { Self.setAside(settingsFile) }
        }
        loaded.registry = Self.load(FileRegistry.self, root.appending(path: "managed-files.json")) ?? FileRegistry()
        loaded.journal = Self.loadEach(JournalEntry.self, root.appending(path: "journal.json"))
        let baselineFile = root.appending(path: "baseline.json")
        loaded.baseline = Self.load(Baseline.self, baselineFile)
        loaded.inflight = Self.loadEach(InflightChange.self, root.appending(path: "inflight.json"))
        loaded.activeMode = Self.load(ModeRecord?.self, root.appending(path: "active-mode.json")) ?? nil
        loaded.paused = Self.load(PausedState?.self, root.appending(path: "paused.json")) ?? nil
        baselineUnreadable = loaded.baseline == nil && FileManager.default.fileExists(atPath: Self.setAsidePath(baselineFile))
        state = Locked(loaded)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let value = try? decoder.decode(type, from: data) { return value }
        setAside(url)
        return nil
    }

    /// Reads a list (the undo history, say) item by item: one Orbit can't read (damaged, or from a newer
    /// Orbit) doesn't cost the rest. The file as it was is kept alongside.
    private static func loadEach<T: Decodable>(_ type: T.Type, _ url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([Lenient<T>].self, from: data) else {
            setAside(url)
            return []
        }
        let readable = entries.compactMap(\.value)
        if readable.count < entries.count { setAside(url, keepingOriginal: true) }
        return readable
    }

    /// Decodes a value if it can, and stands in for it with nil if it can't.
    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    static func setAsidePath(_ url: URL) -> String {
        url.deletingPathExtension().path(percentEncoded: false) + " (unreadable).json"
    }

    /// Keeps a file Orbit can't read (damaged, or from a newer Orbit) instead of letting the next save replace it.
    private static func setAside(_ url: URL, keepingOriginal: Bool = false) {
        let aside = URL(fileURLWithPath: setAsidePath(url))
        if FileManager.default.fileExists(atPath: aside.path(percentEncoded: false)) {
            _ = try? FileManager.default.trashItem(at: aside, resultingItemURL: nil)
        }
        if keepingOriginal {
            try? FileManager.default.copyItem(at: url, to: aside)
        } else {
            try? FileManager.default.moveItem(at: url, to: aside)
        }
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: root.appending(path: name), options: .atomic)
            saveFailure.withLock { $0[name] = nil }
        } catch {
            saveFailure.withLock { $0[name] = error.localizedDescription }
        }
    }

    private let saveFailure = Locked<[String: String]>([:])
    /// Why Orbit couldn't save part of its state last time it tried, if it couldn't.
    public var saveProblem: String? {
        saveFailure.current.sorted { $0.key < $1.key }.first.map { "Couldn't save \($0.key): \($0.value)" }
    }

    public var settings: OrbitSettings { state.withLock { $0.settings } }

    // Each change is saved before the lock is let go, so two quick changes can't reach the disk in the wrong order.

    /// Changes the settings and returns them as they were before and after.
    @discardableResult
    public func updateSettings(_ change: (inout OrbitSettings) -> Void) -> (before: OrbitSettings, after: OrbitSettings) {
        state.withLock { s in
            let before = s.settings
            change(&s.settings)
            save(s.settings, "settings.json")
            return (before, s.settings)
        }
    }

    public var registry: FileRegistry {
        var registry = state.withLock { $0.registry }
        if let liveRoot, let live = Self.load(FileRegistry.self, liveRoot.appending(path: "managed-files.json")) {
            registry.alsoWritten = live.lastWritten
        }
        return registry
    }

    public func noteWritten(_ file: ManagedFile, data: Data) {
        state.withLock { s in
            s.registry.lastWritten[file] = Hashing.sha256(data)
            save(s.registry, "managed-files.json")
        }
    }

    public var journal: [JournalEntry] { state.withLock { $0.journal } }

    /// Records how a change went: in the history if it can be undone or failed (so it shows up), and
    /// off the list of changes under way (`beginChange`) whose id it carries.
    public func append(_ entry: JournalEntry) {
        state.withLock { s in
            if !entry.actions.isEmpty || entry.failed { add([entry], to: &s) }
            // In the history first, then off the list: stopping between the two saves can only leave a
            // duplicate the next launch recognises, never lose the change.
            end(entry.id, in: &s)
        }
    }

    /// Records a change that belongs with others of its kind today (sorting Downloads, say): it joins
    /// that group's entry while the entry is from today and not undone, else it starts a new one.
    /// `title` names the entry from how many steps it now holds.
    public func appendOrMerge(_ entry: JournalEntry, title: (Int) -> String) {
        guard let group = entry.group, !entry.actions.isEmpty else { return append(entry) }
        state.withLock { s in
            if let i = s.journal.lastIndex(where: { $0.group == group }), !s.journal[i].undone,
               Calendar.current.isDate(s.journal[i].date, inSameDayAs: entry.date) {
                var merged = s.journal.remove(at: i)
                merged.actions += entry.actions
                merged.date = entry.date
                merged.title = title(merged.actions.count)
                s.journal.append(merged)
                save(s.journal, "journal.json")
            } else {
                var fresh = entry
                fresh.title = title(entry.actions.count)
                add([fresh], to: &s)
            }
            end(entry.id, in: &s)
        }
    }

    private func add(_ entries: [JournalEntry], to s: inout State) {
        guard !entries.isEmpty else { return }
        s.journal += entries
        if s.journal.count > 200 { s.journal.removeFirst(s.journal.count - 200) }
        save(s.journal, "journal.json")
    }

    public func markUndone(_ id: UUID) {
        state.withLock { s in
            if let i = s.journal.firstIndex(where: { $0.id == id }) { s.journal[i].undone = true }
            save(s.journal, "journal.json")
        }
    }

    // MARK: Changes under way

    /// A change starts: noted before it touches anything, so if Orbit stops part-way the next launch knows.
    public func beginChange(_ id: UUID, title: String) {
        state.withLock { s in
            s.inflight.append(InflightChange(id: id, title: title))
            save(s.inflight, "inflight.json")
        }
    }

    /// The undo steps a change has recorded so far, saved as each one is recorded.
    public func noteSteps(_ actions: [UndoAction], change id: UUID) {
        state.withLock { s in
            guard let i = s.inflight.firstIndex(where: { $0.id == id }) else { return }
            s.inflight[i].actions = actions
            save(s.inflight, "inflight.json")
        }
    }

    /// A change that finished with nothing for the history (`append` ends the others).
    public func endChange(_ id: UUID) {
        state.withLock { s in end(id, in: &s) }
    }

    private func end(_ id: UUID, in s: inout State) {
        guard let i = s.inflight.firstIndex(where: { $0.id == id }) else { return }
        s.inflight.remove(at: i)
        save(s.inflight, "inflight.json")
    }

    /// The changes under way now.
    public var inflight: [InflightChange] { state.withLock { $0.inflight } }

    /// Changes still under way when Orbit last stopped go into the history as interrupted, so what
    /// they did can be undone. Called once at launch, before anything new starts.
    @discardableResult
    public func recoverInterrupted() -> [JournalEntry] {
        state.withLock { s in
            guard !s.inflight.isEmpty else { return [] }
            // One already in the history did finish: Orbit stopped between saving the two files.
            let known = Set(s.journal.map(\.id))
            let entries = s.inflight.filter { !known.contains($0.id) }.map(\.interrupted)
            add(entries, to: &s)
            s.inflight = []
            save(s.inflight, "inflight.json")
            return entries
        }
    }

    // MARK: Links

    /// A secret only Orbit's own links carry (those it shows and writes into Karabiner rules): a link
    /// without it, from a web page say, asks before it changes anything.
    public var linkToken: String {
        state.withLock { s in
            if let token = s.linkToken { return token }
            let file = root.appending(path: "link-token")
            if let saved = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               saved.count >= 32 {
                s.linkToken = saved
                return saved
            }
            let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? Data(token.utf8).write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false))
            s.linkToken = token
            return token
        }
    }

    // MARK: Active mode

    /// The mode switched on, kept so it survives Orbit quitting (what to put back when it ends).
    public var activeMode: ModeRecord? { state.withLock { $0.activeMode } }

    public func setActiveMode(_ record: ModeRecord?) {
        state.withLock { s in
            s.activeMode = record
            save(record, "active-mode.json")
        }
    }

    /// What was on when Orbit was paused; nil while it isn't paused.
    public var paused: PausedState? { state.withLock { $0.paused } }

    public func setPaused(_ paused: PausedState?) {
        state.withLock { s in
            s.paused = paused
            save(paused, "paused.json")
        }
    }

    public var baseline: Baseline? { state.withLock { $0.baseline } }

    public func setBaseline(_ baseline: Baseline) {
        state.withLock { s in
            s.baseline = baseline
            save(baseline, "baseline.json")
        }
    }
}

/// Everything Orbit needs to look at and change the Mac, switched as a whole between live and practice.
public struct SystemContext: Sendable {
    public let mode: RunMode
    public let paths: Paths
    public let uid: UInt32
    public let executor: any CommandExecuting
    public let files: any FileStore
    public let prefs: any PreferenceWriting
    public let practiceLog: PracticeLog
    public let store: StateStore
    /// What Orbit did, for the Health page and diagnostics.
    public let activity: ActivityLog
    /// Changes run here one at a time (shared by every copy of this context).
    public var lane = ChangeLane()
    /// What Orbit reads straight from macOS (tests swap in their own).
    public var readings = SystemReadings()

    public static func make(mode: RunMode, paths: Paths = Paths()) -> SystemContext {
        let log = PracticeLog()
        let live = LiveExecutor(home: paths.home)
        switch mode {
        case .live:
            let store = StateStore(root: paths.support)
            let activity = ActivityLog(root: store.root)
            return SystemContext(mode: mode, paths: paths, uid: getuid(), executor: LoggingExecutor(live, log: activity),
                                 files: LiveFileStore(), prefs: LivePreferences(), practiceLog: log, store: store, activity: activity)
        case .practice:
            let store = StateStore(root: paths.practiceRoot.appending(path: "State"), liveRoot: paths.support)
            let activity = ActivityLog(root: store.root)
            return SystemContext(mode: mode, paths: paths, uid: getuid(),
                                 executor: LoggingExecutor(PracticeExecutor(live: live, log: log), log: activity),
                                 files: PracticeFileStore(paths: paths, log: log),
                                 prefs: PracticePreferences(log: log), practiceLog: log, store: store, activity: activity)
        }
    }

    @discardableResult
    public func run(_ command: Command) async -> CommandResult { await executor.run(command) }

    /// A dated folder for the backups made by one change.
    public func backupFolder(_ label: String) -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        return paths.backups.appending(path: "\(stamp) \(label)")
    }
}
