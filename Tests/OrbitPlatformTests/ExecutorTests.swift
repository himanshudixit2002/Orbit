import Foundation
import Testing
import OrbitCore
@testable import OrbitPlatform

@Suite struct ExecutorTests {
    let executor = LiveExecutor(home: FileManager.default.temporaryDirectory)

    @Test func capturesOutputAndStatus() async {
        let result = await executor.run(Command("/bin/sh", ["-c", "echo hello; echo oops >&2; exit 3"], effect: .readOnly,
                                                summary: "test", okStatuses: [3]))
        #expect(result.status == 3)
        #expect(result.ok)
        #expect(result.stdout == "hello\n")
        #expect(result.stderr == "oops\n")
    }

    @Test func stopsSlowCommands() async {
        let start = Date()
        let result = await executor.run(Command("/bin/sleep", ["5"], effect: .readOnly, summary: "test", timeout: 0.3))
        #expect(result.timedOut)
        #expect(!result.ok)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func largeOutputDoesNotDeadlock() async {
        let result = await executor.run(Command("/bin/sh", ["-c", "head -c 5000000 /dev/zero | tr '\\\\0' a"], effect: .readOnly,
                                                summary: "test", timeout: 20))
        #expect(result.ok)
        #expect(result.stdout.count >= 4_000_000)
    }

    @Test func missingProgramFailsCleanly() async {
        let result = await executor.run(Command("/nope/not-here", effect: .readOnly, summary: "test"))
        #expect(!result.ok)
    }

    @Test func practiceModeOnlyRunsReadOnlyCommands() async {
        let log = PracticeLog()
        let practice = PracticeExecutor(live: executor, log: log)
        let marker = FileManager.default.temporaryDirectory.appending(path: "orbit-practice-\(UUID().uuidString)")
        let result = await practice.run(Command("/usr/bin/touch", [marker.path], effect: .userFiles, summary: "Make a file"))
        #expect(result.simulated)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(log.all.map(\.summary) == ["Make a file"])
        let read = await practice.run(Command("/bin/echo", ["hi"], effect: .readOnly, summary: "Look"))
        #expect(read.stdout == "hi\n")
    }
}

@Suite struct FileStoreTests {
    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "orbit-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writeKeepsModeAndFollowsSymlinks() throws {
        let dir = try temp()
        let real = dir.appending(path: "real.sh")
        try Data("old".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: real.path)
        let link = dir.appending(path: "link.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try LiveFileStore().write(Data("new".utf8), to: link, executable: false)
        #expect(try String(contentsOf: real, encoding: .utf8) == "new")
        #expect((try FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == real.path)
        let mode = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o750)
    }

    @Test func practiceWritesGoToTheShadowCopy() throws {
        let home = try temp()
        let paths = Paths(home: home)
        let store = PracticeFileStore(paths: paths, log: PracticeLog())
        let target = home.appending(path: ".config/yabai/yabairc")
        try store.write(Data("x".utf8), to: target, executable: true)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(FileManager.default.fileExists(atPath: store.shadow(target).path))
    }

    @Test func backupsNeverOverwrite() throws {
        let dir = try temp()
        let file = dir.appending(path: "a.txt")
        try Data("1".utf8).write(to: file)
        let backups = dir.appending(path: "backups")
        let first = try LiveFileStore().backup(file, into: backups)
        let second = try LiveFileStore().backup(file, into: backups)
        #expect(first != second)
        #expect(FileManager.default.fileExists(atPath: second!.path))
    }
}

@Suite struct ThemeFileTests {
    @Test func tmuxIncludeIsAddedOnceAndRemovedExactly() {
        let conf = "set -g mouse on\n\n# Initialize TPM (keep at very bottom)\nrun '~/.tmux/plugins/tpm/tpm'\n"
        let added = TerminalThemes.tmuxConfWithInclude(conf)
        #expect(added.contains("orbit-theme.conf"))
        #expect(TerminalThemes.tmuxConfWithInclude(added) == added)
        #expect(TerminalThemes.tmuxConfWithoutInclude(added) == conf)
    }

    @Test func btopConfKeepsOtherLines() {
        let conf = "#? Config\ncolor_theme = \"/opt/homebrew/share/btop/themes/tokyo-night.theme\"\nvim_keys = True\n"
        let out = TerminalThemes.btopConf(conf)
        #expect(out.contains("color_theme = \"orbit\""))
        #expect(out.contains("vim_keys = True"))
        #expect(!out.contains("tokyo-night"))
    }

    @Test func wallpaperRendersForEveryTheme() {
        for palette in Palette.all {
            #expect(WallpaperRenderer.render(palette, width: 320, height: 180) != nil)
        }
    }

    @Test func dockEntriesRoundTrip() {
        let tiles = [DockTile(path: "/Applications/Safari.app", label: "Safari"), DockTile(path: "/System/Applications/Notes.app", label: "Notes")]
        let parsed = DockModel.tiles(DockModel.persistentApps(tiles))
        #expect(parsed.map(\.path) == tiles.map(\.path))
        #expect(parsed.map(\.label) == ["Safari", "Notes"])
    }

    @Test func samplerReadsTheMac() {
        let sampler = StatsSampler()
        _ = sampler.sample()
        let s = sampler.sample()
        #expect(s.memoryTotal > 0)
        #expect(s.diskTotal > 0)
        #expect((0...1).contains(s.cpu))
    }
}
