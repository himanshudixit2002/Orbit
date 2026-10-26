import Foundation
import OrbitCore

/// What happened when Orbit changed something, and how to undo it.
public struct ActionOutcome: Sendable {
    public var ok: Bool
    public var message: String
    public var undo: [UndoAction]

    public init(ok: Bool, message: String, undo: [UndoAction] = []) {
        self.ok = ok
        self.message = message
        self.undo = undo
    }
}

/// A config file changed outside Orbit: the user decides whether Orbit may replace it.
public struct EditedByHand: Error, Sendable {
    public let file: ManagedFile
    /// What Orbit would write instead, for the differences view.
    public let proposed: String?
}

public enum WritePolicy: Sendable, Equatable {
    case askIfEdited
    /// The user has seen these hand-edited files and chose Orbit's version of each. Others still ask.
    case overwrite(Set<ManagedFile>)

    /// This policy, with one more file the user agreed Orbit may replace.
    public func approving(_ file: ManagedFile) -> WritePolicy {
        if case .overwrite(let files) = self { return .overwrite(files.union([file])) }
        return .overwrite([file])
    }
}

/// A step of a change that couldn't be done. `undo` puts back whatever that step did manage.
struct StepFailed: LocalizedError {
    var message: String
    var undo: [UndoAction] = []
    var errorDescription: String? { message }
}

/// Collects how to undo each step of a change as it happens and saves them as it goes, so a change cut
/// short (Orbit quit or crashed) can still be undone as far as it got.
public final class UndoRecorder: Sendable {
    /// The change the app is running in this task (begun with `StateStore.beginChange`): the steps
    /// recorded for it are saved under it as they happen.
    @TaskLocal public static var change: UUID?
    /// The recorder of the `steps` this task is inside, so steps nested in it save after its own.
    @TaskLocal static var current: UndoRecorder?

    private let recorded = Locked<[UndoAction]>([])
    private let saved: @Sendable ([UndoAction]) -> Void

    init(saved: @escaping @Sendable ([UndoAction]) -> Void) { self.saved = saved }

    /// A recorder for this task: inside the enclosing one if there is one, else saving under the change
    /// the app is running, else (checks and tests) saving nowhere.
    static func forThisTask(_ store: StateStore) -> UndoRecorder {
        if let outer = current { return UndoRecorder { [outer] steps in outer.saved(outer.actions + steps) } }
        guard let change else { return UndoRecorder { _ in } }
        return UndoRecorder { [store] in store.noteSteps($0, change: change) }
    }

    public var actions: [UndoAction] { recorded.current }

    public func append(_ step: UndoAction) { self += [step] }

    public static func += (recorder: UndoRecorder, steps: [UndoAction]) {
        guard !steps.isEmpty else { return }
        recorder.saved(recorder.recorded.withLock { all in
            all += steps
            return all
        })
    }
}

/// Every change Orbit makes. Each records how to undo itself; nothing is deleted for good.
public struct Actions: Sendable {
    public let ctx: SystemContext

    public init(_ ctx: SystemContext) { self.ctx = ctx }

    var paths: Paths { ctx.paths }
    var uid: UInt32 { ctx.uid }
    var settings: OrbitSettings { ctx.store.settings }

