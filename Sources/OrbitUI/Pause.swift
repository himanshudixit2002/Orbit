import OrbitCore
import OrbitPlatform
import SwiftUI

extension AppModel {
    /// Switches off everything Orbit runs, after stopping the mode that's on (which puts back what it
    /// changed), and remembers what was on. Orbit itself keeps running in the menu bar to resume.
    @discardableResult
    func pauseOrbit(quiet: Bool = false) async -> OrbitReply {
        guard paused == nil else { return OrbitReply(ok: true, message: "Orbit is already paused.") }
        // Busy from the first click: stopping the mode takes a moment, and a second click mustn't start another pause.
        guard !isBusy("pause"), busy.insert("pause-prep").inserted else { return OrbitReply(ok: false, message: "Orbit is still working on that.") }
        defer { busy.remove("pause-prep") }
        let mode = modes.active
        if mode != nil {
            await modes.stop()
            // What the mode switched is back as it was: look again before choosing what to pause.
            await refresh()
        }
        // A mode with a timer or a schedule isn't started again: its time may be over by then.
        let restart = mode.flatMap { $0.endsAt == nil && !$0.bySchedule ? $0.modeID : nil }
        let instant = await Task.detached(priority: .userInitiated) { [actions] in actions.instantGroupsOn() }.value
        let on = FeatureID.switchable.filter { state($0).isOn || state($0).needsAttention }
        let pausing = PausedState(features: on, instant: Array(instant), modeID: restart)
        let result = await performNow("pause", "Paused Orbit", quiet: quiet) { [actions] policy in
            try await actions.pause(pausing, policy: policy)
        }
        paused = ctx.store.paused
        speedFindings.removeAll { $0.id == "speed-instant" }
        return OrbitReply(ok: result.ok, message: result.message)
    }

    /// Switches back on what was on when Orbit was paused, then starts the mode that was on.
    @discardableResult
    func resumeOrbit(quiet: Bool = false) async -> OrbitReply {
        guard let state = ctx.store.paused else {
            paused = nil
            return OrbitReply(ok: true, message: "Orbit isn't paused.")
        }
        let result = await performNow("pause", "Resumed Orbit", quiet: quiet) { [actions] policy in
            try await actions.resume(state, policy: policy)
        }
        paused = ctx.store.paused
        if paused == nil, let id = state.modeID, modes.active == nil, let mode = settings.modes.first(where: { $0.id == id }) {
            await modes.toggle(mode)
        }
        return OrbitReply(ok: result.ok, message: result.message)
    }

    var pauseBusy: Bool { isBusy("pause") || isBusy("pause-prep") }

    func togglePaused() {
        Task { paused == nil ? await pauseOrbit() : await resumeOrbit() }
    }

    /// "Window tiling, the window glow and Work mode", for "Paused: …".
    var pausedSummary: String {
        guard let paused else { return "" }
        return PausePlan.summary(paused, modeName: paused.modeID.map { id in settings.modes.first { $0.id == id }?.name ?? id })
    }
}

/// The one switch for everything Orbit does: pause it all, or bring it all back.
struct PauseButton: View {
    @Environment(AppModel.self) private var model
    var prominent = false

    var body: some View {
        let isPaused = model.paused != nil
        Button { model.togglePaused() } label: {
            Label(isPaused ? "Resume Orbit" : "Pause everything", systemImage: isPaused ? "play.fill" : "pause.fill")
        }
        .buttonStyle(prominent || isPaused ? AnyButtonStyle(.glassProminent) : AnyButtonStyle(.glass))
        .disabled(model.pauseBusy)
        .help(isPaused ? "Switch back on what was on when you paused" : "Switch off everything Orbit runs; one click brings it back")
    }
}

/// Says that Orbit is paused, since when and what comes back, with Resume.
struct PausedBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let paused = model.paused {
            GlassPanel(padding: 18, glow: .orange) {
                HStack(spacing: 14) {
                    Image(systemName: "pause.circle.fill").font(.system(size: 30)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Orbit is paused").font(.headline)
                        Text("Since \(paused.since.formatted(date: .omitted, time: .shortened)). Resume brings back \(model.pausedSummary).")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    PauseButton()
                }
            }
        }
    }
}
