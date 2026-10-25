import Foundation
import OrbitCore

/// One loose file on the Desktop and the folder "Tidy the Desktop" would move it to.
public struct TidyMove: Sendable, Identifiable, Equatable {
    public let source: URL
    public let destination: DesktopTidy.Destination

    public var id: String { source.path(percentEncoded: false) }

    public init(source: URL, destination: DesktopTidy.Destination) {
        self.source = source
        self.destination = destination
    }
}

extension Actions {
    /// The loose files on the Desktop and where each would go, or nil if macOS won't let Orbit look.
    /// Folders and apps stay where they are. The first look makes macOS ask about the Desktop folder.
    public func desktopTidyPlan() -> [TidyMove]? {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: paths.desktop, includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return nil }
        return items
            .filter { (try? $0.resourceValues(forKeys: Set(keys)))?.isDirectory == false }
            .map { TidyMove(source: $0, destination: DesktopTidy.destination(for: $0.lastPathComponent)) }
            .sorted { $0.source.lastPathComponent.localizedStandardCompare($1.source.lastPathComponent) == .orderedAscending }
    }

    /// Moves the files, never over something already there, and records how to put each one back.
    public func tidyDesktop(_ plan: [TidyMove]) -> ActionOutcome {
        let undo = UndoRecorder.forThisTask(ctx.store)
        var moved = 0
        var failed = 0
        for move in plan {
            let folder = paths.at(move.destination.rawValue)
            let name = DesktopTidy.freeName(move.source.lastPathComponent) { ctx.files.exists(folder.appending(path: $0)) }
            let target = folder.appending(path: name)
            do {
                try ctx.files.move(move.source, to: target)
                undo.append(.moveBack(current: target.path(percentEncoded: false), original: move.source.path(percentEncoded: false)))
                moved += 1
            } catch {
                failed += 1
            }
        }
        let files = "\(moved) file\(moved == 1 ? "" : "s")"
        return failed == 0
            ? ActionOutcome(ok: true, message: "Moved \(files) off the Desktop into Documents.", undo: undo.actions)
            : ActionOutcome(ok: false, message: "Moved \(files); \(failed) couldn't be moved (open in another app?).", undo: undo.actions)
    }
}
