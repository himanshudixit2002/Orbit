import AppKit
import Foundation
import OrbitCore
import ServiceManagement

public struct TilingStatus: Sendable, Equatable {
    public init() {}

    public var installed = false
    public var yabai = HelperRun.notLoaded
    public var skhd = HelperRun.notLoaded
    public var yabaiPlistExists = false
    public var stalePlistExists = false
    /// "Allow in the Background" is off for yabai or skhd, so macOS won't start it at login.
    public var backgroundBlocked = false
    public var problem: HelperProblem?

    public var state: FeatureState {
        if !installed { return .notInstalled }
        if case .crashed? = problem { return problem!.state }
        if yabai.isRunning && skhd.isRunning {
            if stalePlistExists { return HelperProblem.duplicate.state }
            if backgroundBlocked {
                return .needsPermission(.backgroundItems, "Working now, but it won't start again after a restart until it's switched on under Login Items → Allow in the Background.")
            }
            return .on
        }
        if let problem { return problem.state }
        if yabai.isRunning { return .needsPermission(.accessibility, "Tiling works, but its keyboard shortcuts need Accessibility.") }
        return .off
    }
}

public struct ServiceStatus: Sendable, Equatable {
    public init() {}

    public var installed = false
    public var run = HelperRun.notLoaded
    /// Set by the watchdog when the helper keeps stopping.
    public var problem: HelperProblem?

    public var state: FeatureState {
        if !installed { return .notInstalled }
        if let problem { return problem.state }
        return run.isRunning ? .on : .off
    }
}

public struct MenuBarStatus: Sendable, Equatable {
    public init() {}

    public var installed = false
    public var run = HelperRun.notLoaded
    public var macMenuBarHidden = false
    public var pluginsMissing: [String] = []
    /// Set by the watchdog when the bar keeps stopping.
    public var problem: HelperProblem?

    public var state: FeatureState {
        if !installed { return .notInstalled }
        if let problem { return problem.state }
        if run.isRunning { return macMenuBarHidden ? .on : .blocked("It's on, but the Mac's own menu bar is still showing over it.") }
        return .off
    }
}

public struct KeyboardStatus: Sendable, Equatable {
    public init() {}

    public var installed = false
    public var driver = DriverState.missing
    public var running = false
    public var rulesActive = false

    public var state: FeatureState {
        if !installed { return .notInstalled }
        if driver != .enabled {
            return .needsPermission(.driverExtension, "Karabiner's keyboard driver needs your OK in System Settings.")
        }
        return rulesActive && running ? .on : .off
    }
}

public struct DownloadsStatus: Sendable, Equatable {
    public init() {}

    public var installed = false
    public var run = HelperRun.notLoaded
    public var disabled = false
    public var log = SorterLog()
    /// When the sorter last got into Downloads.
    public var lastChecked: Date?

    public var state: FeatureState {
        if !installed { return .notInstalled }
        if !run.isLoaded || disabled { return .off }
        if log.isBlocked(checkedAt: lastChecked) { return .needsPermission(.filesAndFolders, "\"Downloads Sorter\" needs permission to open your Downloads folder.") }
        return .on
    }
}

public struct AppStatus: Sendable, Equatable {
    public init() {}

    public var installed = false
    public var running = false
    public var quickLook: QuickLookState?

    public var state: FeatureState {
        if !installed { return .notInstalled }
        if let quickLook {
            switch quickLook {
            case .enabled: return .on
            case .disabled: return .off
            case .notRegistered: return .needsPermission(.firstOpen, "Open it once so macOS starts using it.")
            }
        }
        return running ? .on : .off
    }
}

/// The apps Orbit looks after on the Apps page.
public struct ManagedApp: Sendable, Identifiable, Equatable {
    public let id: FeatureID
    public let name: String
    public let bundleID: String
    public let path: String
    public let cask: String
    public let symbol: String
    public let blurb: String
    public let permissions: [PermissionKind]
    public let quickLookExtension: String?

