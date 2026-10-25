import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct InstantSorterTests {
    func file(_ url: URL, age: TimeInterval) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path(percentEncoded: false))
    }

    @Test func finishedDownloadsAreSortedIntoTodaysEntry() async throws {
        let ctx = try sandboxContext()
        let downloads = ctx.paths.downloads
        try file(downloads.appending(path: "report.pdf"), age: 120)
        try file(downloads.appending(path: "photo.png"), age: 120)
        try file(downloads.appending(path: "still-coming.zip"), age: 1)
        try file(downloads.appending(path: "kept.txt"), age: 120)
        DownloadsKeep.keep("kept.txt", root: ctx.store.root, downloads: downloads)
        let sorter = InstantSorter(ctx: ctx)
        let moved = await sorter.pass()
        #expect(Set(moved.map(\.path)) == ["Documents/report.pdf", "Images/photo.png"])
        #expect(FileManager.default.fileExists(atPath: downloads.appending(path: "Documents/report.pdf").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: downloads.appending(path: "still-coming.zip").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: downloads.appending(path: "kept.txt").path(percentEncoded: false)))
        let entry = try #require(ctx.store.journal.last)
        #expect(entry.group == "downloads" && entry.title == "Sorted 2 downloads" && entry.actions.count == 2)
        let log = SorterLog.parse(try String(contentsOf: ctx.paths.sorterLog, encoding: .utf8))
        #expect(Set(log.entries.map(\.destination)) == ["Documents/report.pdf", "Images/photo.png"])

        // Put back: home again, and not sorted a second time.
        let back = Actions(ctx).putBack(try #require(log.entries.first { $0.file == "report.pdf" }))
        #expect(back.ok)
        #expect(await sorter.pass().isEmpty)
        #expect(FileManager.default.fileExists(atPath: downloads.appending(path: "report.pdf").path(percentEncoded: false)))
    }

    @Test func rulesRewriteTheHourlySorterAndUndoPutsItBack() async throws {
        let ctx = try sandboxContext()
        let original = "#!/bin/zsh\necho old\n"
        try FileManager.default.createDirectory(at: ctx.paths.sorterScript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: ctx.paths.sorterScript, atomically: true, encoding: .utf8)
        var downloads = DownloadSettings()
        downloads.rules.append(DownloadRule(folder: "Books", extensions: ["mobi"]))
        let actions = Actions(ctx)
        let outcome = try await actions.applyDownloads(downloads, policy: .overwrite([.sorterScript]))
        #expect(outcome.ok)
        #expect(try String(contentsOf: ctx.paths.sorterScript, encoding: .utf8).contains("mobi) echo Books ;;"))
        #expect(ctx.store.settings.downloads.rules.last?.folder == "Books")
        _ = await actions.undo(outcome.undo)
        #expect(try String(contentsOf: ctx.paths.sorterScript, encoding: .utf8) == original)
        #expect(ctx.store.settings.downloads == DownloadSettings())
    }
}
