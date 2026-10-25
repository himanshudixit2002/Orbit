import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct CrashSafetyTests {
    func stateFolder() -> URL { FileManager.default.temporaryDirectory.appending(path: "orbit-state-\(UUID().uuidString)") }

    @Test func aChangeCutShortComesBackAsInterruptedWithItsSteps() throws {
        let root = stateFolder()
        let store = StateStore(root: root)
        let id = UUID()
        store.beginChange(id, title: "Changed the theme")
        store.noteSteps([.gitConfig(key: "delta.syntax-theme", value: "old")], change: id)
        // Orbit stops here; the next launch finds it.
        let reopened = StateStore(root: root)
        #expect(reopened.recoverInterrupted().count == 1)
        let entry = try #require(reopened.journal.last)
        #expect(entry.id == id)
        #expect(entry.outcome == .interrupted)
        #expect(entry.actions == [.gitConfig(key: "delta.syntax-theme", value: "old")])
        #expect(entry.message == "Orbit stopped before this finished. Undo puts back what it had already changed.")
        // Handed over once: later launches find nothing more.
        let later = StateStore(root: root)
        #expect(later.recoverInterrupted().isEmpty)
        #expect(later.journal.count == 1)
    }

    @Test func aFinishedChangeLeavesNothingBehind() {
        let store = StateStore(root: stateFolder())
        let id = UUID()
        store.beginChange(id, title: "Changed the theme")
        store.append(JournalEntry(id: id, title: "Changed the theme", actions: [.gitConfig(key: "delta.syntax-theme", value: nil)]))
        // Nothing to undo: not in the history, but finished all the same.
        let quiet = UUID()
        store.beginChange(quiet, title: "Started window tiling again")
        store.append(JournalEntry(id: quiet, title: "Started window tiling again", actions: []))
        #expect(store.inflight.isEmpty)
        #expect(store.journal.map(\.id) == [id])
    }

    @Test func stoppingBetweenTheTwoSavesLeavesNoDuplicate() throws {
        let root = stateFolder()
        let store = StateStore(root: root)
        let id = UUID()
        store.beginChange(id, title: "Changed the theme")
        let underWay = try Data(contentsOf: root.appending(path: "inflight.json"))
        store.append(JournalEntry(id: id, title: "Changed the theme", actions: [.gitConfig(key: "delta.syntax-theme", value: nil)]))
        // The history was saved; Orbit stopped before the list of changes under way was.
        try underWay.write(to: root.appending(path: "inflight.json"))
        let reopened = StateStore(root: root)
        #expect(reopened.recoverInterrupted().isEmpty)
        #expect(reopened.journal.count == 1)
        #expect(reopened.journal.first?.outcome == nil)
    }

    @Test func stepsAreSavedAsTheyHappen() async throws {
        let ctx = try sandboxContext()
        let actions = Actions(ctx)
        let id = UUID()
        ctx.store.beginChange(id, title: "Changed the theme")
        let seen = Locked<[[UndoAction]]>([])
        let first = UndoAction.gitConfig(key: "a", value: nil), second = UndoAction.gitConfig(key: "b", value: nil)
        let outcome = await UndoRecorder.$change.withValue(id) {
            await actions.steps { undo in
                undo.append(first)
                seen.withLock { $0.append(ctx.store.inflight.first?.actions ?? []) }
                // Steps nested inside keep the outer ones' steps in the saved list.
                let inner = await actions.steps { inner in
                    inner.append(second)
                    seen.withLock { $0.append(ctx.store.inflight.first?.actions ?? []) }
                    return "Inner done."
                }
                undo += inner.undo
                return "Done."
            }
        }
        #expect(seen.current == [[first], [first, second]])
        #expect(outcome.undo == [first, second])
        #expect(ctx.store.inflight.first?.actions == [first, second])
    }

    @Test func stepsOutsideAChangeSaveNothing() async throws {
        let ctx = try sandboxContext()
        _ = await Actions(ctx).steps { undo in
            undo.append(.gitConfig(key: "a", value: nil))
            return "Done."
        }
        #expect(ctx.store.inflight.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ctx.store.root.appending(path: "inflight.json").path(percentEncoded: false)))
    }

    @Test func theActiveModeIsKeptAcrossLaunches() {
        let root = stateFolder()
        var record = ModeRecord(modeID: "focus")
        record.closedApps = ["/Applications/Slack.app"]
        StateStore(root: root).setActiveMode(record)
        // Saved dates keep whole seconds.
        let kept = StateStore(root: root).activeMode
        #expect(kept?.modeID == "focus" && kept?.closedApps == ["/Applications/Slack.app"])
        #expect(abs((kept?.started ?? .distantPast).timeIntervalSince(record.started)) < 1)
        StateStore(root: root).setActiveMode(nil)
        #expect(StateStore(root: root).activeMode == nil)
    }
}

@Suite struct AdminScriptTests {
    // Only plain AppleScript here: on a thread of its own, a script that waits (`delay`, the password
    // prompt) needs a running app's main run loop, which a test process doesn't have.
    @Test func aScriptRunsOnItsOwnThreadAndAnswers() async {
        #expect(await KarabinerInstaller.runOnOwnThread("return \"ok\"").output == "ok")
        let cancelled = await KarabinerInstaller.runOnOwnThread("error number -128")
        #expect(cancelled.errorNumber == -128 && cancelled.output == nil)
    }
}

@Suite struct GroupedHistoryTests {
    func entry(_ path: String, date: Date = Date()) -> JournalEntry {
        var entry = JournalEntry(title: "", actions: [.moveBack(current: path, original: "/x/\(path)")], date: date)
        entry.group = "downloads"
        return entry
    }

    @Test func todaysMovesShareOneEntry() {
        let store = StateStore(root: FileManager.default.temporaryDirectory.appending(path: "orbit-group-\(UUID().uuidString)"))
        store.appendOrMerge(entry("a")) { "Sorted \($0) download\($0 == 1 ? "" : "s")" }
        store.append(JournalEntry(title: "Changed the theme", actions: [.gitConfig(key: "k", value: nil)]))
        store.appendOrMerge(entry("b")) { "Sorted \($0) downloads" }
        #expect(store.journal.map(\.title) == ["Changed the theme", "Sorted 2 downloads"])
        #expect(store.journal.last?.actions.count == 2)
    }

    @Test func yesterdaysOrAnUndoneEntryIsntReused() {
        let store = StateStore(root: FileManager.default.temporaryDirectory.appending(path: "orbit-group-\(UUID().uuidString)"))
        store.appendOrMerge(entry("a", date: Date().addingTimeInterval(-86_400 * 2))) { "Sorted \($0)" }
        store.appendOrMerge(entry("b")) { "Sorted \($0)" }
        #expect(store.journal.count == 2)
        store.markUndone(store.journal[1].id)
        store.appendOrMerge(entry("c")) { "Sorted \($0)" }
        #expect(store.journal.count == 3)
    }

    @Test func theLinkTokenIsSecretAndStays() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "orbit-token-\(UUID().uuidString)")
        let token = StateStore(root: root).linkToken
        #expect(token.count == 32 && token.allSatisfy(\.isHexDigit))
        #expect(StateStore(root: root).linkToken == token)
        let mode = try FileManager.default.attributesOfItem(atPath: root.appending(path: "link-token").path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
