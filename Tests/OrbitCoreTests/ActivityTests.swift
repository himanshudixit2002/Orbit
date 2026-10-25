import Foundation
@testable import OrbitCore
import Testing

@Suite struct ActivityTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func noticesStayRare() {
        let sent = [NoticePolicy.Sent(key: "failed Glow", kind: "failed", at: now.addingTimeInterval(-120))]
        #expect(!NoticePolicy.allows(key: "failed Glow", kind: "failed", sent: sent, now: now))
        #expect(NoticePolicy.allows(key: "failed Glow", kind: "failed", sent: sent, now: now.addingTimeInterval(600)))
        let three = (1...3).map { NoticePolicy.Sent(key: "failed \($0)", kind: "failed", at: now.addingTimeInterval(-Double($0) * 700)) }
        #expect(!NoticePolicy.allows(key: "failed 4", kind: "failed", sent: three, now: now))
        #expect(NoticePolicy.allows(key: "stopping borders", kind: "keepsStopping", sent: three, now: now))
    }

    @Test func diagnosticsLeaveOutTheHomeFolderAndName() {
        let report = DiagnosticsReport.render([.init("Helpers", ["/Users/himanshudixit/.config/yabai/yabairc", "user himanshudixit"])],
                                              home: "/Users/himanshudixit/", user: "himanshudixit")
        #expect(report.contains("~/.config/yabai/yabairc"))
        #expect(!report.contains("himanshudixit"))
        #expect(report.hasPrefix("## Helpers\n"))
    }
}
