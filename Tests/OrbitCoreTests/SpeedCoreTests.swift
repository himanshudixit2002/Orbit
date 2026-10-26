import Foundation
@testable import OrbitCore
import Testing

@Suite struct SpeedTweakTests {
    @Test func durationsAreDoublesAndSwitchesBooleans() {
        for tweak in SpeedTweak.all {
            switch tweak.value {
            case .double, .bool: break
            default: Issue.record("\(tweak.key) has the wrong type")
            }
        }
        #expect(Set(SpeedTweak.all.map(\.group)) == Set(SpeedTweak.Group.allCases))
        #expect(SpeedTweak.tweaks(in: .finder).map(\.key) == ["DisableAllAnimations"])
    }

    @Test func numbersCompareByValueWhateverTheirType() {
        let quickLook = SpeedTweak.all.first { $0.key == "QLPanelAnimationDuration" }!
        #expect(quickLook.isApplied(.double(0)) && quickLook.isApplied(.int(0)))
        #expect(!quickLook.isApplied(.double(0.2)) && !quickLook.isApplied(nil))
        let windows = SpeedTweak.all.first { $0.group == .windows }!
        #expect(windows.isApplied(.bool(false)) && windows.isApplied(.int(0)) && !windows.isApplied(nil))
    }

    @Test func aGroupIsOnWhenAllItsTweaksAre() {
        var values: [String: PrefValue] = [:]
        for tweak in SpeedTweak.tweaks(in: .dock) { values[Baseline.key(tweak.domain, tweak.key)] = tweak.value }
        #expect(SpeedTweak.groupsOn { values[Baseline.key($0, $1)] } == [.dock])
        values[Baseline.key(WatchedPreferences.dockDomain, "launchanim")] = .bool(true)
        #expect(SpeedTweak.groupsOn { values[Baseline.key($0, $1)] }.isEmpty)
    }

    @Test func theWatchedListGrowsWithoutRepeats() {
        let keys = WatchedPreferences.keys.map { Baseline.key($0.domain, $0.key) }
        #expect(keys.count == Set(keys).count)
        #expect(Array(keys.prefix(WatchedPreferences.first.count)) == WatchedPreferences.first.map { Baseline.key($0.domain, $0.key) })
        for tweak in SpeedTweak.all { #expect(keys.contains(Baseline.key(tweak.domain, tweak.key))) }
    }

    @Test func aSnapshotRemembersSetAndUnsetValues() {
        var snapshot = PreferenceSnapshot()
        snapshot.record("a", .double(0.35))
        snapshot.record("b", nil)
        #expect(snapshot.knows("a") && snapshot.knows("b") && !snapshot.knows("c"))
        #expect(snapshot.value("a") == .double(0.35) && snapshot.value("b") == nil)
        snapshot.forget("b")
        #expect(!snapshot.knows("b"))
    }
}
