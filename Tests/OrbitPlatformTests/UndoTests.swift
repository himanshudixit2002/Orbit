import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct UndoTests {
    /// Every regular file under `folder`, with its text.
    func texts(under folder: URL) -> [String] {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    @Test func undoKeepsTheCurrentFileAndLeavesItAloneWhenTheSavedCopyIsGone() async throws {
        let paths = try tempHome()
        let ctx = SystemContext.make(mode: .practice, paths: paths)
        let actions = Actions(ctx)
        let file = paths.lazygitConfig
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("my own edit\n".utf8).write(to: file)
        let path = file.path(percentEncoded: false)

        let gone = await actions.undo([.restoreFile(path: path, backup: paths.at("no-such-copy").path(percentEncoded: false))])
        #expect(!gone.ok)
        #expect(ctx.practiceLog.all.isEmpty)  // not sent to the Trash

        let saved = paths.at("saved-copy")
        try Data("before Orbit\n".utf8).write(to: saved)
        let outcome = await actions.undo([.restoreFile(path: path, backup: saved.path(percentEncoded: false))])
        #expect(outcome.ok)
        let practiceCopy = try #require((ctx.files as? PracticeFileStore)?.shadow(file))
        #expect(try String(contentsOf: practiceCopy, encoding: .utf8) == "before Orbit\n")
        #expect(texts(under: ctx.store.root.appending(path: "Backups")).contains("my own edit\n"))
        // Orbit now knows that file as its own again, so the next change won't call it hand-edited.
        #expect(ctx.store.registry.verdict(for: .lazygit, current: Data("before Orbit\n".utf8)) == .safe)
    }

    @Test func undoPutsBackTheSettingsAChangeAltered() async throws {
        let paths = try tempHome()
        let ctx = SystemContext.make(mode: .practice, paths: paths)
        let actions = Actions(ctx)
        let before = ctx.store.settings
        var glow = before.glow
        glow.width += 3
        let outcome = try await actions.applyGlow(glow)
        #expect(ctx.store.settings.glow == glow)
        // A mode edited afterwards, outside the journal, must survive the undo.
        ctx.store.updateSettings { $0.modes[0].name = "Deep work" }
        _ = await actions.undo(outcome.undo)
        #expect(ctx.store.settings.glow == before.glow)
        #expect(ctx.store.settings.modes[0].name == "Deep work")
    }

    @Test func switchingOffCountsAHelperThatIsLoadedButNotRunning() {
        let crashing = HelperRun.loaded(running: false, pid: nil, lastExit: 0)
        let running = HelperRun.loaded(running: true, pid: 7, lastExit: nil)
        #expect(Actions.needsSwitching(.yabai, to: false, now: crashing))
        #expect(!Actions.needsSwitching(.yabai, to: false, now: .notLoaded))
        #expect(Actions.needsSwitching(.yabai, to: true, now: crashing))
        #expect(!Actions.needsSwitching(.yabai, to: true, now: running))
        #expect(!Actions.needsSwitching(.sorter, to: true, now: crashing))
    }
}

@Suite struct StateStoreTests {
    @Test func unreadableFilesAreSetAsideNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "orbit-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("[{\"not\": \"a journal\"".utf8).write(to: root.appending(path: "journal.json"))
        try Data("{\"from\": \"a newer Orbit\"}".utf8).write(to: root.appending(path: "baseline.json"))
        let store = StateStore(root: root)
        #expect(store.journal.isEmpty)
        #expect(store.baseline == nil)
        // A new baseline now would record Orbit's own changes as "before Orbit".
        #expect(store.baselineUnreadable)
        store.append(JournalEntry(title: "Switched theme", actions: [.gitConfig(key: "delta.syntax-theme", value: nil)]))
        let kept = try String(contentsOf: root.appending(path: "journal (unreadable).json"), encoding: .utf8)
        #expect(kept == "[{\"not\": \"a journal\"")
    }
}

@Suite struct PracticeFilesTests {
    @Test func practiceModeReadsBackItsOwnWritesAndLeavesTheRealFile() throws {
        let paths = try tempHome()
        let files = PracticeFileStore(paths: paths, log: PracticeLog())
        let file = paths.batConfig
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("real\n".utf8).write(to: file)
        #expect(files.read(file) == Data("real\n".utf8))
        try files.write(Data("practice\n".utf8), to: file, executable: false)
        #expect(files.read(file) == Data("practice\n".utf8))
        #expect(try Data(contentsOf: file) == Data("real\n".utf8))
    }
}

@Suite struct PartialChangeTests {
    struct DiskFull: LocalizedError {
        var errorDescription: String? { "The disk is full." }
    }

    @Test func aChangeThatFailsHalfwayKeepsWhatItAlreadyDidForUndo() async throws {
        let actions = Actions(SystemContext.make(mode: .practice, paths: try tempHome()))
        let outcome = await actions.steps { undo in
            undo.append(.gitConfig(key: "delta.syntax-theme", value: nil))
            throw DiskFull()
        }
        #expect(!outcome.ok)
        #expect(outcome.undo == [.gitConfig(key: "delta.syntax-theme", value: nil)])
        #expect(outcome.message.hasPrefix("The disk is full."))
    }

    @Test func aHelperThatWontStartStopsTheChangeAndCanBeUndone() async throws {
        let actions = Actions(SystemContext.make(mode: .practice, paths: try tempHome()))
        let outcome = await actions.steps { undo in
            undo.append(.restorePreference(domain: "NSGlobalDomain", key: "_HIHideMenuBar", value: .bool(false)))
            throw StepFailed(message: "Couldn't start the menu bar: Error: Formula not installed.", undo: [.helper(.sketchybar, wasOn: false)])
        }
        #expect(!outcome.ok)
        #expect(outcome.message.hasPrefix("Couldn't start the menu bar"))
        #expect(outcome.undo == [.restorePreference(domain: "NSGlobalDomain", key: "_HIHideMenuBar", value: .bool(false)),
                                 .helper(.sketchybar, wasOn: false)])
    }

    @Test func aFailedHelperCommandBecomesAPlainMessage() async throws {
        let actions = Actions(SystemContext.make(mode: .practice, paths: try tempHome()))
        let missing = CommandResult.launchFailure("Couldn't start /opt/homebrew/bin/yabai: The file doesn't exist.")
        #expect(await actions.failure(of: missing, switching: .yabai, on: true)
                == "Couldn't start window tiling: Couldn't start /opt/homebrew/bin/yabai: The file doesn't exist.")
        // Practice mode can't look at launchd's real state, so a command that went through is trusted.
        #expect(await actions.failure(of: .simulatedSuccess, switching: .yabai, on: true) == nil)
    }
}

