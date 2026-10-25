import Foundation
import Testing
@testable import OrbitCore

@Suite struct LineDiffTests {
    @Test func identicalFilesHaveNoChanges() {
        let text = "a\nb\nc\n"
        #expect(LineDiff.diff(text, text).allSatisfy { $0.kind == .same })
        #expect(LineDiff.condensed(LineDiff.diff(text, text)) == [.skipped(3)])
    }

    @Test func oneChangedLineShowsAsRemovedThenAdded() {
        let diff = LineDiff.diff("gap 10\npadding 12\n", "gap 4\npadding 12\n")
        #expect(diff == [LineDiff.Line(.removed, "gap 10"), LineDiff.Line(.added, "gap 4"), LineDiff.Line(.same, "padding 12")])
    }

    @Test func addedAndRemovedLinesAtTheEnds() {
        #expect(LineDiff.diff("a\nb", "a\nb\nc") == [.init(.same, "a"), .init(.same, "b"), .init(.added, "c")])
        #expect(LineDiff.diff("x\na", "a") == [.init(.removed, "x"), .init(.same, "a")])
        #expect(LineDiff.diff("", "new") == [.init(.added, "new")])
    }

    @Test func longUnchangedRunsAreFolded() {
        let old = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 20\n", with: "line twenty\n")
        let rows = LineDiff.condensed(LineDiff.diff(old, new), context: 2)
        #expect(rows.first == .skipped(17))
        #expect(rows.last == .skipped(18))
        #expect(rows.contains(.line(.init(.added, "line twenty"))))
    }
}

@Suite struct DesktopTidyTests {
    @Test func filesGoToTheRightFolders() {
        #expect(DesktopTidy.destination(for: "Note from ChatGPT.txt") == .notes)
        #expect(DesktopTidy.destination(for: "PLAN.md") == .notes)
        #expect(DesktopTidy.destination(for: "Screenshot 2026.PNG") == .media)
        #expect(DesktopTidy.destination(for: "song.mp3") == .media)
        #expect(DesktopTidy.destination(for: "open.spotify.com:collection:tracks.webloc") == .links)
        #expect(DesktopTidy.destination(for: "resume.pdf") == .other)
        #expect(DesktopTidy.destination(for: "Makefile") == .other)
    }

    @Test func freeNameNeverReusesATakenName() {
        let taken: Set<String> = ["a.md", "a 2.md", "README"]
        let isTaken: (String) -> Bool = { taken.contains($0) }
        let fresh = DesktopTidy.freeName("b.md", taken: isTaken)
        let third = DesktopTidy.freeName("a.md", taken: isTaken)
        let noExtension = DesktopTidy.freeName("README", taken: isTaken)
        #expect(fresh == "b.md")
        #expect(third == "a 3.md")
        #expect(noExtension == "README 2")
    }
}

@Suite struct ModeTests {
    @Test func newModesAreUniqueAndCustom() {
        let a = ModeDefinition.newCustom(), b = ModeDefinition.newCustom()
        #expect(a.id != b.id)
        #expect(!a.isBuiltIn)
        let builtIn = ModeDefinition.defaults.allSatisfy { $0.isBuiltIn }
        #expect(builtIn)
    }

    @Test func editedModesSurviveSaving() throws {
        var settings = OrbitSettings()
        var mode = ModeDefinition.newCustom()
        mode.name = "Study"
        mode.openApps = ["Notes"]
        mode.quitApps = ["WhatsApp"]
        mode.keepAwake = .display
        settings.modes.append(mode)
        let reloaded = try OrbitSettings.decode(settings.encoded())
        #expect(reloaded.modes.last == mode)
    }
}

@Suite struct DockTests {
    func app(_ path: String) -> PrefValue {
        DockModel.entry(path: path, label: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    }

    @Test func spacersAreKeptInPlace() {
        let space = PrefValue.dict(["tile-data": .dict([:]), "tile-type": .string("spacer-tile")])
        let small = PrefValue.dict(["tile-data": .dict([:]), "tile-type": .string("small-spacer-tile")])
        let stored = PrefValue.array([app("/Applications/Safari.app"), space, app("/System/Applications/Notes.app"), small])
        let tiles = DockModel.tiles(stored)
        #expect(tiles.map(\.label) == ["Safari", "Space", "Notes", "Small space"])
        #expect(tiles.filter(\.isApp).count == 2)
        #expect(DockModel.persistentApps(tiles) == stored)

        var reordered = tiles
        reordered.swapAt(0, 2)
        #expect(DockModel.persistentApps(reordered)
                == .array([app("/System/Applications/Notes.app"), space, app("/Applications/Safari.app"), small]))
    }
}

@Suite struct JournalOverlapTests {
    @Test func laterChangesToTheSameThingsAreFound() {
        var dracula = OrbitSettings()
        dracula.theme = .dracula
        let theme = JournalEntry(title: "Switched to the Dracula theme",
                                 actions: [.restoreFile(path: "/h/.config/borders/bordersrc", backup: "/b/1"),
                                           .restoreSettings(SettingsUndo(before: OrbitSettings(), after: dracula))])
        let glow = JournalEntry(title: "Changed the window glow", actions: [.restoreFile(path: "/h/.config/borders/bordersrc", backup: "/b/2")])
        let dock = JournalEntry(title: "Tidied the Dock",
                                actions: [.restorePreference(domain: "com.apple.dock", key: "autohide", value: nil)])
        #expect(theme.overtaken(in: [theme, glow, dock]).map(\.title) == ["Changed the window glow"])
        #expect(glow.overtaken(in: [theme, glow, dock]).isEmpty)
        var undoneGlow = glow
        undoneGlow.undone = true
        #expect(theme.overtaken(in: [theme, undoneGlow, dock]).isEmpty)
    }
}
