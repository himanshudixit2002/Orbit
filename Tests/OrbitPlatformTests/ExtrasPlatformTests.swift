import Foundation
import Testing
import OrbitCore
@testable import OrbitPlatform

/// Builds a throwaway home folder so tests never touch the real one.
func tempHome() throws -> Paths {
    let url = FileManager.default.temporaryDirectory.appending(path: "orbit-home-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return Paths(home: url)
}

@Suite struct ConflictTests {
    @Test func handEditedFileStopsTheChangeAndCarriesOrbitsVersion() async throws {
        let paths = try tempHome()
        try FileManager.default.createDirectory(at: paths.yabairc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# my own yabairc\nyabai -m config window_gap 3\n".utf8).write(to: paths.yabairc)
        let actions = Actions(SystemContext.make(mode: .practice, paths: paths))
        do {
            _ = try await actions.applyTiling(TilingSettings())
            Issue.record("expected the hand edit to be noticed")
        } catch let edited as EditedByHand {
            #expect(edited.file == .yabairc)
            #expect(edited.proposed?.contains("yabai -m config window_gap            10") == true)
        }
        // Choosing "Use Orbit's version" goes ahead.
        let outcome = try await actions.applyTiling(TilingSettings(), policy: .overwrite([.yabairc]))
        #expect(outcome.ok)
    }

    @Test func agreeingToReplaceOneEditedFileStillAsksAboutTheNext() async throws {
        let paths = try tempHome()
        for (url, text) in [(paths.batConfig, "--theme=\"Nord\"\n"), (paths.lazygitConfig, "gui:\n  showIcons: true\n")] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let actions = Actions(SystemContext.make(mode: .practice, paths: paths))
        var asked: [ManagedFile] = []
        var policy = WritePolicy.askIfEdited
        for _ in 0..<5 {
            do {
                _ = try await actions.applyTheme(.dracula, tmux: false, policy: policy)
                break
            } catch let edited as EditedByHand {
                asked.append(edited.file)
                policy = policy.approving(edited.file)
            }
        }
        #expect(asked == [.batConfig, .lazygit])
    }

    @Test func aFileAlreadyMatchingOrbitsVersionIsNoConflict() async throws {
        let paths = try tempHome()
        let ctx = SystemContext.make(mode: .practice, paths: paths)
        let actions = Actions(ctx)
        let barOn = await actions.isRunning(.sketchybar)
        let text = YabaiConfig.render(ctx.store.settings, barReserved: barOn ? ctx.store.settings.bar.reservedSpace : nil)
        try FileManager.default.createDirectory(at: paths.yabairc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: paths.yabairc)
        _ = try await actions.applyTiling(TilingSettings())
    }
}

@Suite struct DesktopTidyActionTests {
    @Test func tidiesLooseFilesLeavesFoldersAndUndoes() async throws {
        let paths = try tempHome()
        let fm = FileManager.default
        try fm.createDirectory(at: paths.desktop.appending(path: "Project"), withIntermediateDirectories: true)
        for name in ["notes.md", "photo.png", "site.webloc", "report.pdf", ".hidden"] {
            try Data(name.utf8).write(to: paths.desktop.appending(path: name))
        }
        // Something with the same name is already in Notes: it must not be overwritten.
        try fm.createDirectory(at: paths.at("Documents/Notes"), withIntermediateDirectories: true)
        try Data("older".utf8).write(to: paths.at("Documents/Notes/notes.md"))

        let actions = Actions(SystemContext.make(mode: .live, paths: paths))
        let plan = try #require(actions.desktopTidyPlan())
        #expect(plan.map(\.source.lastPathComponent) == ["notes.md", "photo.png", "report.pdf", "site.webloc"])

        let outcome = actions.tidyDesktop(plan)
        #expect(outcome.ok)
        #expect(fm.fileExists(atPath: paths.at("Documents/Notes/notes 2.md").path))
        #expect(try String(contentsOf: paths.at("Documents/Notes/notes.md"), encoding: .utf8) == "older")
        #expect(fm.fileExists(atPath: paths.at("Documents/Media/photo.png").path))
        #expect(fm.fileExists(atPath: paths.at("Documents/Links/site.webloc").path))
        #expect(fm.fileExists(atPath: paths.at("Documents/From Desktop/report.pdf").path))
        #expect(fm.fileExists(atPath: paths.desktop.appending(path: "Project").path))
        #expect(fm.fileExists(atPath: paths.desktop.appending(path: ".hidden").path))

        let undone = await actions.undo(outcome.undo)
        #expect(undone.ok)
        for name in ["notes.md", "photo.png", "site.webloc", "report.pdf"] {
            #expect(fm.fileExists(atPath: paths.desktop.appending(path: name).path), "\(name) should be back")
        }
        #expect(try String(contentsOf: paths.at("Documents/Notes/notes.md"), encoding: .utf8) == "older")
    }

    @Test func practiceModeMovesNothing() throws {
        let paths = try tempHome()
        try FileManager.default.createDirectory(at: paths.desktop, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: paths.desktop.appending(path: "a.txt"))
        let actions = Actions(SystemContext.make(mode: .practice, paths: paths))
        _ = actions.tidyDesktop(try #require(actions.desktopTidyPlan()))
        #expect(FileManager.default.fileExists(atPath: paths.desktop.appending(path: "a.txt").path))
    }
}
