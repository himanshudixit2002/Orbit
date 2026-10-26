import Foundation
import OrbitCore

extension Actions {
    /// The change behind one of Orbit's switches.
    public func setFeature(_ id: FeatureID, on: Bool, policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        switch id {
        case .tiling:
            return try await setTiling(on, policy: policy)
        case .glow:
            return try await setGlow(on, policy: policy)
        case .menuBar:
            return try await setMenuBar(on, policy: policy)
        case .capsLock:
            var keyboard = settings.keyboard
            keyboard.capsLockEnabled = on
            return try await applyKeyboard(keyboard)
        case .downloads:
            return await setDownloads(on)
        case .raycast, .altTab, .ice, .syntaxHighlight, .terminalLook:
            return ActionOutcome(ok: false, message: "\(id.title) has no on/off switch.")
        }
    }

    /// Switches off what `state` says is on (read just before: the switches, Instant Mac) and remembers
    /// it, so `resume` brings back exactly that. Settings, config files, the theme and the wallpaper
    /// stay as they are. One change, whose Undo brings it all back.
    public func pause(_ state: PausedState, policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        try await switchAll(state, on: false, policy: policy)
    }

    /// Switches back on what was on when Orbit was paused, and ends the pause.
    public func resume(_ state: PausedState, policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        try await switchAll(state, on: true, policy: policy)
    }

    /// Each switch goes through its own change, one after another; one that can't is reported and the
    /// rest still go. A switch whose config file was edited by hand is skipped and asked about once the
    /// rest are done; with the user's OK the whole thing runs again, leaving alone what's already right.
    func switchAll(_ state: PausedState, on: Bool, policy: WritePolicy) async throws -> ActionOutcome {
        var edited: EditedByHand?
        let outcome = await steps { undo in
            // Paused as soon as it starts: if Orbit stops part-way, it still knows what to bring back.
            if !on { undo += setPaused(state) }
            var problems: [String] = []
            for id in PausePlan.order where state.features.contains(id) {
                do {
                    let result = try await setFeature(id, on: on, policy: policy)
                    undo += result.undo
                    if !result.ok { problems.append(result.message) }
                } catch let handEdited as EditedByHand {
                    edited = edited ?? handEdited
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
            if !state.instant.isEmpty {
                let result = await setInstant(Set(state.instant), on: on)
                undo += result.undo
                if !result.ok { problems.append(result.message) }
            }
            if on { undo += setPaused(nil) }
            guard problems.isEmpty else { throw StepFailed(message: problems.joined(separator: " ")) }
            return on ? "Orbit is back: what it was doing is on again." : "Orbit is paused: everything it runs is off until you resume."
        }
        if let edited { throw edited }
        return outcome
    }

    /// Notes whether Orbit is paused, and how to put that back.
    func setPaused(_ paused: PausedState?) -> [UndoAction] {
        let before = ctx.store.paused
        guard before != paused else { return [] }
        ctx.store.setPaused(paused)
        return [.pausedState(before)]
    }
}
