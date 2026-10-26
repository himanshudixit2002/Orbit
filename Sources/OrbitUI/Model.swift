import AppKit
import Observation
import OrbitCore
import OrbitPlatform
import OrbitShared
import ServiceManagement
import SwiftUI

extension Page {
    var hue: Hue {
        switch self {
        case .home: .blue
        case .style: .pink
        case .windows: .cyan
        case .menuBar: .indigo
        case .keyboard: .orange
        case .files: .teal
        case .modes: .purple
        case .shortcuts: .indigo
        case .developer: .orange
        case .monitor: .green
        case .speed: .orange
        case .cleanup: .yellow
        case .dockFinder: .blue
        case .apps: .cyan
        case .health: .red
        }
    }
}

/// A config file was changed outside Orbit; asks before replacing it.
/// Asked before undoing an older change that later changes have built on.
struct UndoQuestion: Identifiable {
    let entry: JournalEntry
    /// The later changes that touched some of the same things.
    let later: [JournalEntry]
    var id: UUID { entry.id }
}

struct Conflict: Identifiable {
    let id = UUID()
    let file: ManagedFile
    /// What Orbit would write, shown against the file on disk.
    let proposed: String?
    let retry: @MainActor () async -> Void
}

@Observable
public final class AppModel {
    public let ctx: SystemContext
    let probes: Probes
    let actions: Actions
    var status = SystemStatus()
    var settings: OrbitSettings
    var page: Page = .home
    var busy: Set<String> = []
    var toast: Toast?
    var conflict: Conflict?
    var undoQuestion: UndoQuestion?
    /// A profile picked to import, waiting for the user to look it over.
    var pendingImport: ProfileImport?
    /// A folder the setup was just saved into that's in git: Orbit offers to commit it there.
    var profileCommitFolder: URL?
    public var showSetup = false
    var practiceLog: [PracticeEntry] = []
    var journal: [JournalEntry] = []
    var deepChecking = false
    /// Whether Orbit opens at login (asked of macOS off the main thread on each check).
    var launchAtLogin = false
    /// Orbit is set to open at login but switched off in System Settings › Login Items.
    var loginNeedsApproval = false
    /// The main window was asked for before Orbit could open windows.
    @ObservationIgnored var mainWindowWanted = false
    @ObservationIgnored var lastLink: (url: URL, at: Date)?
    /// Wakes up for the next thing a mode does by itself.
    @ObservationIgnored var modeAlarm: Task<Void, Never>?
    /// Asks about a link without Orbit's token (tests answer for the user).
    @ObservationIgnored var confirmLink: @MainActor (OrbitCommand) -> Bool = AppModel.askAboutLink
    /// Remembers which mode a Focus started (tests use their own).
    @ObservationIgnored var focusDefaults = UserDefaults.standard
    @ObservationIgnored let commandPalette = PaletteController()
    /// What the Doctor found last time it looked.
    var doctor: [DoctorFinding] = []
    var doctorChecked: Date?
    var doctorRunning = false
    /// What needed attention at the last check; nil before the first one.
    @ObservationIgnored var lastAttention: Set<FeatureID>?
    @ObservationIgnored let hotKey = HotKey()
    /// Whether the palette's shortcut is working (another app may own it).
    var hotKeyRegistered = false
    /// Told when the user adds, edits or deletes a mode (Siri's phrases name them).
    @ObservationIgnored public var modesEdited: (() -> Void)?
    /// The Dock and Finder as last read, so their page opens on real values straight away.
    var dockFinder: DockFinderReading?
    /// Which instant groups are on (read off the main thread when the Speed page shows).
    var instantOn: Set<SpeedTweak.Group> = []
    let appCatalog = AppCatalog()
    let monitor = MonitorModel()
    let modes: ModesModel
    let cleanup: CleanupModel
    let storage: StorageModel
    var openWindow: OpenWindowAction?
    var isSnapshot = false
    var karabinerStep: KarabinerInstaller.Step = .idle
    var searchText = ""
    /// Bumped by ⌘F; the search field takes focus when it changes.
    var searchRequest = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var queued: [String: (title: String, work: Work)] = [:]
    private var spaceObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var fileWatcher: FileWatcher?
    private var exitWatcher: ExitWatcher?
    private var refreshPending: Task<Void, Never>?
    let watchdog = Watchdog()
    /// Keeps the menu bar's CPU, memory and clock up to date (fewer processes than its scripts).
    let barFeeder: BarFeeder
    /// Keeps what the widgets and Control Center switches show up to date.
    let publisher: SnapshotPublisher
    /// Sorts each download as soon as it's finished, while Orbit runs.
    let instantSorter: InstantSorter
    /// When each app was last in front and what it used last time: for the Speed page (and, apart,
    /// for the heavy-app notices, whose sampling runs on its own clock).
    let speedTracker: AppUsageTracker
    let heavyTracker: AppUsageTracker
    var speedFindings: [DoctorFinding] = []
    var speedFacts: SpeedFacts?
    var speedChecked: Date?
    var speedRunning = false
    var appUsage: [AppUsage] = []
    var loginAgents: [UserLoginAgent] = []
    /// What was on when Orbit was paused (everything it runs switched off); nil while it isn't.
    var paused: PausedState?
    /// The restarts Orbit has timed, oldest first.
    var startups: [StartupRecord] = []
    /// The apps that were heavy at the heavy-app check's last look.
    @ObservationIgnored var heavyBefore: Set<String> = []
    private var activationObserver: NSObjectProtocol?
    var sortingInstantly = false
    @ObservationIgnored var sorterScriptChecked = false
    /// macOS notifications (only in the real app: they need its bundle).
    var notifier: Notifier?
    /// Helpers the watchdog says keep stopping, so each is announced once.
    private(set) var keepsStopping: Set<Helper> = []
    private var pendingRestarts: Set<Helper> = []
    private var activeObserver: NSObjectProtocol?
    /// Set when Orbit sends the user to System Settings to fix tiling, so coming back checks again.
    var fixingTiling = false

