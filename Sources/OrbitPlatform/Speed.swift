import AppKit
import Foundation
import OrbitCore

extension Actions {
    /// Switches instant tweaks on or off, as one change with Undo. On, each remembers what it replaces;
    /// off, that comes back (or Apple's default, when nothing was set). The Dock and Finder restart to
    /// show it; apps pick up the rest as they open.
    public func setInstant(_ groups: Set<SpeedTweak.Group>, on: Bool) async -> ActionOutcome {
        let tweaks = SpeedTweak.all.filter { groups.contains($0.group) }
        return await steps { undo in
            var snapshot = settings.speed.before
            var changes: [PreferenceChange] = []
            for tweak in tweaks {
                let id = Baseline.key(tweak.domain, tweak.key)
                if on {
                    let now = ctx.readings.preference(tweak.domain, tweak.key)
                    if !snapshot.knows(id), !tweak.isApplied(now) { snapshot.record(id, now) }
                    changes.append(PreferenceChange(tweak.domain, tweak.key, tweak.value))
                } else {
                    changes.append(PreferenceChange(tweak.domain, tweak.key, snapshot.value(id)))
                    snapshot.forget(id)
                }
            }
            if snapshot != settings.speed.before { undo += changeSettings { $0.speed.before = snapshot } }
            undo += await setPreferences(changes, message: "").undo
            guard on else { return "The animations are back as they were." }
            let reopen = groups.contains(.windows) || groups.contains(.sheets)
            return "Done: the Dock and Finder already show it" + (reopen ? "; apps get it as you open them (reopen any that are open now)." : ".")
        }
    }

    /// Which instant groups are fully on now.
    public func instantGroupsOn() -> Set<SpeedTweak.Group> {
        SpeedTweak.groupsOn { ctx.readings.preference($0, $1) }
    }
}
