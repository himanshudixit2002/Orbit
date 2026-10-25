import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct TilingStatusTests {
    func running() -> TilingStatus {
        var status = TilingStatus()
        status.installed = true
        status.yabai = .loaded(running: true, pid: 1, lastExit: nil)
        status.skhd = .loaded(running: true, pid: 2, lastExit: nil)
        return status
    }

    @Test func runningTilingThatWontStartAtLoginNeedsTheUsersOK() {
        var status = running()
        #expect(status.state == .on)
        status.backgroundBlocked = true
        guard case .needsPermission(.backgroundItems, let detail) = status.state else {
            Issue.record("expected the background-items OK, got \(status.state)")
            return
        }
        #expect(detail.contains("restart"))
    }

    @Test func aLaunchAgentThatIsntThereIsNotBlocked() throws {
        let paths = try tempHome()
        #expect(!SystemReadings().backgroundBlocked(paths.launchAgent(Helper.skhd.label)))
    }
}
