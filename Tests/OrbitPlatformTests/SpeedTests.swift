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

@Suite struct InstantMacTests {
    let dock = WatchedPreferences.dockDomain

    @Test func everythingInstantThenBackAsItWas() async throws {
        let system = FakeSystem()
        let prefs = FakePreferences([Baseline.key(dock, "autohide-time-modifier"): .double(0.35),
                                     Baseline.key(dock, "expose-animation-duration"): .double(0.12)])
        let ctx = try sandboxContext(system, prefs: prefs)
        let actions = Actions(ctx)
        let on = await actions.setInstant(Set(SpeedTweak.Group.allCases), on: true)
        #expect(on.ok)
        for tweak in SpeedTweak.all { #expect(tweak.isApplied(prefs.read(tweak.domain, tweak.key)), "\(tweak.key)") }
        #expect(actions.instantGroupsOn() == Set(SpeedTweak.Group.allCases))
        #expect(system.ran("killall", "Dock") && system.ran("killall", "Finder"))
        #expect(ctx.store.settings.speed.before.value(Baseline.key(dock, "autohide-time-modifier")) == .double(0.35))

        // Off: the Dock's own speeds come back, and what wasn't set is unset again.
        #expect(await actions.setInstant([.dock, .finder], on: false).ok)
        #expect(prefs.read(dock, "autohide-time-modifier") == .double(0.35))
        #expect(prefs.read(dock, "expose-animation-duration") == .double(0.12))
        #expect(prefs.read(dock, "launchanim") == nil)
        #expect(prefs.read(WatchedPreferences.finderDomain, "DisableAllAnimations") == nil)
        #expect(actions.instantGroupsOn() == [.windows, .sheets])
    }

    @Test func undoPutsEveryValueBack() async throws {
        let prefs = FakePreferences([Baseline.key(dock, "autohide-time-modifier"): .double(0.35)])
        let ctx = try sandboxContext(prefs: prefs)
        let actions = Actions(ctx)
        let on = await actions.setInstant(Set(SpeedTweak.Group.allCases), on: true)
        _ = await actions.undo(on.undo)
        #expect(prefs.read(dock, "autohide-time-modifier") == .double(0.35))
        #expect(prefs.read(WatchedPreferences.globalDomain, "NSAutomaticWindowAnimationsEnabled") == nil)
        #expect(actions.instantGroupsOn().isEmpty)
        #expect(ctx.store.settings.speed.before == PreferenceSnapshot())
    }
}
