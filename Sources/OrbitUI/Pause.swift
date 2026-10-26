import OrbitCore
import OrbitPlatform
import SwiftUI

extension AppModel {
    /// Switches off everything Orbit runs and remembers what was on. The mode that's on stays on with
    /// what it changed, so Resume never opens, quits or hides apps; it only stops keeping the Mac awake.
    /// Orbit itself keeps running in the menu bar to resume.
    @discardableResult
    func pauseOrbit(quiet: Bool = false) async -> OrbitReply {
        guard paused == nil else { return OrbitReply(ok: true, message: "Orbit is already paused.") }
        guard modes.working == nil else { return OrbitReply(ok: false, message: "Orbit is still switching modes.") }
        // Busy from the first click: reading what's on takes a moment, and a second click mustn't start another pause.
        guard !isBusy("pause"), busy.insert("pause-prep").inserted else { return OrbitReply(ok: false, message: "Orbit is still working on that.") }
        defer { busy.remove("pause-prep") }
        let instant = await Task.detached(priority: .userInitiated) { [actions] in actions.instantGroupsOn() }.value
        let on = FeatureID.switchable.filter { state($0).isOn || state($0).needsAttention }
        let pausing = PausedState(features: on, instant: Array(instant), modeID: modes.active?.modeID)
        let result = await performNow("pause", "Paused Orbit", quiet: quiet) { [actions] policy in
            try await actions.pause(pausing, policy: policy)
        }
        paused = ctx.store.paused
        if paused != nil { modes.hold() }
        speedFindings.removeAll { $0.id == "speed-instant" }
        return OrbitReply(ok: result.ok, message: result.message)
    }

    /// Switches back on what was on when Orbit was paused; the mode that's on keeps the Mac awake again.
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
        if paused == nil { modes.resume() }
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