@Suite struct JournalLoadingTests {
    @Test func oneUnreadableEntryDoesntCostTheRest() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "orbit-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let good = JournalEntry(title: "Switched theme", actions: [.gitConfig(key: "delta.syntax-theme", value: nil)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var entries = try JSONSerialization.jsonObject(with: encoder.encode([good])) as! [Any]
        // An entry written by a newer Orbit, with an undo step this one doesn't know.
        entries.append(["id": UUID().uuidString, "date": "2026-10-25T12:00:00Z", "title": "Something new",
                        "undone": false, "actions": [["teleport": ["where": "moon"]]]])
        let file = root.appending(path: "journal.json")
        try JSONSerialization.data(withJSONObject: entries).write(to: file)

        let store = StateStore(root: root)
        #expect(store.journal.map(\.title) == ["Switched theme"])
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "journal (unreadable).json").path(percentEncoded: false)))
    }
}

@Suite struct BeforeOrbitTests {
    @Test func aFileTheSnapshotLacksComesBackFromOrbitsFirstBackupOfIt() {
        var baseline = Baseline(wallpaper: nil)
        baseline.files["/h/.config/bat/config"] = "/b/before/config"
        let btop = "/h/.config/btop/btop.conf"
        let plugin = "/h/.config/sketchybar/plugins/cpu.sh"
        let journal = [
            JournalEntry(title: "Switched to the Tokyo Night theme", actions: [.restoreFile(path: btop, backup: "/b/1/btop.conf"),
                                                                               .restoreFile(path: plugin, backup: nil)]),
            JournalEntry(title: "Switched to the Nord theme", actions: [.restoreFile(path: btop, backup: "/b/2/btop.conf")])
        ]
        #expect(Actions.before("/h/.config/bat/config", baseline: baseline, journal: journal) == .copy("/b/before/config"))
        #expect(Actions.before(btop, baseline: baseline, journal: journal) == .copy("/b/1/btop.conf"))
        #expect(Actions.before(plugin, baseline: baseline, journal: journal) == .absent)
        #expect(Actions.before("/h/.zshrc", baseline: baseline, journal: journal) == .unknown)
    }
}

