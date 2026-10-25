import Foundation
@testable import OrbitCore
import Testing

@Suite struct DownloadSorterTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func finishedFilesMoveAndTheRestWait() {
        let items = [
            DownloadSorter.Item(name: "report.pdf", isFile: true, modified: now.addingTimeInterval(-60)),
            DownloadSorter.Item(name: "photo.HEIC", isFile: true, modified: now.addingTimeInterval(-30)),
            DownloadSorter.Item(name: "movie.mp4", isFile: true, modified: now.addingTimeInterval(-3)),
            DownloadSorter.Item(name: "big.zip.crdownload", isFile: true, modified: now.addingTimeInterval(-600)),
            DownloadSorter.Item(name: ".DS_Store", isFile: true, modified: now.addingTimeInterval(-600)),
            DownloadSorter.Item(name: "Images", isFile: false, modified: now.addingTimeInterval(-600)),
            DownloadSorter.Item(name: "notes", isFile: true, modified: now.addingTimeInterval(-600))
        ]
        let (moves, lookAgain) = DownloadSorter.plan(items, settings: DownloadSettings(), now: now, settle: 10) { folder, name in
            folder == "Documents" && name == "report.pdf"
        }
        #expect(moves == [
            DownloadSorter.Move(name: "notes", folder: "Other", destination: "notes"),
            DownloadSorter.Move(name: "photo.HEIC", folder: "Images", destination: "photo.HEIC"),
            DownloadSorter.Move(name: "report.pdf", folder: "Documents", destination: "report (2).pdf")
        ])
        #expect(lookAgain == now.addingTimeInterval(7))
    }

    @Test func twoFilesWithOneNameDontCollide() {
        let items = ["a.txt", "a.TXT"].map { DownloadSorter.Item(name: $0, isFile: true, modified: now.addingTimeInterval(-100)) }
        let (moves, _) = DownloadSorter.plan(items, settings: DownloadSettings(), now: now, settle: 10) { _, _ in false }
        #expect(Set(moves.map(\.destination)) == ["a.txt", "a.TXT"])
        #expect(DownloadSorter.freeName("a.txt") { ["a.txt", "a (2).txt"].contains($0) } == "a (3).txt")
        #expect(DownloadSorter.freeName("README") { $0 == "README" } == "README (2)")
    }

    @Test func logLinesReadBackAsTheHourlySortersDo() throws {
        let move = DownloadSorter.Move(name: "report.pdf", folder: "Documents", destination: "report (2).pdf")
        let log = SorterLog.parse(DownloadSorter.logLine(move, at: now))
        let entry = try #require(log.entries.first)
        #expect(entry.file == "report.pdf" && entry.folder == "Documents" && entry.destination == "Documents/report (2).pdf")
    }
}

@Suite struct SorterScriptTests {
    @Test func theDefaultScriptSortsExactlyAsBefore() throws {
        let script = SorterScript.render(DownloadSettings())
        #expect(script.contains("    pdf|doc|docx|txt|md|rtf|pages|key|numbers|ppt|pptx|xls|xlsx|csv|epub|tex) echo Documents ;;"))
        #expect(script.contains("    webloc|url) echo Links ;;"))
        #expect(script.contains("    *) echo Other ;;"))
        #expect(script.contains("kill -0 $pid") && script.contains("downloads-keep.txt"))
        // zsh itself checks it parses.
        let file = FileManager.default.temporaryDirectory.appending(path: "orbit-sorter-\(UUID().uuidString).zsh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let zsh = Process()
        zsh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        zsh.arguments = ["-n", file.path(percentEncoded: false)]
        try zsh.run()
        zsh.waitUntilExit()
        #expect(zsh.terminationStatus == 0)
    }

    @Test func folderNamesAreQuotedAndEndingsCleaned() {
        var settings = DownloadSettings()
        settings.rules = [DownloadRule(folder: "My Books", extensions: [".EPUB", "mobi", "a;b"])]
        settings.otherFolder = "Misc's"
        let script = SorterScript.render(settings)
        #expect(script.contains("    epub|mobi|ab) echo 'My Books' ;;"))
        #expect(script.contains(#"    *) echo 'Misc'\''s' ;;"#))
    }
}

@Suite struct SimulatorRuntimeTests {
    @Test func theRuntimeListIsRead() throws {
        let text = """
        == Disk Images ==
        -- iOS --
        iOS 26.1 (23B86) - 5060E103-3B22-49AB-94F9-E5F8EEB1F0F3 (Ready)
        -- watchOS --
        watchOS 26.0 (23R354) - 11111111-3B22-49AB-94F9-E5F8EEB1F0F3 (Ready)

        Total Disk Images: 2 (12.5G)
        """
        let runtimes = try #require(SimulatorRuntimes.parse(text))
        #expect(runtimes.detail == "iOS 26.1, watchOS 26.0")
        #expect(runtimes.size == 12_500_000_000)
        #expect(SimulatorRuntimes.parse("== Disk Images ==\nTotal Disk Images: 0 (0B)") == nil)
    }
}
