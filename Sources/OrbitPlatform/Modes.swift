import AppKit
import Foundation
import IOKit.pwr_mgt
import OrbitCore

/// What a mode changed, so switching it off can put things back.
public struct ModeRecord: Codable, Sendable, Equatable {
    public var modeID: String
    public var started: Date
    public var closedApps: [String]      // app paths to reopen
    public var hiddenApps: [String]      // bundle ids to show again
    public var startedTiling: Bool
    /// How to put back the theme, switches and window style the mode changed.
    public var undo: [UndoAction] = []
    /// When its timer switches it off.
    public var endsAt: Date?
    /// Started by its schedule (which then also stops it).
    public var bySchedule = false
    /// What the mode couldn't do, said once it's on.
    public var notes: [String] = []

    public init(modeID: String) {
        self.modeID = modeID
        started = Date()
        closedApps = []
        hiddenApps = []
        startedTiling = false
    }

    private enum CodingKeys: String, CodingKey { case modeID, started, closedApps, hiddenApps, startedTiling, undo, endsAt, bySchedule, notes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modeID = try c.decode(String.self, forKey: .modeID)
        started = c.value(.started, or: Date())
        closedApps = c.value(.closedApps, or: [])
        hiddenApps = c.value(.hiddenApps, or: [])
        startedTiling = c.value(.startedTiling, or: false)
        undo = c.value(.undo, or: [])
        endsAt = c.value(.endsAt, or: nil)
        bySchedule = c.value(.bySchedule, or: false)
        notes = c.value(.notes, or: [])
    }
}

/// Applies Work / Focus / Chill / Present. Apps are asked to quit politely, never forced, and the
/// keep-awake hold belongs to Orbit, so it ends by itself if Orbit quits.
@MainActor
public final class ModeEngine {
    let ctx: SystemContext
    let actions: Actions
    private var assertion: IOPMAssertionID?

    public init(ctx: SystemContext) {
        self.ctx = ctx
        actions = Actions(ctx)
    }

    var practicing: Bool { ctx.mode == .practice }

    func runningApp(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == name && $0.activationPolicy == .regular }
    }

    /// Switches a mode on, in this order: close apps, hide the rest (not the ones it opens), change the
    /// theme and switches, open apps and websites, keep the Mac awake, run its shortcut. A hand-edited
    /// config file is left alone (and said so), never overwritten.
    public func apply(_ mode: ModeDefinition, bySchedule: Bool = false) async -> ModeRecord {
        var record = ModeRecord(modeID: mode.id)
        record.bySchedule = bySchedule
        for name in mode.quitApps {
            guard let app = runningApp(named: name) else { continue }
            if practicing {
                ctx.practiceLog.record("Would ask \(name) to quit", "")
            } else if app.terminate() {
                if let path = app.bundleURL?.path(percentEncoded: false) { record.closedApps.append(path) }
            }
        }
        if mode.hideOthers {
            let front = NSWorkspace.shared.frontmostApplication
            let opening = Set(mode.openApps)
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
                && app != front && app.bundleIdentifier != Bundle.main.bundleIdentifier && !app.isHidden
                && !opening.contains(app.localizedName ?? "") {
                if practicing {
                    ctx.practiceLog.record("Would hide \(app.localizedName ?? "an app")", "")
                } else if app.hide(), let id = app.bundleIdentifier {
                    record.hiddenApps.append(id)
                }
            }
        }
        await change(&record, mode)
        for name in mode.openApps where runningApp(named: name) == nil {
            await ctx.run(Command(Tool.open, ["-a", name], effect: .appControl, summary: "Open \(name)", captureOutput: false))
        }
        for url in mode.urls where URL(string: url)?.scheme != nil {
            await ctx.run(Command(Tool.open, [url], effect: .appControl, summary: "Open \(url)", captureOutput: false))
        }
        setKeepAwake(mode.keepAwake, reason: "Orbit \(mode.name) mode")
        if let shortcut = mode.shortcut, !shortcut.isEmpty {
            let result = await ctx.run(Command("/usr/bin/shortcuts", ["run", shortcut], effect: .appControl,
                                               summary: "Run the \(shortcut) shortcut", timeout: 60))
            if !result.ok { record.notes.append("The \(shortcut) shortcut didn't run: \(result.failureMessage)") }
        }
        if let minutes = mode.timerMinutes, minutes > 0 { record.endsAt = record.started.addingTimeInterval(Double(minutes) * 60) }
        return record
    }

    /// The theme, switches and window style, each through the same change as its page uses, with
    /// how to undo it kept in the record.
    func change(_ record: inout ModeRecord, _ mode: ModeDefinition) async {
        func keep(_ outcome: ActionOutcome?, _ what: String) {
            guard let outcome else { return }
            record.undo += outcome.undo
            if !outcome.ok { record.notes.append(outcome.message) }
        }
        func attempt(_ what: String, _ work: () async throws -> ActionOutcome) async {
            do {
                keep(try await work(), what)
            } catch let edited as EditedByHand {
                record.notes.append("\(edited.file.title) were edited by hand, so the mode left \(what) alone.")
            } catch {
                record.notes.append(error.localizedDescription)
            }
        }
        if let theme = mode.theme, theme != actions.settings.theme {
            let tmux = actions.settings.themeTmux
            await attempt("the theme") { try await actions.applyTheme(theme, tmux: tmux) }
        }
        let tilingOn = await actions.isRunning(.yabai)
        if mode.tiling != .leave, (mode.tiling == .on) != tilingOn {
            await attempt("window tiling") { try await actions.setTiling(mode.tiling == .on) }
            record.startedTiling = mode.tiling == .on
        }
        if let layout = mode.layout, layout != actions.settings.tiling.layout {
            var tiling = actions.settings.tiling
            tiling.layout = layout
            await attempt("the window style") { try await actions.applyTiling(tiling) }
        }
        if mode.glow != .leave, (mode.glow == .on) != (await actions.isRunning(.borders)) {
            await attempt("the glow") { try await actions.setGlow(mode.glow == .on) }
        }
        if mode.menuBar != .leave, (mode.menuBar == .on) != (await actions.isRunning(.sketchybar)) {
            await attempt("the menu bar") { try await actions.setMenuBar(mode.menuBar == .on) }
        }
    }

    /// Switches a mode off: reopens what it closed, shows what it hid, puts back what it changed, lets
    /// the Mac sleep again.
    public func revert(_ record: ModeRecord) async {
        setKeepAwake(.off, reason: "")
        if !record.undo.isEmpty {
            _ = await actions.undo(record.undo)
        } else if record.startedTiling {
            _ = try? await actions.setTiling(false)
        }
        for path in record.closedApps {
            await ctx.run(Commands.openApp(at: path, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, background: true))
        }
        for id in record.hiddenApps {
            if practicing {
                ctx.practiceLog.record("Would show \(id) again", "")
            } else {
                NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.unhide() }
            }
        }
    }

    public func setKeepAwake(_ kind: KeepAwake, reason: String) {
        if let assertion {
            IOPMAssertionRelease(assertion)
            self.assertion = nil
        }
        guard kind != .off else { return }
        if practicing {
            ctx.practiceLog.record("Would keep the \(kind == .display ? "screen" : "Mac") awake", reason)
            return
        }
        let type = kind == .display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id = IOPMAssertionID(0)
        if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess {
            assertion = id
        }
    }

    public var keepingAwake: Bool { assertion != nil }
}
