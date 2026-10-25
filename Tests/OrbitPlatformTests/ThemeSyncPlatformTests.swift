import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct ThemeSyncActionTests {
    @Test func editorColoursComeAndGoAndYourSettingsStay() async throws {
        let ctx = try sandboxContext()
        let original = "{\n    \"editor.fontSize\": 14 // mine\n}\n"
        try FileManager.default.createDirectory(at: ctx.paths.editorSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(original.utf8).write(to: ctx.paths.editorSettings)
        ctx.store.updateSettings { $0.theme = .sunset }
        let actions = Actions(ctx)
        func text() throws -> String { try String(contentsOf: ctx.paths.editorSettings, encoding: .utf8) }

        let on = try await actions.setThemeSync(.editor, on: true)
        #expect(on.ok)
        #expect(try text().contains("\"workbench.colorTheme\": \"Default Dark Modern\""))
        #expect(try text().contains(Palette.sunset.bg.hex))
        #expect(try text().contains("// mine"))
        #expect(ctx.store.settings.themeSync.editor)

        // A new theme recolours it (with the editor's own copy, if it has one).
        _ = try await actions.applyTheme(.catppuccin, tmux: false)
        #expect(try text().contains(Palette.catppuccin.bg.hex) || text().contains("\"Catppuccin Mocha\""))

        // Off, the file is exactly as it was.
        #expect(try await actions.setThemeSync(.editor, on: false).ok)
        #expect(try text() == original)
        #expect(!ctx.store.settings.themeSync.editor)
    }

    @Test func undoTakesTheEditorsColoursOutToo() async throws {
        let ctx = try sandboxContext()
        let actions = Actions(ctx)
        ctx.store.updateSettings { $0.theme = .sunset }
        let on = try await actions.setThemeSync(.editor, on: true)
        #expect(FileManager.default.fileExists(atPath: ctx.paths.editorSettings.path(percentEncoded: false)))
        _ = await actions.undo(on.undo)
        #expect(try JSONKeyPatch.values(EditorTheme.keys, in: String(contentsOf: ctx.paths.editorSettings, encoding: .utf8)).isEmpty)
        #expect(!ctx.store.settings.themeSync.editor)
    }

    @Test func warpGetsAThemeThatFollowsWhileItsOn() async throws {
        let ctx = try sandboxContext()
        let actions = Actions(ctx)
        func warp() throws -> String { try String(contentsOf: ctx.paths.warpTheme, encoding: .utf8) }
        #expect(try await actions.setThemeSync(.warp, on: true).ok)
        #expect(try warp() == WarpTheme.render(.tokyoNight))
        _ = try await actions.applyTheme(.nord, tmux: false)
        #expect(try warp() == WarpTheme.render(.nord))
        #expect(try await actions.setThemeSync(.warp, on: false).ok)
        _ = try await actions.applyTheme(.dracula, tmux: false)
        #expect(try warp() == WarpTheme.render(.nord))
    }

    @Test func theAccentColourRemembersYours() async throws {
        let ctx = try sandboxContext()
        let yours = Preferences.read(WatchedPreferences.globalDomain, MacAccent.key)
        #expect(try await Actions(ctx).setThemeSync(.accent, on: true).ok)
        #expect(ctx.store.settings.themeSync.accent)
        #expect(ctx.store.settings.themeSync.accentBefore == yours)
        if yours != .int(MacAccent.blue.rawValue) {
            #expect(ctx.practiceLog.all.contains { $0.detail == "NSGlobalDomain AppleAccentColor = int(4)" })
        }
    }

    @Test func filesOrbitTookOnLaterAreKeptByBackToBeforeOrbit() async throws {
        let ctx = try sandboxContext()
        let actions = Actions(ctx)
        let sorter = ctx.paths.sorterScript
        // A baseline from before the list was kept, and a sorter script that was there before Orbit managed it.
        ctx.store.setBaseline(Baseline(wallpaper: nil))
        try FileManager.default.createDirectory(at: sorter.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/bash\n# mine\n".utf8).write(to: sorter)
        actions.topUpBaseline()
        let baseline = try #require(ctx.store.baseline)
        #expect(baseline.lookedAt?.contains(sorter.path(percentEncoded: false)) == true)
        #expect(baseline.files[sorter.path(percentEncoded: false)] != nil)

        // Orbit then writes the sorter and Warp's theme; going back keeps the first and takes out the second.
        try Data("#!/bin/bash\n# orbit\n".utf8).write(to: sorter)
        _ = try await actions.setThemeSync(.warp, on: true)
        _ = await actions.restoreBaseline()
        #expect(try String(contentsOf: sorter, encoding: .utf8) == "#!/bin/bash\n# mine\n")
        #expect(!FileManager.default.fileExists(atPath: ctx.paths.warpTheme.path(percentEncoded: false)))
    }
}

@Suite struct WindowLayoutActionTests {
    let windows = """
    [{"id":1,"app":"Warp","title":"","space":1,"frame":{"x":4,"y":44,"w":954,"h":1032},"is-floating":false},
     {"id":2,"app":"Antigravity IDE","title":"Orbit","space":1,"frame":{"x":962,"y":44,"w":954,"h":1032},"is-floating":false}]
    """
    let spaces = #"[{"index":1,"type":"bsp","is-visible":true}]"#

    func fakeYabai() -> FakeSystem {
        let system = FakeSystem()
        system.load(Helper.yabai.label)
        system.answer(CommandResult(status: 0, stdout: windows, ok: true)) { $0.arguments == ["-m", "query", "--windows"] }
        system.answer(CommandResult(status: 0, stdout: spaces, ok: true)) { $0.arguments == ["-m", "query", "--spaces"] }
        return system
    }

    @Test func savingAndArrangingWithUndo() async throws {
        let system = fakeYabai()
        let ctx = try sandboxContext(system)
        let actions = Actions(ctx)
        #expect(await actions.saveWindowLayout(name: "Coding").ok)
        var layout = try #require(ctx.store.settings.windowLayouts.first)
        #expect(layout.desktops.first?.windows.map(\.app) == ["Warp", "Antigravity IDE"])

        // Saved with the IDE on the left: arranging swaps them; undo holds the arrangement from before.
        layout.desktops[0].windows.reverse()
        let outcome = await actions.arrangeWindows(layout)
        #expect(outcome.ok)
        #expect(system.ran("yabai", "-m", "window", "1", "--swap", "2"))
        guard case .arrangeWindows(let before)? = outcome.undo.first else {
            Issue.record("no undo snapshot")
            return
        }
        #expect(before.desktops.first?.windows.map(\.app) == ["Warp", "Antigravity IDE"])
        #expect(await actions.deleteWindowLayout(layout.id).ok)
        #expect(ctx.store.settings.windowLayouts.isEmpty)
    }

    @Test func aDesktopGetsItsOwnStyleLiveAndInTheConfig() async throws {
        let system = fakeYabai()
        let ctx = try sandboxContext(system)
        try FileManager.default.createDirectory(at: ctx.paths.yabairc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(YabaiConfig.render(ctx.store.settings, barReserved: nil).utf8).write(to: ctx.paths.yabairc)
        ctx.store.noteWritten(.yabairc, data: try Data(contentsOf: ctx.paths.yabairc))
        let actions = Actions(ctx)
        #expect(try await actions.setSpaceLayout(2, .stack).ok)
        #expect(system.ran("yabai", "-m", "config", "--space", "2", "layout", "stack"))
        #expect(try String(contentsOf: ctx.paths.yabairc, encoding: .utf8).contains("yabai -m config --space 2 layout stack"))
        #expect(try await actions.setSpaceLayout(2, nil).ok)
        #expect(system.ran("yabai", "-m", "config", "--space", "2", "layout", "bsp"))
        #expect(ctx.store.settings.tiling.spaceLayouts.isEmpty)
    }

    @Test func withoutTilingNothingIsSavedOrMoved() async throws {
        let ctx = try sandboxContext(FakeSystem())
        let failing = FakeSystem()
        failing.answer(CommandResult(status: 1, stderr: "yabai-msg: failed to connect", ok: false)) { $0.arguments.first == "-m" }
        let actions = Actions(try sandboxContext(failing))
        #expect(await !actions.saveWindowLayout(name: "Coding").ok)
        #expect(ctx.store.settings.windowLayouts.isEmpty)
    }
}

@Suite struct ProfileActionTests {
    @Test func importingAppliesEachPartAndUndoPutsItBack() async throws {
        let system = FakeSystem()
        system.load(Helper.yabai.label)
        system.load(Helper.borders.label)
        let ctx = try sandboxContext(system)
        let actions = Actions(ctx)
        // The other Mac: wider gaps, and a glow file edited by hand.
        var theirs = OrbitSettings()
        theirs.tiling.gap = 20
        theirs.modes = []
        let glow = "#!/bin/bash\n# my own glow\nborders width=9.0 token=\(OrbitProfile.tokenPlaceholder)\n"
        let profile = OrbitProfile(settings: theirs, files: [ManagedFile.bordersrc.rawValue: glow], edited: [ManagedFile.bordersrc.rawValue])

        let outcome = try await actions.importProfile(profile)
        #expect(outcome.ok, "\(outcome.message)")
        #expect(ctx.store.settings.tiling.gap == 20)
        #expect(ctx.store.settings.modes.isEmpty)
        #expect(try String(contentsOf: ctx.paths.yabairc, encoding: .utf8).contains(/window_gap +20\n/))
        #expect(try String(contentsOf: ctx.paths.bordersrc, encoding: .utf8) == glow.replacingOccurrences(of: OrbitProfile.tokenPlaceholder, with: ctx.store.linkToken))
        #expect(system.ran("yabai", "-m", "config", "window_gap", "20"))

        _ = await actions.undo(outcome.undo)
        #expect(ctx.store.settings.tiling.gap == 10)
        #expect(ctx.store.settings.modes == ModeDefinition.defaults)
        #expect(!FileManager.default.fileExists(atPath: ctx.paths.bordersrc.path(percentEncoded: false)))
    }

    @Test func handEditedFilesHereAreListedFirst() async throws {
        let ctx = try sandboxContext()
        let actions = Actions(ctx)
        try FileManager.default.createDirectory(at: ctx.paths.bordersrc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# written by Orbit\n".utf8).write(to: ctx.paths.bordersrc)
        ctx.store.noteWritten(.bordersrc, data: Data("# written by Orbit\n".utf8))
        try Data("# changed by me\n".utf8).write(to: ctx.paths.bordersrc)
        var theirs = OrbitSettings()
        theirs.glow.width = 10
        let profile = OrbitProfile(settings: theirs, files: [:], edited: [])
        #expect(actions.filesImportReplaces(profile) == [.bordersrc])
        await #expect(throws: EditedByHand.self) { try await actions.importProfile(profile) }
        let approved = try await actions.importProfile(profile, policy: WritePolicy.askIfEdited.approving(.bordersrc))
        #expect(approved.ok)
    }

    @Test func savingIntoAFolderAndCommittingThere() async throws {
        let system = FakeSystem()
        let ctx = try sandboxContext(system)
        let actions = Actions(ctx)
        try FileManager.default.createDirectory(at: ctx.paths.yabairc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("yabai -m config layout bsp\n".utf8).write(to: ctx.paths.yabairc)
        let folder = ctx.paths.developer.appending(path: "dotfiles/orbit")
        #expect(await actions.exportProfile(intoFolder: folder).ok)
        let profile = try OrbitProfile.decode(Data(contentsOf: folder.appending(path: "Orbit Profile.json")))
        #expect(profile.files["yabairc"] == "yabai -m config layout bsp\n")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "files/yabairc").path(percentEncoded: false)))
        #expect(await actions.commitProfile(in: folder).ok)
        let path = folder.path(percentEncoded: false)
        #expect(system.ran("git", "-C", path, "add", "--", "Orbit Profile.json", "files"))
        #expect(system.commands.contains { $0.arguments.starts(with: ["-C", path, "commit", "-m"]) })
        #expect(!system.commands.contains { $0.arguments.contains("push") })
    }

    @Test func aProfileIsReadFromItsJSON() async throws {
        let ctx = try sandboxContext()
        let file = ctx.paths.home.appending(path: "Orbit Profile.json")
        var settings = OrbitSettings()
        settings.theme = .rosePine
        try OrbitProfile(settings: settings, files: [:], edited: []).encoded().write(to: file)
        #expect(try await Actions(ctx).readProfile(at: file).settings.theme == .rosePine)
    }
}
