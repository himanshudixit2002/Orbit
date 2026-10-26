import Foundation
@testable import OrbitCore
import Testing

@Suite struct PauseCoreTests {
    @Test func whatWasOnIsKeptInOrbitsOrder() throws {
        let state = PausedState(features: [.downloads, .tiling, .menuBar], instant: [.finder, .windows], modeID: "focus")
        #expect(state.features == [.menuBar, .tiling, .downloads])
        #expect(state.instant == [.windows, .finder])
        #expect(PausePlan.order.filter(state.features.contains) == [.menuBar, .tiling, .downloads])
        #expect(PausePlan.summary(state, modeName: "Focus") == "the new menu bar, window tiling, Downloads sorting, Instant Mac and Focus mode")
        #expect(PausePlan.summary(PausedState(features: [.glow]), modeName: nil) == "the window glow")
        #expect(PausePlan.summary(PausedState(), modeName: nil) == "nothing that was running")
    }

    @Test func aPauseReadsBackAndSkipsWhatItDoesntKnow() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = PausedState(features: [.glow], instant: [.dock], modeID: nil, since: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try decoder.decode(PausedState.self, from: encoder.encode(state)) == state)
        let later = Data(#"{"features":["glow","hologram"],"instant":["dock","teleport"],"since":"2027-01-15T08:00:00Z"}"#.utf8)
        let read = try decoder.decode(PausedState.self, from: later)
        #expect(read.features == [.glow] && read.instant == [.dock] && read.modeID == nil)
    }

    @Test func pauseAndResumeHaveLinks() throws {
        #expect(OrbitLink.command(from: URL(string: "orbit://pause?token=abc")!) == .setPaused(true))
        #expect(OrbitLink.command(from: URL(string: "orbit://resume")!) == .setPaused(false))
        #expect(OrbitLink.url(for: .setPaused(true), token: "t")?.absoluteString == "orbit://pause?token=t")
        #expect(OrbitLink.url(for: .setPaused(false), token: "t")?.absoluteString == "orbit://resume?token=t")
        #expect(!OrbitCommand.setPaused(true).showsOrbit)
        #expect(UndoAction.pausedState(nil).targets == ["orbit paused"])
    }

    @Test func aSnapshotFromBeforePausingStillReads() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = Data(#"{"written":"2026-10-25T10:00:00Z","running":true,"practice":false,"features":[],"modes":[],"theme":"nord"}"#.utf8)
        let snapshot = try decoder.decode(OrbitSnapshot.self, from: old)
        #expect(snapshot.pausedSince == nil && snapshot.theme == .nord)
    }
}