    public static let all: [ManagedApp] = [
        ManagedApp(id: .raycast, name: "Raycast", bundleID: "com.raycast.macos", path: "/Applications/Raycast.app",
                   cask: "raycast", symbol: "magnifyingglass", blurb: "Find and open anything from the keyboard.",
                   permissions: [.accessibility], quickLookExtension: nil),
        ManagedApp(id: .altTab, name: "AltTab", bundleID: "com.lwouis.alt-tab-macos", path: "/Applications/AltTab.app",
                   cask: "alt-tab", symbol: "rectangle.on.rectangle", blurb: "⌘Tab shows live previews of your windows.",
                   permissions: [.accessibility, .screenRecording], quickLookExtension: nil),
        ManagedApp(id: .ice, name: "Ice", bundleID: "com.jordanbaird.Ice", path: "/Applications/Ice.app",
                   cask: "jordanbaird-ice", symbol: "menubar.rectangle", blurb: "Tucks menu bar icons out of the way.",
                   permissions: [.accessibility, .screenRecording], quickLookExtension: nil),
        ManagedApp(id: .syntaxHighlight, name: "Syntax Highlight", bundleID: "org.sbarex.SourceCodeSyntaxHighlight",
                   path: "/Applications/Syntax Highlight.app", cask: "syntax-highlight", symbol: "chevron.left.forwardslash.chevron.right",
                   blurb: "Press space on a code file in Finder for a coloured preview.",
                   permissions: [.firstOpen], quickLookExtension: "org.sbarex.SourceCodeSyntaxHighlight.QuickLookExtension")
    ]
}

/// Everything Orbit knows about the Mac right now.
public struct SystemStatus: Sendable, Equatable {
    public var tiling = TilingStatus()
    public var glow = ServiceStatus()
    public var menuBar = MenuBarStatus()
    public var keyboard = KeyboardStatus()
    public var downloads = DownloadsStatus()
    public var apps: [FeatureID: AppStatus] = [:]
    public var terminalThemed = false
    public var checkedAt: Date?
    /// launchd's details for helpers it was asked about this check (those that weren't running).
    public var jobs: [Helper: LaunchdJob] = [:]

    public init() {}

    /// Notes a helper's problem on the feature it belongs to (a problem already found stays).
    public mutating func mark(_ helper: Helper, _ problem: HelperProblem) {
        switch helper {
        // What the helpers' own messages explain (Accessibility, say) says more than "keeps stopping".
        case .yabai, .skhd: if tiling.problem == nil { tiling.problem = problem }
        case .borders: glow.problem = problem
        case .sketchybar: menuBar.problem = problem
        case .sorter: break
        }
    }

    public func run(of helper: Helper) -> HelperRun {
        switch helper {
        case .yabai: tiling.yabai
        case .skhd: tiling.skhd
        case .borders: glow.run
        case .sketchybar: menuBar.run
        case .sorter: downloads.run
        }
    }

    /// The background helpers running now, to be told the moment one stops.
    public var helperPIDs: Set<Int32> {
        Set([tiling.yabai, tiling.skhd, glow.run, menuBar.run].compactMap { $0.pid.map(Int32.init) })
    }

    /// The same readings, whenever each was taken: an unchanged status needn't redraw anything.
    public func sameReadings(as other: SystemStatus) -> Bool {
        var mine = self, theirs = other
        mine.checkedAt = nil
        theirs.checkedAt = nil
        return mine == theirs
    }

    public func state(_ id: FeatureID) -> FeatureState {
        guard checkedAt != nil else { return .unknown }
        switch id {
        case .tiling: return tiling.state
        case .glow: return glow.state
        case .menuBar: return menuBar.state
        case .capsLock: return keyboard.state
        case .downloads: return downloads.state
        case .terminalLook: return terminalThemed ? .on : .off
        case .raycast, .altTab, .ice, .syntaxHighlight: return apps[id]?.state ?? .unknown
        }
    }
}

/// Read-only checks. Nothing here changes the Mac, so they run in practice mode too.
public struct Probes: Sendable {
    let ctx: SystemContext
    /// Slow answers that rarely change, kept between checks.
    let cache = ProbeCache()

    public init(_ ctx: SystemContext) { self.ctx = ctx }

    func exists(_ path: String) -> Bool { ctx.readings.installed(path) }

    /// What every check in one pass shares, each read once: launchd's switched-off list and the
    /// process table.
    struct Pass: Sendable {
        let disabled: [String: Bool]
        let processes: [RunningProcess]
        /// launchd's details for each helper it was asked about, gathered as the checks run.
        let jobs = Locked<[Helper: LaunchdJob]>([:])

        /// A helper launchd started and is running now, found without asking launchctl.
        func running(_ helper: Helper) -> RunningProcess? {
            guard let name = helper.processName else { return nil }
            return processes.first { $0.name == name && $0.parent == 1 }
        }
    }