    public init(ctx: SystemContext) {
        self.ctx = ctx
        probes = Probes(ctx)
        actions = Actions(ctx)
        settings = ctx.store.settings
        // A change Orbit was making when it last stopped shows in the history, with Undo for what it did.
        for entry in ctx.store.recoverInterrupted() {
            ctx.activity.record(ActivityRecord(.change, entry.title, ok: false, detail: entry.message, date: entry.date))
        }
        journal = ctx.store.journal
        paused = ctx.store.paused
        startups = ctx.store.startups
        modes = ModesModel(ctx: ctx)
        cleanup = CleanupModel(ctx: ctx)
        storage = StorageModel(ctx: ctx)
        barFeeder = BarFeeder(ctx: ctx)
        instantSorter = InstantSorter(ctx: ctx)
        speedTracker = AppUsageTracker(readings: ctx.readings)
        heavyTracker = AppUsageTracker(readings: ctx.readings)
        publisher = SnapshotPublisher(store: SharedStore(practice: ctx.mode == .practice, home: ctx.paths.home))
        modes.changed = { [weak self] record in
            self?.publishSnapshot()
            self?.feedBar()
            self?.armModeAlarm()
            // What a mode couldn't do (a hand-edited file it left alone, say) is said once it's on.
            if let notes = record?.notes, !notes.isEmpty { self?.show(Toast(ok: false, message: notes.joined(separator: " "), journalID: nil)) }
        }
    }

    /// Tells the bar feeder what to show: the stats and clock, and the mode that's on.
    func feedBar() {
        barFeeder.update(running: status.menuBar.run.isRunning, barPID: status.menuBar.run.pid, bar: settings.bar,
                         palette: settings.palette, mode: modes.active.map { modes.name($0) })
    }

    public static func launch(mode: RunMode) -> AppModel {
        let model = AppModel(ctx: SystemContext.make(mode: mode))
        // Shortcuts, Siri, Focus, widgets and Control Center reach Orbit through this.
        OrbitBridge.handler = model
        let notifier = Notifier()
        notifier.model = model
        notifier.start()
        model.notifier = notifier
        model.showSetup = !model.settings.setupCompleted
        Task { await model.start() }
        return model
    }

    var isPractice: Bool { ctx.mode == .practice }
    var palette: Palette { settings.palette }

