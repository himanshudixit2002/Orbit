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

    public init(modeID: String) {
        self.modeID = modeID
        started = Date()
        closedApps = []
        hiddenApps = []
        startedTiling = false
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

    public func apply(_ mode: ModeDefinition) async -> ModeRecord {
        var record = ModeRecord(modeID: mode.id)
        for name in mode.quitApps {
            guard let app = runningApp(named: name) else { continue }
            if practicing {
                ctx.practiceLog.record("Would ask \(name) to quit", "")
            } else if app.terminate() {
                if let path = app.bundleURL?.path(percentEncoded: false) { record.closedApps.append(path) }
            }
        }
        for name in mode.openApps where runningApp(named: name) == nil {
            await ctx.run(Command(Tool.open, ["-a", name], effect: .appControl, summary: "Open \(name)", captureOutput: false))
        }
        if mode.hideOthers {
            let front = NSWorkspace.shared.frontmostApplication
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
                && app != front && app.bundleIdentifier != Bundle.main.bundleIdentifier && !app.isHidden {
                if practicing {
                    ctx.practiceLog.record("Would hide \(app.localizedName ?? "an app")", "")
                } else if app.hide(), let id = app.bundleIdentifier {
                    record.hiddenApps.append(id)
                }
            }
        }
        setKeepAwake(mode.keepAwake, reason: "Orbit \(mode.name) mode")
        if mode.tilingOn, !(await actions.isRunning(.yabai)) {
            record.startedTiling = (try? await actions.setTiling(true, policy: .askIfEdited))?.ok == true
        }
        return record
    }

    /// Switches a mode off: reopens what it closed, shows what it hid, lets the Mac sleep again.
    public func revert(_ record: ModeRecord) async {
        setKeepAwake(.off, reason: "")
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
        if record.startedTiling {
            _ = try? await actions.setTiling(false)
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