@Suite struct RestoreBaselineTests {
    @Test func backToBeforeOrbitTakesOrbitsPartsOutOfTmuxAndBtop() async throws {
        let paths = try tempHome()
        let ctx = SystemContext.make(mode: .practice, paths: paths)
        let actions = Actions(ctx)
        for url in [paths.tmuxConf, paths.btopConf] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(TerminalThemes.tmuxConfWithInclude("set -g mouse on\n").utf8).write(to: paths.tmuxConf)
        try Data("color_theme = \"orbit\"\nupdate_ms = 1500\n".utf8).write(to: paths.btopConf)
        let firstBackup = paths.at("first-backup-btop.conf")
        try Data("color_theme = \"Default\"\nupdate_ms = 1500\n".utf8).write(to: firstBackup)
        ctx.store.setBaseline(Baseline(wallpaper: nil))
        ctx.store.append(JournalEntry(title: "Switched to the Tokyo Night theme",
                                      actions: [.restoreFile(path: paths.btopConf.path(percentEncoded: false),
                                                             backup: firstBackup.path(percentEncoded: false))]))

        _ = await actions.restoreBaseline()
        let practice = try #require(ctx.files as? PracticeFileStore)
        #expect(try String(contentsOf: practice.shadow(paths.tmuxConf), encoding: .utf8) == "set -g mouse on\n")
        #expect(try String(contentsOf: practice.shadow(paths.btopConf), encoding: .utf8) == "color_theme = \"Default\"\nupdate_ms = 1500\n")
    }
}

@Suite struct LoginItemTests {
    @Test func scriptsSayWhetherTheyChangedAnything() {
        #expect(Actions.loginItemScript(name: "Raycast", path: "/Applications/Raycast.app", on: true) == """
        tell application "System Events"
        if exists login item "Raycast" then return "already"
        make login item at end with properties {path:"/Applications/Raycast.app", hidden:false}
        return "changed"
        end tell
        """)
        #expect(Actions.loginItemScript(name: "Raycast", path: "/Applications/Raycast.app", on: false) == """
        tell application "System Events"
        if not (exists login item "Raycast") then return "already"
        delete login item "Raycast"
        return "changed"
        end tell
        """)
    }
}

@Suite struct BackupTidyingTests {
    func folder(_ name: String, in backups: URL, daysOld: Double) throws -> URL {
        let url = backups.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("a backup\n".utf8).write(to: url.appending(path: "bordersrc"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -daysOld * 86_400)],
                                              ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    @Test func onlyOldBackupsNothingPointsToAreUnneeded() async throws {
        let ctx = SystemContext.make(mode: .practice, paths: try tempHome())
        let actions = Actions(ctx)
        let backups = actions.backupsFolder
        let stillUndoable = try folder("2026-09-01 100000 glow style", in: backups, daysOld: 30)
        let forgotten = try folder("2026-09-02 100000 glow style", in: backups, daysOld: 30)
        _ = try folder("2026-10-25 100000 glow style", in: backups, daysOld: 0)
        _ = try folder("Before Orbit", in: backups, daysOld: 30)
        ctx.store.append(JournalEntry(title: "Changed the window glow",
                                      actions: [.restoreFile(path: "/h/.config/borders/bordersrc",
                                                             backup: stillUndoable.appending(path: "bordersrc").path(percentEncoded: false))]))

        #expect(actions.unneededBackups().map(\.lastPathComponent) == [forgotten.lastPathComponent])
        // Practice mode only says what it would do: the folder stays where it is.
        #expect(actions.clearUnneededBackups() == 1)
        #expect(ctx.practiceLog.all.contains { $0.summary.contains("Trash") })
        #expect(FileManager.default.fileExists(atPath: forgotten.path(percentEncoded: false)))
    }
}