    var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
    }

    var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Good night" : hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        return "\(part), \(firstName)"
    }

    /// Whether the Mac started moments ago (Orbit opening as a login item, say). macOS and every other
    /// login item are busy then, so Orbit's own optional work waits a few minutes; its status check,
    /// shortcuts and the menu bar's numbers don't, as they're light and keep the bar's scripts quieter.
    static var macJustStarted: Bool { ProcessInfo.processInfo.systemUptime < 180 }

    func start() async {
        let justStarted = Self.macJustStarted
        // Paused, the mode that's on doesn't keep the Mac awake until Orbit is resumed.
        if paused == nil { modes.resume() }
        armModeAlarm()
        if justStarted, !isPractice, !isSnapshot {
            Task { [weak self] in await self?.timeStartup() }
        }
        // Low on disk: a notice at most once a day.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(justStarted ? 300 : 60))
            while !Task.isCancelled {
                self?.checkDiskSpace()
                try? await Task.sleep(for: .seconds(6 * 3600), tolerance: .seconds(600))
            }
        }
        // Apps left in the background that keep the Mac busy: a look every 5 minutes (a few milliseconds).
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(justStarted ? 300 : 60))
            while !Task.isCancelled {
                await self?.checkHeavyApps()
                try? await Task.sleep(for: .seconds(300), tolerance: .seconds(30))
            }
        }
        // The Doctor and the Speed check look once Orbit has settled (they read app bundles and folders).
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(justStarted ? 300 : 20))
            self?.runDoctor()
            self?.runSpeedCheck()
        }
        watchActivations()
        applyHotKey()
        publisher.startHeartbeat { [weak self] in self.map { $0.makeSnapshot() } }
        Task { _ = await readDockFinder() }
        Task { [weak self] in
            if justStarted { try? await Task.sleep(for: .seconds(120)) }
            await self?.keepOpeningAtLogin()
        }
        let wallpaper = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0)?.path(percentEncoded: false) }
        await actions.captureBaselineIfNeeded(wallpaper: wallpaper)
        actions.topUpBaseline()
        await refresh()
        watchForChanges()
        // Backups the undo history no longer points to go to the Trash, so they don't pile up over the months.
        Task.detached(priority: .background) { [actions] in
            if justStarted { try? await Task.sleep(for: .seconds(600)) }
            actions.clearUnneededBackups()
        }
        startPolling()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
        // Coming back to Orbit from System Settings checks again what the user changed there.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameToFront() }
        }
    }

    /// Keeps track of when each app was last in front (for "you haven't used it for a while").
    func watchActivations() {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path(percentEncoded: false) {
            speedTracker.noteActive(front)
            heavyTracker.noteActive(front)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [speedTracker, heavyTracker] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let path = app.bundleURL?.path(percentEncoded: false) else { return }
            speedTracker.noteActive(path)
            heavyTracker.noteActive(path)
        }
    }

    func cameToFront() {
        guard fixingTiling else { return }
        fixingTiling = false
        retryTiling()
    }

    /// Changes are noticed as they happen (see `watchForChanges`); this is only a safety net: every two
    /// minutes while an Orbit window can be seen, every fifteen otherwise.
    func startPolling() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let seen = NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
                try? await Task.sleep(for: .seconds(seen ? 120 : 900), tolerance: .seconds(10))
                await self?.refresh()
            }
        }
    }

    /// Re-checks when something actually changes: a config file or launch agent, the sorter's log, an
    /// app installed or removed, a managed app opening or quitting, a helper stopping, the Mac waking.
    func watchForChanges() {
        let paths = ctx.paths
        let folders = [".config/yabai", ".config/skhd", ".config/borders", ".config/sketchybar", ".config/karabiner",
                       "Library/LaunchAgents", "Library/Logs"].map(paths.at)
            + [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: Tool.homebrew + "/bin")]
        fileWatcher = FileWatcher(folders: folders) { [weak self] changed in
            guard changed.contains(where: Self.matters) else { return }
            Task { @MainActor in self?.requestRefresh() }
        }
        exitWatcher = ExitWatcher { [weak self] _ in
            Task { @MainActor in self?.requestRefresh() }
        }
        exitWatcher?.watch(status.helperPIDs)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? ""
                guard ManagedApp.all.contains(where: { $0.bundleID == id }) || id.hasPrefix("org.pqrs.") else { return }
                MainActor.assumeIsolated { self?.requestRefresh() }
            })
        }
        // Nothing to show while the screens sleep or another user's session is in front.
        let pauses: [(Notification.Name, Bool)] = [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                                                   (NSWorkspace.sessionDidResignActiveNotification, true),
                                                   (NSWorkspace.sessionDidBecomeActiveNotification, false)]
        for (name, paused) in pauses {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [barFeeder] _ in
                barFeeder.setPaused(paused)
            })
        }
        // A schedule is wall-clock time: a changed clock or time zone moves its alarm.
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            workspaceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.armModeAlarm() }
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.armModeAlarm()
                // Helpers are often still starting just after waking: judge nothing for a moment.
                self?.watchdog.hold(for: 30)
                self?.requestRefresh(after: .seconds(5))
            }
        })
    }

    /// Turns the watchdog's verdicts into what the pages show, and restarts what launchd won't.
    func applyWatchdog(to status: inout SystemStatus) {
        let paths = ctx.paths, files = ctx.files
        let verdicts = watchdog.observe(status) { KeepAlive.read(files.read(paths.launchAgent($0.label))) }
        var stopping: Set<Helper> = []
        for (helper, verdict) in verdicts {
            switch verdict {
            case .fine: break
            case .crashLoop(let detail), .gaveUp(let detail):
                status.mark(helper, .crashed(detail))
                stopping.insert(helper)
                guard !keepsStopping.contains(helper) else { continue }
                ctx.activity.record(ActivityRecord(.watchdog, "\(helper.title.capitalizedFirst) keeps stopping", ok: false, detail: detail))
                OrbitLog.watchdog.error("\(helper.label, privacy: .public): \(detail, privacy: .public)")
                notifier?.send(.keepsStopping, key: "stopping \(helper)", title: "\(helper.title.capitalizedFirst) keeps stopping",
                               body: detail, page: .health)
            case .restart(let delay): scheduleRestart(helper, after: delay)
            }
        }
        for helper in keepsStopping.subtracting(stopping) {
            ctx.activity.record(ActivityRecord(.watchdog, "\(helper.title.capitalizedFirst) is running steadily again"))
        }
        keepsStopping = stopping
    }

    /// Starts a helper again after `seconds`, through the change lane. Practice mode only reports.
    func scheduleRestart(_ helper: Helper, after seconds: TimeInterval) {
        guard ctx.mode == .live, pendingRestarts.insert(helper).inserted else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            pendingRestarts.remove(helper)
            watchdog.restarted(helper)
            let running = await ctx.lane.run("Start \(helper.title) again") { [actions] in await actions.kickstart(helper) }
            ctx.activity.record(ActivityRecord(.watchdog, "Started \(helper.title) again after it stopped", ok: running))
            requestRefresh()
        }
    }

    /// Whether a changed file can affect what Orbit shows (its own logs folder holds plenty that can't).
    nonisolated static func matters(_ path: String) -> Bool {
        !path.contains("/Library/Logs/") || path.contains("/sort-downloads.")
    }

    /// Something changed: check again in a moment, merging a burst of events into one check.
    func requestRefresh(after delay: Duration = .milliseconds(250)) {
        refreshPending?.cancel()
        refreshPending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    public func refresh(deep: Bool = false) async {
        guard !isSnapshot else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        if deep { deepChecking = true }
        var fresh = await probes.all(deep: deep)
        if deep { deepChecking = false }
        // A check that started later has newer news.
        guard generation == refreshGeneration else { return }
        applyWatchdog(to: &fresh)
        // Only what changed is handed to the views, so a quiet check redraws nothing.
        if status.checkedAt == nil || !fresh.sameReadings(as: status) { status = fresh }
        let saved = ctx.store.settings
        if saved != settings { settings = saved }
        let history = ctx.store.journal
        if history != journal { journal = history }
        let pausedNow = ctx.store.paused
        if pausedNow != paused { paused = pausedNow }
        let practice = ctx.practiceLog.all
        if practice != practiceLog { practiceLog = practice }
        exitWatcher?.watch(fresh.helperPIDs)
        feedBar()
        publishSnapshot()
        noticeNewAttention()
        syncInstantSorting()
        showLoginStatus(await Task.detached { SMAppService.mainApp.status }.value)
    }

    /// Reads the Dock and Finder again (off the main thread) and keeps what it found.
    func readDockFinder() async -> DockFinderReading {
        let fresh = await Task.detached(priority: .userInitiated) { DockFinderReading.read() }.value
        if fresh != dockFinder { dockFinder = fresh }
        return fresh
    }

    func state(_ id: FeatureID) -> FeatureState { status.state(id) }

    var coreFeatures: [FeatureID] { FeatureID.allCases }
    var doneCount: Int { coreFeatures.filter { state($0).isOn }.count }
    var attention: [FeatureID] { coreFeatures.filter { state($0).needsAttention } }

    // MARK: Running changes

    typealias Work = @Sendable (WritePolicy) async throws -> ActionOutcome

    /// Runs a change, records how to undo it, shows the result, then re-checks. The same change never
    /// runs twice at once (a double click would undo-log a half state): a request that arrives while
    /// it's running waits, and only the newest waiting one runs (a colour drag sends dozens).
    /// `lane: false` is for things that change nothing shared and may take minutes (opening or
    /// installing an app), which shouldn't hold up every other change.
    func perform(_ key: String, _ title: String, lane: Bool = true, _ work: @escaping Work) {
        // Marked busy here, before the task starts, so a quick second click sees it.
        guard busy.insert(key).inserted else {
            queued[key] = (title, work)
            return
        }
        Task { await run(key, title, .askIfEdited, lane: lane, work) }
    }

    /// Like `perform`, but waits and reports whether it worked (used by the guided setup).
    @discardableResult
    func performNow(_ key: String, _ title: String, quiet: Bool = false, _ work: @escaping Work) async -> (ok: Bool, message: String) {
        guard busy.insert(key).inserted else { return (false, "Orbit is still working on that.") }
        return await run(key, title, .askIfEdited, quiet: quiet, work)
    }

    /// Runs a change whose key the caller has marked busy, and frees the key when it's done.
    @discardableResult
    private func run(_ key: String, _ title: String, _ policy: WritePolicy, quiet: Bool = false, lane: Bool = true,
                     _ work: @escaping Work) async -> (ok: Bool, message: String) {
        defer { finished(key) }
        var result = (ok: false, message: "")
        let change = UUID()
        let attempt: @Sendable () async -> Result<ActionOutcome, any Error> = { [store = ctx.store] in
            // Noted before anything changes, and each undo step as it's recorded: if Orbit stops part-way,
            // the next launch can still undo what was done.
            store.beginChange(change, title: title)
            return await UndoRecorder.$change.withValue(change) {
                do { return .success(try await work(policy)) } catch { return .failure(error) }
            }
        }
        do {
            let outcome = try await (lane ? ctx.lane.run(title, attempt) : attempt()).get()
            let id = record(title, outcome.ok, outcome.message, undo: outcome.undo, change: change)
            result = (outcome.ok, outcome.message)
            if !quiet { show(Toast(ok: outcome.ok, message: outcome.message, journalID: id)) }
            if !outcome.ok { notifyFailure(title, outcome.message) { [weak self] in self?.perform(key, title, work) } }
        } catch let edited as EditedByHand {
            // Most changes stop before touching anything. Pause goes on past a hand-edited file to switch
            // off the rest, and what it did stays in the history so Undo can still put it back.
            let done = ctx.store.inflight.first { $0.id == change }?.actions ?? []
            if done.isEmpty {
                ctx.store.endChange(change)
            } else {
                record(title, true, "Part-way: \(edited.file.title) were edited by hand.", undo: done, change: change)
                requestRefresh(after: .milliseconds(300))
            }
            // Asked from outside the window: the question waits in Orbit, and a notice says so.
            if quiet {
                notifier?.send(.edited, key: "edited \(edited.file)", title: "Orbit didn't change \(edited.file.title)",
                               body: "They were edited by hand. Open Orbit to compare and choose.") { [weak self] in self?.openMainWindow() }
            }
            // Returning now frees `key` before the user can answer. Their OK covers only the file they
            // were shown: any other hand-edited file in the same change still gets its own question.
            let next = policy.approving(edited.file)
            conflict = Conflict(file: edited.file, proposed: edited.proposed) { [weak self] in
                guard let self, busy.insert(key).inserted else { return }
                await run(key, title, next, work)
            }
            return (false, "\(edited.file.title) were edited by hand.")
        } catch {
            result = (false, error.localizedDescription)
            record(title, false, error.localizedDescription, undo: [], change: change)
            if !quiet { show(Toast(ok: false, message: error.localizedDescription, journalID: nil)) }
            notifyFailure(title, error.localizedDescription) { [weak self] in self?.perform(key, title, work) }
        }
        settings = ctx.store.settings
        try? await Task.sleep(for: .milliseconds(300))
        await refresh()
        // Helpers can take a moment to start (or to fail): look once more shortly.
        requestRefresh(after: .seconds(2))
        return result
    }

    /// Notes a change in the history (with Undo when there's something to undo; failures too, so they
    /// show up) and in the activity log, under the id it ran with. Returns the history entry Undo can use.
    @discardableResult
    func record(_ title: String, _ ok: Bool, _ message: String, undo: [UndoAction], change: UUID = UUID()) -> UUID? {
        ctx.activity.record(ActivityRecord(.change, title, ok: ok, detail: ok ? nil : message))
        var entry = JournalEntry(id: change, title: title, actions: undo)
        if !ok {
            entry.outcome = .failed
            entry.message = message
        }
        ctx.store.append(entry)
        return undo.isEmpty ? nil : entry.id
    }

    /// A change that didn't work while Orbit's window wasn't in front (from the menu bar panel, say).
    func notifyFailure(_ title: String, _ message: String, retry: @escaping () -> Void) {
        notifier?.send(.failed, key: "failed \(title)", title: "\(title) didn't work", body: message, page: .health, act: retry)
    }

    private func finished(_ key: String) {
        busy.remove(key)
        if let next = queued.removeValue(forKey: key) { perform(key, next.title, next.work) }
    }

    func show(_ toast: Toast) {
        withAnimation(Motion.animation(.spring(duration: 0.4))) { self.toast = toast }
        let id = toast.id
        Task {
            try? await Task.sleep(for: .seconds(toast.journalID == nil ? 5 : 9))
            if self.toast?.id == id { withAnimation { self.toast = nil } }
        }
    }

    func undo(_ id: UUID, evenIfOvertaken: Bool = false) {
        guard let entry = ctx.store.journal.first(where: { $0.id == id }), !entry.undone else { return }
        // Undoing an older change also puts back what later changes did to the same things: ask first.
        let later = entry.overtaken(in: ctx.store.journal)
        if !later.isEmpty, !evenIfOvertaken {
            undoQuestion = UndoQuestion(entry: entry, later: later)
            return
        }
        guard busy.insert("undo").inserted else { return }
        toast = nil
        Task {
            let outcome = await ctx.lane.run("Undo \(entry.title)") { [actions] in await actions.undo(entry.actions) }
            ctx.store.markUndone(id)
            show(Toast(ok: outcome.ok, message: outcome.ok ? "Undid \"\(entry.title)\"." : outcome.message, journalID: nil))
            try? await Task.sleep(for: .milliseconds(300))
            await refresh()
            requestRefresh(after: .seconds(2))
            busy.remove("undo")
        }
    }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    /// Before quitting: lets a change under way finish (ten seconds at most; one cut off even so shows
    /// as interrupted, with Undo, next time) and hands the menu bar's numbers back to its scripts.
    public func prepareToQuit() async {
        _ = await finishChanges(within: .seconds(10))
        await barFeeder.handBack()
        await instantSorter.stop()
        if !isSnapshot { publisher.stopped() }
    }

    /// What the widgets and Control Center switches show.
    func makeSnapshot() -> OrbitSnapshot {
        OrbitSnapshot(practice: isPractice,
                      features: coreFeatures.map { OrbitSnapshot.Feature(id: $0, state: OrbitSnapshot.State(state($0)), detail: state($0).detail) },
                      modes: settings.modes.map { OrbitSnapshot.Mode(id: $0.id, name: $0.name, symbol: $0.symbol) },
                      activeMode: modes.active?.modeID, theme: settings.theme, pausedSince: paused?.since)
    }

    func publishSnapshot() {
        guard !isSnapshot, status.checkedAt != nil else { return }
        publisher.publish(makeSnapshot())
    }

    // MARK: Mode timers and schedules

    /// One alarm for the next thing a mode does by itself, set again whenever that could have moved:
    /// a mode going on or off, modes edited, the Mac waking, the clock or time zone changing.
    func armModeAlarm(now: Date = Date()) {
        modeAlarm?.cancel()
        guard !isSnapshot else { return }
        let active = modes.active.map { ModeAlarm.Active(modeID: $0.modeID, started: $0.started, endsAt: $0.endsAt, bySchedule: $0.bySchedule) }
        guard let alarm = ModeAlarm.next(after: now, modes: settings.modes, active: active) else { return }
        modeAlarm = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, alarm.date.timeIntervalSinceNow)), tolerance: .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.alarmFired(alarm)
            self?.armModeAlarm()
        }
    }

    func alarmFired(_ alarm: ModeAlarm) async {
        switch alarm {
        case .stop(let id, _, let reason):
            guard modes.active?.modeID == id else { return }
            let name = settings.modes.first { $0.id == id }?.name ?? id
            await modes.stop()
            ctx.activity.record(ActivityRecord(.change, "Switched off \(name) mode", detail: reason.capitalizedFirst + "."))
        case .start(let id, _, let askFirst):
            // Paused, Orbit starts nothing by itself.
            guard paused == nil, let mode = settings.modes.first(where: { $0.id == id }), modes.active?.modeID != id else { return }
            if askFirst {
                notifier?.send(.modeSchedule, key: "schedule \(id)", title: "Start \(mode.name) mode?",
                               body: "It's time for \(mode.name) mode. \(mode.blurb)", every: 300) { [weak self] in
                    Task { await self?.modes.toggle(mode, bySchedule: true) }
                }
            } else {
                await modes.toggle(mode, bySchedule: true)
            }
        }
    }

    /// Whether a change is under way (quitting waits for it).
    public var isChanging: Bool { !ctx.lane.isIdle }

    /// Waits up to `limit` for the changes under way to finish; false if they hadn't by then.
    public func finishChanges(within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !ctx.lane.isIdle {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// How much space Orbit's own files take: settings, undo history and backups.
    func storageUsed() async -> Int64 {
        await Task.detached { [actions] in actions.storageUsed() }.value
    }

    // MARK: Features

    /// Flips a feature's switch from the window.
    func setFeature(_ id: FeatureID, on: Bool) {
        guard let change = featureChange(id, on: on) else { return }
        perform(change.key, change.title, change.work)
    }

    func setTiling(_ on: Bool) { setFeature(.tiling, on: on) }

    func applyTiling(_ tiling: TilingSettings) {
        settings.tiling = tiling
        perform("tilingSettings", "Changed window arrangement") { [actions] in
            try await actions.applyTiling(tiling, policy: $0)
        }
    }

    func setGlow(_ on: Bool) { setFeature(.glow, on: on) }

    func setSpaceLayout(_ space: Int, _ layout: TilingLayout?) {
        let title = layout.map { "Desktop \(space) uses \($0.title.lowercased()) windows" } ?? "Desktop \(space) uses the shared window style"
        perform("spaceLayout-\(space)", title) { [actions] in try await actions.setSpaceLayout(space, layout, policy: $0) }
    }

    func saveWindowLayout(_ name: String) {
        perform("saveLayout", "Saved the window arrangement \"\(name)\"") { [actions] _ in await actions.saveWindowLayout(name: name) }
    }

    func deleteWindowLayout(_ layout: WindowLayout) {
        perform("deleteLayout-\(layout.id)", "Deleted the window arrangement \"\(layout.name)\"") { [actions] _ in
            await actions.deleteWindowLayout(layout.id)
        }
    }

    func applyFloatingApps(_ apps: [String]) {
        settings.floatingApps = apps
        perform("floatingApps", "Changed which apps float") { [actions] in try await actions.applyFloatingApps(apps, policy: $0) }
    }

    func applyGlow(_ glow: GlowSettings) {
        settings.glow = glow
        perform("glowSettings", "Changed the window glow") { [actions] in
            try await actions.applyGlow(glow, policy: $0)
        }
    }

    func setMenuBar(_ on: Bool) { setFeature(.menuBar, on: on) }

    func applyBar(_ bar: BarSettings) {
        settings.bar = bar
        perform("barSettings", "Changed what the menu bar shows") { [actions] in
            try await actions.applyBar(bar, policy: $0)
        }
    }

    func setDownloads(_ on: Bool) { setFeature(.downloads, on: on) }

    /// Instant sorting runs while the Downloads feature is on and the user wants it (live mode only).
    func syncInstantSorting() {
        let wanted = !isPractice && !isSnapshot && settings.downloads.instant && state(.downloads).isOn
        let downloads = settings.downloads
        if wanted != sortingInstantly { sortingInstantly = wanted }
        // The hourly sorter learns to stand down while Orbit sorts (only if it's still Orbit's own script).
        if wanted, !sorterScriptChecked {
            sorterScriptChecked = true
            let current = ctx.files.read(ctx.paths.sorterScript)
            if current != Data(SorterScript.render(downloads).utf8),
               ctx.store.registry.verdict(for: .sorterScript, current: current) == .safe {
                perform("downloadsRules", "Updated the hourly Downloads sorter") { [actions] in
                    try await actions.applyDownloads(downloads, policy: $0)
                }
            }
        }
        // Just after the Mac starts, the first look through Downloads waits until things calm down.
        let firstLook: Duration = Self.macJustStarted ? .seconds(90) : .seconds(1)
        Task { [instantSorter] in
            if wanted { await instantSorter.start(downloads, firstLook: firstLook); await instantSorter.update(downloads) } else { await instantSorter.stop() }
        }
    }

    func applyDownloads(_ downloads: DownloadSettings) {
        settings.downloads = downloads
        perform("downloadsRules", "Changed how Downloads are sorted") { [actions] in try await actions.applyDownloads(downloads, policy: $0) }
    }

    func putBack(_ entry: SorterLog.Entry) {
        perform("putBack-\(entry.destination)", "Put \(entry.file) back in Downloads", lane: false) { [actions] _ in actions.putBack(entry) }
    }

    func sortDownloadsNow() {
        perform("sortNow", "Sorted Downloads", lane: false) { [actions] _ in await actions.sortDownloadsNow() }
    }

    func open(_ app: ManagedApp) {
        perform(app.id.rawValue, "Opened \(app.name)", lane: false) { [actions] _ in await actions.open(app) }
    }

    func install(_ app: ManagedApp) {
        perform(app.id.rawValue, "Installed \(app.name)", lane: false) { [actions] _ in await actions.install(app) }
    }

    func setLoginItem(_ app: ManagedApp, on: Bool) {
        perform("login-\(app.id.rawValue)", on ? "\(app.name) opens at login" : "\(app.name) stops opening at login") { [actions] _ in
            await actions.setLoginItem(app, on: on)
        }
    }

    func setPreferences(_ title: String, _ changes: [Actions.PreferenceChange]) {
        perform("prefs-\(title)", title) { [actions] _ in await actions.setPreferences(changes, message: "\(title).") }
    }

    func restoreBaseline() {
        let themedWallpaper = settings.wallpaperFollowsTheme
        perform("restore", "Went back to before Orbit") { [actions] _ in await actions.restoreBaseline() }
        // Orbit drew the current wallpaper: the one from before comes back.
        if themedWallpaper { restoreOriginalWallpaper() }
    }

    func resetDockAndFinder() {
        perform("resetDock", "Reset the Dock and Finder") { [actions] _ in await actions.resetDockAndFinder() }
    }

    func putProjectsBack() {
        perform("projectsBack", "Moved projects back to the Desktop") { [actions] _ in await actions.putProjectsBackOnDesktop() }
    }

    func openSettings(_ pane: SettingsPane, fixingTiling: Bool = false) {
        if fixingTiling { self.fixingTiling = true }
        if let url = URL(string: pane.url) { NSWorkspace.shared.open(url) }
    }

    /// yabai only checks for Accessibility as it starts, so after a trip to System Settings a stopped
    /// tiling helper gets one more start. Only once per trip: each failed start can make macOS ask again.
    func retryTiling() {
        guard status.tiling.installed, !state(.tiling).isOn else { return }
        Task {
            await performNow("tiling", "Started window tiling again", quiet: true) { [actions] _ in await actions.retryTiling() }
            if state(.tiling).isOn { show(Toast(ok: true, message: "Window tiling is working now.", journalID: nil)) }
        }
    }

    /// The most helpful next step for a feature that needs attention.
    func fix(_ id: FeatureID) {
        switch state(id) {
        case .needsPermission(let kind, _):
            if kind == .firstOpen, let app = ManagedApp.all.first(where: { $0.id == id }) {
                open(app)
            } else {
                openSettings(.for(kind), fixingTiling: id == .tiling)
            }
        case .blocked:
            if id == .tiling, status.tiling.problem == .duplicate || status.tiling.stalePlistExists {
                setTiling(true)
            } else if id == .tiling, status.tiling.problem == .separateSpacesOff {
                openSettings(.desktopAndDock)
            } else if id == .menuBar {
                setMenuBar(true)
            } else {
                page = .health
            }
        default:
            break
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        ctx.store.updateSettings { $0.openAtLogin = on }
        settings = ctx.store.settings
        guard !isPractice else {
            ctx.practiceLog.record(on ? "Would open Orbit when you log in" : "Would stop opening Orbit when you log in", "SMAppService.mainApp")
            practiceLog = ctx.practiceLog.all
            return
        }
        Task {
            // ServiceManagement answers over IPC: asked off the main thread.
            let (problem, status) = await Task.detached { () -> (String?, SMAppService.Status) in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    return (nil, SMAppService.mainApp.status)
                } catch {
                    return (error.localizedDescription, SMAppService.mainApp.status)
                }
            }.value
            if let problem { show(Toast(ok: false, message: "macOS didn't allow it: \(problem)", journalID: nil)) }
            showLoginStatus(status)
            if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    func showLoginStatus(_ status: SMAppService.Status) {
        if launchAtLogin != (status == .enabled) { launchAtLogin = status == .enabled }
        if loginNeedsApproval != (status == .requiresApproval) { loginNeedsApproval = status == .requiresApproval }
    }

    /// Orbit opens quietly at login unless the user turned that off: registered from the installed copy,
    /// again if macOS lost track of it (after an update, say), never while macOS waits for the user's OK.
    func keepOpeningAtLogin() async {
        guard !isPractice, !isSnapshot else { return }
        let installed = Bundle.main.bundleURL.path(percentEncoded: false).hasPrefix("/Applications/")
        let choice = settings.openAtLogin
        let (registered, status) = await Task.detached { () -> (Bool, SMAppService.Status) in
            guard Self.shouldRegisterAtLogin(choice: choice, status: SMAppService.mainApp.status, installed: installed) else {
                return (false, SMAppService.mainApp.status)
            }
            try? SMAppService.mainApp.register()
            return (true, SMAppService.mainApp.status)
        }.value
        if registered {
            ctx.activity.record(ActivityRecord(.change, "Orbit will open at login", ok: status == .enabled))
        }
        showLoginStatus(status)
    }

    nonisolated static func shouldRegisterAtLogin(choice: Bool?, status: SMAppService.Status, installed: Bool) -> Bool {
        installed && choice != false && (status == .notRegistered || status == .notFound)
    }

    func completeSetup() {
        ctx.store.updateSettings { $0.setupCompleted = true }
        settings = ctx.store.settings
        showSetup = false
    }

    // MARK: Search

    public func focusSearch() {
        openMainWindow()
        searchRequest += 1
    }

    // MARK: Modes

    /// Saves a mode the user edited or created.
    /// Saves a mode the user edited or created, in the history with Undo.
    func saveMode(_ mode: ModeDefinition) {
        let isNew = !settings.modes.contains { $0.id == mode.id }
        Task {
            await performNow("modes", isNew ? "Added \(mode.name) mode" : "Edited \(mode.name) mode") { [actions] _ in
                actions.editSettings(isNew ? "Added \(mode.name) mode." : "Saved \(mode.name) mode.") { s in
                    if let i = s.modes.firstIndex(where: { $0.id == mode.id }) { s.modes[i] = mode } else { s.modes.append(mode) }
                }
            }
            modesEdited?()
            armModeAlarm()
        }
    }

    func deleteMode(_ id: String) {
        let name = settings.modes.first { $0.id == id }?.name ?? "The mode"
        Task {
            await performNow("modes", "Deleted \(name) mode") { [actions] _ in
                actions.editSettings("\(name) mode is deleted.") { $0.modes.removeAll { $0.id == id } }
            }
            modesEdited?()
            armModeAlarm()
        }
    }

    /// Puts one of the four built-in modes back the way Orbit ships it.
    func resetMode(_ id: String) {
        guard let original = ModeDefinition.defaults.first(where: { $0.id == id }) else { return }
        saveMode(original)
    }

    // MARK: Desktop

    func tidyDesktop(_ plan: [TidyMove]) {
        perform("tidyDesktop", "Tidied the Desktop") { [actions] _ in actions.tidyDesktop(plan) }
    }
}