    func pass() async -> Pass {
        let disabled = LaunchctlParser.disabled(await ctx.run(Commands.launchctlPrintDisabled(uid: ctx.uid)).stdout)
        return Pass(disabled: disabled, processes: ctx.readings.processes())
    }

    /// A helper's state: straight from the process table while it runs, else from launchd, which also
    /// knows whether it's loaded and how it last ended.
    func helper(_ helper: Helper, in pass: Pass) async -> HelperRun {
        if let process = pass.running(helper) { return .loaded(running: true, pid: Int(process.pid), lastExit: nil) }
        let result = await ctx.run(Commands.launchctlPrint(helper.label, uid: ctx.uid))
        let run = LaunchctlParser.run(result)
        if run.isLoaded { pass.jobs.withLock { $0[helper] = LaunchdJob.parse(result.stdout) } }
        return run
    }

    /// The last few kilobytes a helper wrote to its error log.
    func tail(_ path: String, bytes: Int = 4096) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    }

    /// The last lines a helper wrote to its error log, newest last.
    public func recentErrors(_ helper: Helper, lines: Int = 8) -> [String] {
        guard let path = helper.errorLog(user: NSUserName()) else { return [] }
        return Array(tail(path).split(separator: "\n").suffix(lines).map(String.init))
    }

    /// Checks everything. `deep` forgets the kept answers and asks again.
    @concurrent public func all(deep: Bool = false) async -> SystemStatus {
        if deep { cache.clear() }
        let pass = await pass()
        async let tiling = tiling(pass)
        async let glow = service(.borders, pass)
        async let menuBar = menuBar(pass)
        async let keyboard = keyboard(pass)
        async let downloads = downloads(pass)
        async let apps = apps()
        var status = SystemStatus()
        status.tiling = await tiling
        status.glow = await glow
        status.menuBar = await menuBar
        status.keyboard = await keyboard
        status.downloads = await downloads
        status.apps = await apps
        status.terminalThemed = terminalThemed()
        status.jobs = pass.jobs.current
        status.checkedAt = Date()
        return status
    }

    public func tiling() async -> TilingStatus { await tiling(await pass()) }
    public func service(_ helper: Helper) async -> ServiceStatus { await service(helper, await pass()) }
    public func menuBar() async -> MenuBarStatus { await menuBar(await pass()) }
    public func keyboard() async -> KeyboardStatus { await keyboard(await pass()) }
    public func downloads() async -> DownloadsStatus { await downloads(await pass()) }

    @concurrent func tiling(_ pass: Pass) async -> TilingStatus {
        var status = TilingStatus()
        status.installed = exists(Tool.yabai) && exists(Tool.skhd)
        guard status.installed else { return status }
        async let yabai = helper(.yabai, in: pass)
        async let skhd = helper(.skhd, in: pass)
        status.yabai = await yabai
        status.skhd = await skhd
        status.yabaiPlistExists = ctx.files.exists(ctx.paths.launchAgent(Helper.yabai.label))
        status.stalePlistExists = ctx.files.exists(ctx.paths.launchAgent(Helper.staleYabaiLabel))
        // Even while running, macOS may stop them starting again at the next login.
        status.backgroundBlocked = [Helper.yabai, .skhd].contains { ctx.readings.backgroundBlocked(ctx.paths.launchAgent($0.label)) }
        if status.yabai.isRunning && status.skhd.isRunning { return status }

        // Something that should run isn't: work out why from the helpers' own messages.
        let user = NSUserName()
        // Switching tiling off stops and disables both helpers but leaves yabai's plist (and its old
        // error log) behind: that's plain Off, not a problem to explain.
        let switchedOff = pass.disabled[Helper.yabai.label] == true
        let wantsRunning = !switchedOff && (status.yabaiPlistExists || status.yabai.isLoaded || status.skhd.isLoaded)
        if wantsRunning {
            if !status.skhd.isRunning, let problem = HelperLogClassifier.classify(tail("/tmp/skhd_\(user).err.log")) {
                status.problem = problem
            }
            if !status.yabai.isRunning, let problem = HelperLogClassifier.classify(tail("/tmp/yabai_\(user).err.log")) {
                status.problem = problem
            }
            if status.problem == nil, status.backgroundBlocked { status.problem = .notAllowedInBackground }
        }
        return status
    }

    @concurrent func service(_ helper: Helper, _ pass: Pass) async -> ServiceStatus {
        var status = ServiceStatus()
        status.installed = helper.binary.map(exists) ?? true
        // Nothing to ask launchd about a helper that isn't there.
        guard status.installed else { return status }
        status.run = await self.helper(helper, in: pass)
        return status
    }

    @concurrent func menuBar(_ pass: Pass) async -> MenuBarStatus {
        var status = MenuBarStatus()
        status.installed = exists(Tool.sketchybar)
        status.macMenuBarHidden = Preferences.read(WatchedPreferences.globalDomain, "_HIHideMenuBar")?.boolValue ?? false
        guard status.installed else { return status }
        status.run = await helper(.sketchybar, in: pass)
        let plugins = ctx.paths.sketchybarDir.appending(path: "plugins")
        status.pluginsMissing = SketchyBarConfig.plugins.keys.sorted().filter { !ctx.files.exists(plugins.appending(path: $0)) }
        return status
    }

    @concurrent func keyboard(_ pass: Pass) async -> KeyboardStatus {
        var status = KeyboardStatus()
        status.installed = exists("/Applications/Karabiner-Elements.app")
        guard status.installed else { return status }
        status.driver = await karabinerDriver()
        status.running = pass.processes.contains { $0.name.localizedCaseInsensitiveContains("karabiner") }
        status.rulesActive = KarabinerConfig.capsLockActive(in: ctx.files.read(ctx.paths.karabinerJSON))
        return status
    }

    /// Asking for the system extension list takes a process, and once the driver is approved it stays
    /// that way, so a settled answer is kept for half an hour. While it waits for the user's OK, every
    /// check looks again.
    func karabinerDriver() async -> DriverState {
        if let kept: DriverState = cache.value("karabiner driver") { return kept }
        let state = SystemExtensionsParser.karabiner(await ctx.run(Commands.systemExtensions()).stdout)
        if state == .enabled { cache.keep(state, "karabiner driver", for: 30 * 60) }
        return state
    }

    @concurrent func downloads(_ pass: Pass) async -> DownloadsStatus {
        var status = DownloadsStatus()
        status.installed = ctx.files.exists(ctx.paths.sorterApp) && ctx.files.exists(ctx.paths.launchAgent(Helper.sorter.label))
        guard status.installed else { return status }
        status.run = await helper(.sorter, in: pass)
        status.disabled = pass.disabled[Helper.sorter.label] ?? false
        status.lastChecked = (try? FileManager.default.attributesOfItem(atPath: ctx.paths.sorterChecked.path(percentEncoded: false)))?[.modificationDate] as? Date
        if let data = ctx.files.read(ctx.paths.sorterLog) {
            status.log = SorterLog.parse(String(decoding: data, as: UTF8.self))
        }
        return status
    }

    @concurrent public func apps() async -> [FeatureID: AppStatus] {
        let running = ctx.readings.runningApps()
        var out: [FeatureID: AppStatus] = [:]
        for app in ManagedApp.all {
            var status = AppStatus()
            status.installed = exists(app.path)
            status.running = running.contains(app.bundleID)
            if status.installed, let ext = app.quickLookExtension { status.quickLook = await quickLook(ext) }
            out[app.id] = status
        }
        return out
    }

    /// Like the driver: once Quick Look has the extension switched on, that's kept for half an hour.
    func quickLook(_ ext: String) async -> QuickLookState {
        if let kept: QuickLookState = cache.value("quick look \(ext)") { return kept }
        let state = PluginKitParser.parse(await ctx.run(Commands.pluginkitMatch(ext)).stdout)
        if state == .enabled { cache.keep(state, "quick look \(ext)", for: 30 * 60) }
        return state
    }

    public func terminalThemed() -> Bool {
        guard let config = ctx.files.read(ctx.paths.batConfig) else { return false }
        return String(decoding: config, as: UTF8.self).contains("--theme=")
    }
}

/// Answers that are slow to get and rarely change, kept for a while between checks.
final class ProbeCache: Sendable {
    private let entries = Locked<[String: (value: any Sendable, until: Date)]>([:])

    func value<T: Sendable>(_ key: String, now: Date = Date()) -> T? {
        entries.withLock { kept in
            guard let entry = kept[key], entry.until > now else { return nil }
            return entry.value as? T
        }
    }

    func keep(_ value: some Sendable, _ key: String, for seconds: TimeInterval) {
        entries.withLock { $0[key] = (value, Date().addingTimeInterval(seconds)) }
    }

    func clear() { entries.withLock { $0.removeAll() } }
}
