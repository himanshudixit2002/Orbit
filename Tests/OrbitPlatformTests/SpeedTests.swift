import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct LatePreferenceKeyTests {
    let global = WatchedPreferences.globalDomain

    @Test func aSettingYouHadBeforeOrbitComesBackInsteadOfBeingCleared() async throws {
        // Your own NSWindowResizeTime, from before Orbit watched it; an old baseline that never looked.
        let prefs = FakePreferences([Baseline.key(global, "NSWindowResizeTime"): .double(0.2)])
        let ctx = try sandboxContext(prefs: prefs)
        ctx.store.setBaseline(Baseline(wallpaper: nil))
        let actions = Actions(ctx)
        actions.topUpBaseline()
        let baseline = try #require(ctx.store.baseline)
        #expect(baseline.preferences[Baseline.key(global, "NSWindowResizeTime")] == .double(0.2))
        #expect(baseline.preferencesLookedAt?.contains(Baseline.key(global, "NSWindowResizeTime")) == true)

        _ = await actions.setPreferences([.init(global, "NSWindowResizeTime", .double(0.001))], message: "Faster")
        _ = await actions.restoreBaseline()
        #expect(prefs.read(global, "NSWindowResizeTime") == .double(0.2))
    }

    @Test func whatOrbitChangedFirstIsReadFromTheHistory() async throws {
        let prefs = FakePreferences()
        let ctx = try sandboxContext(prefs: prefs)
        ctx.store.setBaseline(Baseline(wallpaper: nil))
        let actions = Actions(ctx)
        // Orbit set it before the baseline learned about the key: the history knows it wasn't set.
        let outcome = await actions.setPreferences([.init(global, "QLPanelAnimationDuration", .double(0))], message: "Faster")
        ctx.store.append(JournalEntry(title: "Faster", actions: outcome.undo))
        actions.topUpBaseline()
        #expect(ctx.store.baseline?.preferences[Baseline.key(global, "QLPanelAnimationDuration")] == nil)
        _ = await actions.restoreBaseline()
        #expect(prefs.read(global, "QLPanelAnimationDuration") == nil)
    }

    @Test func aKeyNothingKnowsAboutIsLeftAlone() async throws {
        let prefs = FakePreferences([Baseline.key(global, "NSAutomaticWindowAnimationsEnabled"): .bool(false)])
        let ctx = try sandboxContext(prefs: prefs)
        ctx.store.setBaseline(Baseline(wallpaper: nil))   // looked at the first keys only; no top-up yet
        _ = await Actions(ctx).restoreBaseline()
        #expect(prefs.read(global, "NSAutomaticWindowAnimationsEnabled") == .bool(false))
    }
}

@Suite struct ProcessReadingTests {
    @Test func thisProcessHasItsPathMemoryAndTime() {
        let me = ProcessStat.all().first { $0.pid == getpid() }
        #expect(me != nil)
        #expect(me.map { !$0.path.isEmpty && $0.memory > 0 && $0.cpuTime > 0 } == true)
        _ = StatsSampler.swapUsed()
    }
}
