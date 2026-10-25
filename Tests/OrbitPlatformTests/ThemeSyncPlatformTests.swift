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