    func backupFolder(_ label: String) -> URL {
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                                               timeZone: .current, calendar: .current))
        return ctx.store.root.appending(path: "Backups/\(stamp) \(label)")
    }

    /// A change to Orbit's own settings only (a mode edited, say), with Undo.
    public func editSettings(_ message: String, _ change: (inout OrbitSettings) -> Void) -> ActionOutcome {
        ActionOutcome(ok: true, message: message, undo: changeSettings(change))
    }

    /// Changes Orbit's settings and returns how to put back exactly what changed.
    func changeSettings(_ change: (inout OrbitSettings) -> Void) -> [UndoAction] {
        let (before, after) = ctx.store.updateSettings(change)
        let undo = SettingsUndo(before: before, after: after)
        return undo.isEmpty ? [] : [.restoreSettings(undo)]
    }

    /// Runs the steps of a change, collecting how to undo each one as it goes. If a step fails, the
    /// change stops there, and what the earlier steps did is still recorded so Undo can put it back.
    func steps(_ body: (UndoRecorder) async throws -> String) async -> ActionOutcome {
        let undo = UndoRecorder.forThisTask(ctx.store)
        do {
            let message = try await UndoRecorder.$current.withValue(undo) { try await body(undo) }
            return ActionOutcome(ok: true, message: message, undo: undo.actions)
        } catch {
            if let failed = error as? StepFailed { undo += failed.undo }
            let reason = error.localizedDescription
            return ActionOutcome(ok: false, message: undo.actions.isEmpty ? reason : reason + " Undo puts back what had already changed.",
                                 undo: undo.actions)
        }
    }

    // MARK: Managed files

    /// Throws `EditedByHand` if any of these files was changed outside Orbit. `proposed` is what
    /// Orbit is about to write to each; a file that already holds exactly that is no conflict, and
    /// neither is one the user has already agreed to replace.
    func checkEdits(_ proposed: [ManagedFile: String], policy: WritePolicy) throws {
        let approved: Set<ManagedFile> = if case .overwrite(let files) = policy { files } else { [] }
        for (file, text) in proposed.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where !approved.contains(file) {
            let current = ctx.files.read(file.url(paths))
            guard ctx.store.registry.verdict(for: file, current: current) == .editedByHand, current != Data(text.utf8) else { continue }
            throw EditedByHand(file: file, proposed: text)
        }
    }

    /// Backs up and replaces a managed file. Unchanged content is left alone.
    func write(_ file: ManagedFile, _ text: String, executable: Bool = false, backups: URL) throws -> [UndoAction] {
        let url = file.url(paths)
        let data = Data(text.utf8)
        let old = ctx.files.read(url)
        if old == data { return [] }
        let backup = try ctx.files.backup(url, into: backups)
        try ctx.files.write(data, to: url, executable: executable)
        ctx.store.noteWritten(file, data: data)
        return [.restoreFile(path: url.path(percentEncoded: false), backup: backup?.path(percentEncoded: false))]
    }

    /// Sets or removes keys in another app's JSON settings file, leaving the rest of it as it was (a
    /// copy of the file is kept in `backups` too). Undo puts back only those keys.
    @discardableResult
    func patchJSON(_ url: URL, _ changes: [String: JSONKeyPatch.Change], backups: URL) throws -> [UndoAction] {
        let text = ctx.files.read(url).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let result = try JSONKeyPatch.apply(changes, to: text)
        guard result.text != text else { return [] }
        _ = try ctx.files.backup(url, into: backups)
        try ctx.files.write(Data(result.text.utf8), to: url, executable: false)
        return [.restoreJSONKeys(path: url.path(percentEncoded: false), values: result.before, absent: result.absent)]
    }

    func writePlain(_ url: URL, _ text: String, executable: Bool, backups: URL) throws -> [UndoAction] {
        let data = Data(text.utf8)
        if ctx.files.read(url) == data { return [] }
        let backup = try ctx.files.backup(url, into: backups)
        try ctx.files.write(data, to: url, executable: executable)
        return [.restoreFile(path: url.path(percentEncoded: false), backup: backup?.path(percentEncoded: false))]
    }

    // MARK: Helpers

    /// Whether a helper is on. The sorter only runs once an hour, so for it "on" means loaded.
    func isRunning(_ helper: Helper) async -> Bool {
        let run = LaunchctlParser.run(await ctx.run(Commands.launchctlPrint(helper.label, uid: uid)))
        return helper == .sorter ? run.isLoaded : run.isRunning
    }

    /// Starts a helper and lets it start again at login.
    @discardableResult
    func start(_ helper: Helper) async -> CommandResult {
        switch helper {
        case .yabai:
            await ctx.run(Commands.launchctlEnable(helper.label, uid: uid))
            return await ctx.run(Commands.yabaiService(.start))
        case .skhd:
            await ctx.run(Commands.launchctlEnable(helper.label, uid: uid))
            return await ctx.run(Commands.skhdService(.start))
        case .borders, .sketchybar:
            return await ctx.run(Commands.brewService(.start, helper.brewFormula!, name: helper.title))
        case .sorter:
            await ctx.run(Commands.launchctlEnable(helper.label, uid: uid))
            return await ctx.run(Commands.launchctlBootstrap(paths.launchAgent(helper.label), uid: uid))
        }
    }

    /// Stops a helper and keeps it from coming back at login.
    @discardableResult
    func stop(_ helper: Helper) async -> CommandResult {
        switch helper {
        case .yabai:
            let result = await ctx.run(Commands.yabaiService(.stop))
            await ctx.run(Commands.launchctlDisable(helper.label, uid: uid))
            return result
        case .skhd:
            let result = await ctx.run(Commands.skhdService(.stop))
            await ctx.run(Commands.launchctlDisable(helper.label, uid: uid))
            return result
        case .borders, .sketchybar:
            return await ctx.run(Commands.brewService(.stop, helper.brewFormula!, name: helper.title))
        case .sorter:
            let result = await ctx.run(Commands.launchctlBootout(helper.label, uid: uid))
            await ctx.run(Commands.launchctlDisable(helper.label, uid: uid))
            return result
        }
    }

    /// Switches a helper on or off and checks that it worked; throws `StepFailed` if it didn't.
    func setHelper(_ helper: Helper, on: Bool) async throws -> [UndoAction] {
        let run = LaunchctlParser.run(await ctx.run(Commands.launchctlPrint(helper.label, uid: uid)))
        guard Self.needsSwitching(helper, to: on, now: run) else { return [] }
        let result = on ? await start(helper) : await stop(helper)
        let undo: [UndoAction] = [.helper(helper, wasOn: !on)]
        if let problem = await failure(of: result, switching: helper, on: on) { throw StepFailed(message: problem, undo: undo) }
        return undo
    }

    /// Why switching a helper didn't work, or nil if it did. launchd is asked afterwards as well,
    /// since some tools report success for things they didn't do.
    func failure(of result: CommandResult, switching helper: Helper, on: Bool) async -> String? {
        let verb = on ? "start" : "stop"
        guard result.ok else { return "Couldn't \(verb) \(helper.title): \(result.failureMessage)" }
        // Practice mode only pretends, so there's nothing to check.
        guard ctx.mode == .live else { return nil }
        let loaded = LaunchctlParser.run(await ctx.run(Commands.launchctlPrint(helper.label, uid: uid))).isLoaded
        return loaded == on ? nil : "macOS didn't \(verb) \(helper.title)."
    }

    /// Starts a stopped helper again (the watchdog's restart), unless it was switched off or came back
    /// in the meantime. Returns whether it's running now.
    public func kickstart(_ helper: Helper) async -> Bool {
        let before = LaunchctlParser.run(await ctx.run(Commands.launchctlPrint(helper.label, uid: uid)))
        guard before.isLoaded else { return false }
        guard !before.isRunning else { return true }
        await ctx.run(Commands.launchctlKickstart(helper.label, uid: uid))
        return LaunchctlParser.run(await ctx.run(Commands.launchctlPrint(helper.label, uid: uid))).isRunning
    }

    /// Whether switching a helper on or off needs doing, given what launchd says about it now.
    static func needsSwitching(_ helper: Helper, to on: Bool, now run: HelperRun) -> Bool {
        if on { return !(helper == .sorter ? run.isLoaded : run.isRunning) }
        // Loaded but not running still counts as on: launchd can start it again, at the latest at login.
        return run.isLoaded
    }

    // MARK: Window tiling

    public func setTiling(_ on: Bool, policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        guard on else {
            return await steps { undo in
                undo += try await setHelper(.yabai, on: false)
                undo += try await setHelper(.skhd, on: false)
                return "Window tiling is off."
            }
        }
        let barOn = await isRunning(.sketchybar)
        let yabairc = YabaiConfig.render(settings, barReserved: barOn ? settings.bar.reservedSpace : nil)
        try checkEdits([.yabairc: yabairc], policy: policy)
        let backups = backupFolder("tiling")
        return await steps { undo in
            // A plist left by an older yabai would start a second copy that fights this one.
            let stale = paths.launchAgent(Helper.staleYabaiLabel)
            if ctx.files.exists(stale) {
                await ctx.run(Commands.launchctlBootout(Helper.staleYabaiLabel, uid: uid))
                let parked = backups.appending(path: stale.lastPathComponent)
                try ctx.files.move(stale, to: parked)
                undo.append(.moveBack(current: parked.path(percentEncoded: false), original: stale.path(percentEncoded: false)))
            }
            undo += try write(.yabairc, yabairc, executable: true, backups: backups)
            undo += try await setHelper(.yabai, on: true)
            undo += try await setHelper(.skhd, on: true)
            return "Window tiling is on."
        }
    }

    /// yabai gives up for good when it starts without Accessibility, and launchd doesn't try it again.
    /// Once the user has been to System Settings, tiling helpers that are switched on get another go.
    public func retryTiling() async -> ActionOutcome {
        var problems: [String] = []
        for helper in [Helper.yabai, .skhd] {
            let run = LaunchctlParser.run(await ctx.run(Commands.launchctlPrint(helper.label, uid: uid)))
            guard run.isLoaded, !run.isRunning else { continue }
            let result = await start(helper)
            if !result.ok { problems.append("Couldn't start \(helper.title): \(result.failureMessage)") }
        }
        return problems.isEmpty ? ActionOutcome(ok: true, message: "Started window tiling again.")
                                : ActionOutcome(ok: false, message: problems.joined(separator: " "))
    }

    /// Saves tiling settings and applies them straight away if tiling is running.
    public func applyTiling(_ tiling: TilingSettings, policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        var next = settings
        next.tiling = tiling
        let barOn = await isRunning(.sketchybar)
        let yabairc = YabaiConfig.render(next, barReserved: barOn ? next.bar.reservedSpace : nil)
        try checkEdits([.yabairc: yabairc], policy: policy)
        return await steps { undo in
            undo += changeSettings { $0.tiling = tiling }
            undo += try write(.yabairc, yabairc, executable: true, backups: backupFolder("tiling settings"))
            if await isRunning(.yabai) {
                await ctx.run(Commands.yabaiLayout(tiling.layout))
                await ctx.run(Commands.yabaiConfig("window_gap", "\(tiling.gap)"))
                for side in ["top", "bottom", "left", "right"] {
                    await ctx.run(Commands.yabaiConfig("\(side)_padding", "\(tiling.padding)"))
                }
                await ctx.run(Commands.yabaiConfig("window_placement", tiling.newWindowsFirst ? "first_child" : "second_child"))
                await ctx.run(Commands.yabaiConfig("split_ratio", String(format: "%.2f", tiling.splitRatio)))
                await ctx.run(Commands.yabaiConfig("auto_balance", tiling.autoBalance ? "on" : "off"))
                await ctx.run(Commands.yabaiConfig("mouse_follows_focus", tiling.mouseFollowsFocus ? "on" : "off"))
                await ctx.run(Commands.yabaiConfig("focus_follows_mouse", tiling.focusFollowsMouse.rawValue))
            }
            return "Window arrangement updated."
        }
    }

    /// Saves which apps float instead of tiling, and changes the rule while yabai runs: apps added
    /// float straight away; ones taken out tile from their next window.
    public func applyFloatingApps(_ apps: [String], policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        var next = settings
        next.floatingApps = apps
        let barOn = await isRunning(.sketchybar)
        let yabairc = YabaiConfig.render(next, barReserved: barOn ? next.bar.reservedSpace : nil)
        try checkEdits([.yabairc: yabairc], policy: policy)
        return await steps { undo in
            undo += changeSettings { $0.floatingApps = apps }
            undo += try write(.yabairc, yabairc, executable: true, backups: backupFolder("floating apps"))
            if await isRunning(.yabai) {
                let rule = YabaiConfig.floatingRule
                await ctx.run(Commands.yabaiRule(["--remove", rule], summary: "Take out the floating apps rule"))
                await ctx.run(Commands.yabaiRule(["--add", "label=\(rule)", "app=\(YabaiConfig.floatingPattern(apps))", "manage=off"],
                                                 summary: "Float \(apps.count) apps"))
                await ctx.run(Commands.yabaiRule(["--apply", rule], summary: "Float their open windows"))
            }
            return "Floating apps updated."
        }
    }

    // MARK: Glow

    public func setGlow(_ on: Bool, policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        guard on else {
            return await steps { undo in
                undo += try await setHelper(.borders, on: false)
                return "The window glow is off."
            }
        }
        let bordersrc = BordersConfig.render(settings.glow, palette: settings.palette)
        try checkEdits([.bordersrc: bordersrc], policy: policy)
        return await steps { undo in
            undo += try write(.bordersrc, bordersrc, executable: true, backups: backupFolder("glow"))
            undo += try await setHelper(.borders, on: true)
            return "The window glow is on."
        }
    }

    public func applyGlow(_ glow: GlowSettings, policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        let bordersrc = BordersConfig.render(glow, palette: settings.palette)
        try checkEdits([.bordersrc: bordersrc], policy: policy)
        return await steps { undo in
            undo += changeSettings { $0.glow = glow }
            undo += try write(.bordersrc, bordersrc, executable: true, backups: backupFolder("glow style"))
            if await isRunning(.borders) {
                await ctx.run(Commands.bordersApply(BordersConfig.options(glow, palette: settings.palette)))
            }
            return "Glow updated."
        }
    }

    // MARK: Menu bar

    /// The bar's files: its layout, its colours (when given) and any plugin that's missing. A plugin
    /// that's there is the user's to change, so it's never replaced.
    func writeBarFiles(rc: String, colors: String?, backups: URL, into undo: UndoRecorder) throws {
        let plugins = paths.sketchybarDir.appending(path: "plugins")
        for (name, text) in SketchyBarConfig.plugins.sorted(by: { $0.key < $1.key })
        where !ctx.files.exists(plugins.appending(path: name)) {
            undo += try writePlain(plugins.appending(path: name), text, executable: true, backups: backups)
        }
        if let colors { undo += try write(.sketchybarColors, colors, executable: true, backups: backups) }
        undo += try write(.sketchybarrc, rc, executable: true, backups: backups)
    }

    func setMacMenuBarHidden(_ hidden: Bool) async -> [UndoAction] {
        let key = "_HIHideMenuBar"
        let old = ctx.readings.preference(WatchedPreferences.globalDomain, key)
        guard (old?.boolValue ?? false) != hidden else { return [] }
        let script = "tell application \"System Events\" to set autohide menu bar of dock preferences to \(hidden)"
        let result = await ctx.run(Commands.appleScript(script, effect: .systemSetting,
                                                        summary: hidden ? "Hide the Mac's own menu bar until you point at the top"
                                                                        : "Show the Mac's own menu bar again"))
        if !result.ok {
            ctx.prefs.set(WatchedPreferences.globalDomain, key, .bool(hidden))
            await ctx.run(Commands.killall("SystemUIServer", summary: "Refresh the menu bar"))
        }
        return [.restorePreference(domain: WatchedPreferences.globalDomain, key: key, value: old)]
    }

    /// Whether the Mac's own menu bar hid itself before Orbit.
    var macMenuBarHiddenBefore: Bool {
        ctx.store.baseline?.preferences[Baseline.key(WatchedPreferences.globalDomain, "_HIHideMenuBar")]?.boolValue ?? false
    }

    /// Tells tiling how much room the bar needs (and whether to nudge its git item), live and in its
    /// config file (written only if it exists). Reads the bar's settings as they are now.
    func reserveBarSpace(_ on: Bool, yabairc: String, backups: URL) async throws -> [UndoAction] {
        if await isRunning(.yabai) {
            await ctx.run(Commands.yabaiConfig("external_bar", settings.bar.externalBar(on: on)))
            await ctx.run(Commands.barFocusSignal(on && settings.bar.showGit))
        }
        guard ctx.files.exists(paths.yabairc) else { return [] }
        return try write(.yabairc, yabairc, executable: true, backups: backups)
    }

    public func setMenuBar(_ on: Bool, policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        let yabairc = YabaiConfig.render(settings, barReserved: on ? settings.bar.reservedSpace : nil)
        var proposed: [ManagedFile: String] = ctx.files.exists(paths.yabairc) ? [.yabairc: yabairc] : [:]
        let rc = SketchyBarConfig.rc(settings.bar)
        let colors = SketchyBarConfig.colors(settings.palette)
        if on {
            proposed[.sketchybarrc] = rc
            proposed[.sketchybarColors] = colors
        }
        try checkEdits(proposed, policy: policy)
        let backups = backupFolder("menu bar")
        if on {
            return await steps { undo in
                try writeBarFiles(rc: rc, colors: colors, backups: backups, into: undo)
                undo += await setMacMenuBarHidden(settings.bar.position == .top ? true : macMenuBarHiddenBefore)
                undo += try await reserveBarSpace(true, yabairc: yabairc, backups: backups)
                undo += try await setHelper(.sketchybar, on: true)
                return "The new menu bar is on. Point at the top of the screen for the Mac's own menus."
            }
        }
        return await steps { undo in
            undo += try await setHelper(.sketchybar, on: false)
            undo += await setMacMenuBarHidden(macMenuBarHiddenBefore)
            undo += try await reserveBarSpace(false, yabairc: yabairc, backups: backups)
            return "The new menu bar is off."
        }
    }

    public func applyBar(_ bar: BarSettings, policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        let rc = SketchyBarConfig.rc(bar)
        let old = settings.bar
        var next = settings
        next.bar = bar
        let barOn = await isRunning(.sketchybar)
        // Tiling's room for the bar follows its size and edge, and its git item needs yabai's nudge.
        let tilingChanges = barOn && (bar.reservedSpace != old.reservedSpace || bar.position != old.position || bar.showGit != old.showGit)
        let yabairc = YabaiConfig.render(next, barReserved: bar.reservedSpace)
        var proposed: [ManagedFile: String] = [.sketchybarrc: rc]
        if tilingChanges, ctx.files.exists(paths.yabairc) { proposed[.yabairc] = yabairc }
        try checkEdits(proposed, policy: policy)
        let backups = backupFolder("menu bar items")
        return await steps { undo in
            undo += changeSettings { $0.bar = bar }
            try writeBarFiles(rc: rc, colors: nil, backups: backups, into: undo)
            if tilingChanges { undo += try await reserveBarSpace(true, yabairc: yabairc, backups: backups) }
            if barOn, bar.position != old.position {
                undo += await setMacMenuBarHidden(bar.position == .top ? true : macMenuBarHiddenBefore)
            }
            if barOn { await ctx.run(Commands.sketchybarReload()) }
            return "Menu bar updated."
        }
    }

    // MARK: Downloads

    public func setDownloads(_ on: Bool) async -> ActionOutcome {
        await steps { undo in
            undo += try await setHelper(.sorter, on: on)
            return on ? "Downloads will be sorted every hour." : "Downloads won't be sorted any more."
        }
    }

    public func sortDownloadsNow() async -> ActionOutcome {
        let result = await ctx.run(Commands.openApp(at: paths.sorterApp.path(percentEncoded: false), name: "Downloads Sorter", background: true))
        return ActionOutcome(ok: result.ok, message: result.ok ? "Sorting your Downloads folder now." : result.failureMessage)
    }

    // MARK: Apps

    public func open(_ app: ManagedApp) async -> ActionOutcome {
        let result = await ctx.run(Commands.openApp(at: app.path, name: app.name))
        return ActionOutcome(ok: result.ok, message: result.ok ? "Opened \(app.name)." : result.failureMessage)
    }

    public func install(_ app: ManagedApp) async -> ActionOutcome {
        let result = await ctx.run(Commands.brewInstallCask(app.cask, name: app.name))
        return ActionOutcome(ok: result.ok, message: result.ok ? "\(app.name) is installed." : result.failureMessage)
    }

    public func setLoginItem(_ app: ManagedApp, on: Bool) async -> ActionOutcome {
        let result = await ctx.run(Commands.appleScript(Self.loginItemScript(name: app.name, path: app.path, on: on), effect: .systemSetting,
                                                        summary: on ? "Open \(app.name) when you log in" : "Stop opening \(app.name) at login"))
        guard result.ok else { return ActionOutcome(ok: false, message: result.failureMessage) }
        let changed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "changed"
        return ActionOutcome(ok: true, message: on ? "\(app.name) will open at login." : "\(app.name) won't open at login.",
                             undo: changed ? [.loginItem(name: app.name, path: app.path, wasOn: !on)] : [])
    }

    /// Adds or removes an app's login item. The script answers "changed", or "already" when there was nothing to do.
    static func loginItemScript(name: String, path: String, on: Bool) -> String {
        let item = "login item \(Shell.appleScriptString(name))"
        let change = on
            ? "if exists \(item) then return \"already\"\nmake login item at end with properties {path:\(Shell.appleScriptString(path)), hidden:false}"
            : "if not (exists \(item)) then return \"already\"\ndelete \(item)"
        return "tell application \"System Events\"\n\(change)\nreturn \"changed\"\nend tell"
    }

    // MARK: Preferences (Dock, Finder, screenshots, keyboard)

    public struct PreferenceChange: Sendable {
        public let domain: String
        public let key: String
        public let value: PrefValue?

        public init(_ domain: String, _ key: String, _ value: PrefValue?) {
            self.domain = domain
            self.key = key
            self.value = value
        }
    }

    /// Changes preferences, then restarts whatever shows them so the change appears at once.
    public func setPreferences(_ changes: [PreferenceChange], message: String) async -> ActionOutcome {
        let undo = UndoRecorder.forThisTask(ctx.store)
        for change in changes {
            let old = ctx.readings.preference(change.domain, change.key)
            guard old != change.value else { continue }
            ctx.prefs.set(change.domain, change.key, change.value)
            undo.append(.restorePreference(domain: change.domain, key: change.key, value: old))
        }
        await refreshAfterPreferences(Set(changes.map(\.domain)))
        return ActionOutcome(ok: true, message: message, undo: undo.actions)
    }

    func refreshAfterPreferences(_ domains: Set<String>) async {
        if domains.contains(WatchedPreferences.dockDomain) {
            await ctx.run(Commands.killall("Dock", summary: "Restart the Dock to show the change"))
        }
        if domains.contains(WatchedPreferences.finderDomain) {
            await ctx.run(Commands.killall("Finder", summary: "Restart Finder to show the change"))
        }
        if domains.contains(WatchedPreferences.screenshotDomain) {
            await ctx.run(Commands.killall("SystemUIServer", summary: "Apply the screenshot setting"))
        }
    }

    // MARK: Undo

    /// Applies an entry's undo steps, newest first.
    public func undo(_ actions: [UndoAction]) async -> ActionOutcome {
        var failures: [String] = []
        var domains = Set<String>()
        var restored = Set<ManagedFile>()
        let keep = backupFolder("before undo")
        for action in actions.reversed() {
            switch action {
            case .restoreFile(let path, let backup):
                let url = URL(fileURLWithPath: path)
                let managed = ManagedFile.allCases.first { $0.url(paths).path(percentEncoded: false) == path }
                do {
                    if let backup {
                        // A saved copy that's gone says nothing about the file, so it's left as it is.
                        guard let data = ctx.files.read(URL(fileURLWithPath: backup)) else {
                            failures.append("the saved copy of \(paths.tilde(url)) is missing, so that file was left as it is")
                            continue
                        }
                        if ctx.files.read(url) != data {
                            // What's there now may hold the user's own edits: it's kept as well.
                            _ = try ctx.files.backup(url, into: keep)
                            try ctx.files.write(data, to: url, executable: path.hasSuffix("rc") || path.hasSuffix(".sh"))
                        }
                        // Either way the file now holds a version Orbit chose, so it isn't "edited by hand".
                        if let managed { ctx.store.noteWritten(managed, data: data) }
                    } else if ctx.files.exists(url) {
                        _ = try ctx.files.trash(url)
                    }
                    if let managed { restored.insert(managed) }
                } catch {
                    failures.append(error.localizedDescription)
                }
            case .restoreSettings(let previous):
                ctx.store.updateSettings { previous.apply(to: &$0) }
            case .restorePreference(let domain, let key, let value):
                ctx.prefs.set(domain, key, value)
                domains.insert(domain)
                if key == MacAccent.key { announceAccentChange() }
                if key == "_HIHideMenuBar" {
                    let hidden = value?.boolValue ?? false
                    await ctx.run(Commands.appleScript(
                        "tell application \"System Events\" to set autohide menu bar of dock preferences to \(hidden)",
                        effect: .systemSetting, summary: "Put the Mac's menu bar back"))
                }
            case .moveBack(let current, let original):
                do {
                    try ctx.files.move(URL(fileURLWithPath: current), to: URL(fileURLWithPath: original))
                } catch {
                    failures.append(error.localizedDescription)
                }
            case .helper(let helper, let wasOn):
                let result = wasOn ? await start(helper) : await stop(helper)
                if let problem = await failure(of: result, switching: helper, on: wasOn) { failures.append(problem) }
            case .gitConfig(let key, let value):
                if let value {
                    await ctx.run(Commands.gitConfigSet(key, value))
                } else {
                    await ctx.run(Commands.gitConfigUnset(key))
                }
            case .loginItem(let name, let path, let wasOn):
                let result = await ctx.run(Commands.appleScript(Self.loginItemScript(name: name, path: path, on: wasOn), effect: .systemSetting,
                                                                summary: wasOn ? "Open \(name) when you log in again" : "Stop opening \(name) at login"))
                if !result.ok { failures.append("\(name) at login: \(result.failureMessage)") }
            case .brewService(let formula, let wasRunning):
                let result = await ctx.run(Commands.brewService(wasRunning ? .start : .stop, formula, name: Doctor.serviceName(formula)))
                if !result.ok { failures.append("\(Doctor.serviceName(formula)): \(result.failureMessage)") }
            case .arrangeWindows(let layout):
                if await isRunning(.yabai) {
                    await arrange(layout)
                } else {
                    failures.append("window tiling isn't running, so the windows stayed where they are")
                }
            case .restoreJSONKeys(let path, let values, let absent):
                do {
                    var changes = values.mapValues { JSONKeyPatch.Change.set($0) }
                    for key in absent { changes[key] = .remove }
                    try patchJSON(URL(fileURLWithPath: path), changes, backups: keep)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
        }
        await refreshAfterPreferences(domains)
        await reload(restored)
        return failures.isEmpty
            ? ActionOutcome(ok: true, message: "Undone.")
            : ActionOutcome(ok: false, message: "Mostly undone, but " + failures.joined(separator: "; ") + ".")
    }

    /// Restored config files only take effect once whatever reads them loads them again.
    func reload(_ files: Set<ManagedFile>) async {
        if files.contains(.bordersrc), await isRunning(.borders) {
            await ctx.run(Commands.brewService(.restart, Helper.borders.brewFormula!, name: "the window glow"))
        }
        if !files.isDisjoint(with: [.sketchybarrc, .sketchybarColors]), await isRunning(.sketchybar) {
            await ctx.run(Commands.sketchybarReload())
        }
        if files.contains(.yabairc), await isRunning(.yabai) {
            await ctx.run(Commands.yabaiService(.restart))
        }
        if !files.isDisjoint(with: [.batTheme, .batConfig]) {
            await ctx.run(Commands.batCacheBuild())
        }
    }
}
