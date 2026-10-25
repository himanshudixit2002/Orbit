import Foundation
import OrbitCore

extension Actions {
    /// The windows and desktops on screen now, from yabai; nil when tiling isn't running.
    public func windowsNow() async -> (windows: [YabaiWindow], spaces: [YabaiSpace])? {
        let spaces = await ctx.run(Commands.yabaiQuerySpaces())
        let windows = await ctx.run(Commands.yabaiQueryWindows())
        guard spaces.ok, windows.ok else { return nil }
        return (YabaiWindow.parse(Data(windows.stdout.utf8)), YabaiSpace.parse(Data(spaces.stdout.utf8)))
    }

    /// Saves how the windows sit now under `name` (replacing a layout of the same name).
    public func saveWindowLayout(name: String) async -> ActionOutcome {
        guard let now = await windowsNow() else {
            return ActionOutcome(ok: false, message: "Window tiling isn't running, so Orbit can't see where the windows are.")
        }
        let layout = WindowLayout.capture(name: name, windows: now.windows, spaces: now.spaces)
        guard !layout.desktops.isEmpty else { return ActionOutcome(ok: false, message: "There are no windows to save.") }
        return await steps { undo in
            undo += changeSettings { settings in
                settings.windowLayouts.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                settings.windowLayouts.append(layout)
            }
            return "Saved \"\(name)\": \(layout.summary)."
        }
    }

    public func deleteWindowLayout(_ id: UUID) async -> ActionOutcome {
        guard let layout = settings.windowLayouts.first(where: { $0.id == id }) else {
            return ActionOutcome(ok: true, message: "It's gone already.")
        }
        return await steps { undo in
            undo += changeSettings { $0.windowLayouts.removeAll { $0.id == id } }
            return "Deleted \"\(layout.name)\"."
        }
    }

    /// Puts the windows back as `layout` has them, as far as they can go. Undo puts them back as they were.
    public func arrangeWindows(_ layout: WindowLayout) async -> ActionOutcome {
        guard let now = await windowsNow() else {
            return ActionOutcome(ok: false, message: "Window tiling isn't running, so Orbit can't arrange the windows.")
        }
        let before = WindowLayout.capture(name: "Before \(layout.name)", windows: now.windows, spaces: now.spaces)
        return await steps { undo in
            undo.append(.arrangeWindows(before))
            let notes = await arrange(layout, now: now)
            return (["Arranged the windows as \"\(layout.name)\"."] + notes).joined(separator: " ")
        }
    }

    /// Runs the plan, then (if windows joined or left the tiling, which moves the others) plans once
    /// more from where they ended up. Returns what couldn't be put back.
    @discardableResult
    func arrange(_ layout: WindowLayout, now: (windows: [YabaiWindow], spaces: [YabaiSpace])? = nil) async -> [String] {
        var found = now
        if found == nil { found = await windowsNow() }
        guard var current = found else { return ["Window tiling isn't running."] }
        var notes: [String] = []
        for round in 0..<2 {
            let plan = LayoutPlanner.plan(layout, windows: current.windows, spaces: current.spaces)
            if round == 0 { notes = plan.notes }
            for step in plan.steps { await ctx.run(Commands.arrange(step)) }
            guard plan.reshapes, round == 0, let after = await windowsNow() else { break }
            current = after
        }
        return notes
    }

    /// Gives one desktop a window style of its own, or (nil) the shared one again.
    public func setSpaceLayout(_ space: Int, _ layout: TilingLayout?, policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        var next = settings
        next.tiling.spaceLayouts.removeAll { $0.space == space }
        if let layout { next.tiling.spaceLayouts.append(SpaceLayout(space: space, layout: layout)) }
        let barOn = await isRunning(.sketchybar)
        let yabairc = YabaiConfig.render(next, barReserved: barOn ? next.bar.reservedSpace : nil)
        let writesFile = ctx.files.exists(paths.yabairc)
        if writesFile { try checkEdits([.yabairc: yabairc], policy: policy) }
        let tiling = next.tiling
        return await steps { undo in
            undo += changeSettings { $0.tiling = tiling }
            if writesFile { undo += try write(.yabairc, yabairc, executable: true, backups: backupFolder("desktop \(space) style")) }
            if await isRunning(.yabai) { await ctx.run(Commands.yabaiSpaceLayout(space, tiling.layout(of: space))) }
            let style = tiling.layout(of: space).title.lowercased()
            return layout == nil ? "Desktop \(space) is back to the shared style (\(style))." : "Desktop \(space) uses \(style) windows now."
        }
    }
}
