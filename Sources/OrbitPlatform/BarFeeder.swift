import Foundation
import OrbitCore

/// Keeps the menu bar's CPU, memory and clock up to date from inside Orbit (see `BarFeed`): every few
/// seconds while the bar is running and the screens are awake, live mode only.
public final class BarFeeder: Sendable {
    /// What to feed: the bar's items and colours, and which copy of the bar (a new one starts afresh).
    struct Plan: Equatable {
        var bar: BarSettings
        var palette: Palette
        var barPID: Int?
        var mode: String?
    }

    private struct State {
        var plan: Plan?
        var paused = false
        var loop: Task<Void, Never>?
        var last: BarFeedValues?
        var lastFull: ContinuousClock.Instant?
        var failures = 0
    }

    let ctx: SystemContext
    private let sampler = StatsSampler()
    private let state = Locked(State())
    private let clock: @Sendable () -> Date

    public init(ctx: SystemContext, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.ctx = ctx
        self.clock = clock
    }

    /// Feeds the bar while it's running, with these settings' items and colours.
    public func update(running: Bool, barPID: Int?, bar: BarSettings, palette: Palette, mode: String? = nil) {
        let wanted = running && ctx.mode == .live && BarFeed.feeds(bar)
        let plan = wanted ? Plan(bar: bar, palette: palette, barPID: barPID, mode: mode) : nil
        state.withLock { s in
            guard s.plan != plan else { return }
            s.plan = plan
            s.last = nil
            s.failures = 0
            restart(&s)
        }
    }

    /// Screens asleep or another user's session in front: nothing to show, so nothing to send.
    public func setPaused(_ paused: Bool) {
        state.withLock { s in
            guard s.paused != paused else { return }
            s.paused = paused
            s.last = nil
            restart(&s)
        }
    }

    public var isFeeding: Bool { state.withLock { $0.loop != nil } }

    private func restart(_ s: inout State) {
        s.loop?.cancel()
        s.loop = nil
        guard s.plan != nil, !s.paused else { return }
        s.loop = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: BarFeed.interval, tolerance: .milliseconds(500))
            }
        }
    }

    /// One update: sends what changed, and everything once a minute (in case the bar reloaded).
    func tick() async {
        let now = ContinuousClock.now
        let (plan, last) = state.withLock { s -> (Plan?, BarFeedValues?) in
            if let full = s.lastFull, now - full < .seconds(BarFeed.fallbackSeconds) { return (s.plan, s.last) }
            return (s.plan, nil)
        }
        guard let plan else { return }
        let reading = sampler.cpuAndMemory()
        let values = BarFeedValues(cpu: reading.cpu.map(BarFeed.cpuPercent), memory: BarFeed.memoryLabel(reading.memoryUsed),
                                   clock: BarFeed.clockLabel(clock(), format: plan.bar.clockFormat), mode: plan.mode)
        guard let command = BarFeed.command(values, last: last, bar: plan.bar, palette: plan.palette) else { return }
        let result = await ctx.run(command)
        state.withLock { s in
            guard s.plan == plan else { return }
            guard result.ok else {
                // The bar isn't answering: stop until the next status check finds it running again.
                s.failures += 1
                if s.failures >= 3 {
                    s.plan = nil
                    s.loop?.cancel()
                    s.loop = nil
                }
                return
            }
            s.failures = 0
            s.last = values
            if last == nil { s.lastFull = now }
        }
    }

    /// Orbit is quitting: the items' own scripts take over again at their usual pace.
    public func handBack() async {
        let plan = state.withLock { s in
            s.loop?.cancel()
            s.loop = nil
            defer { s.plan = nil }
            return s.plan
        }
        guard let plan, let command = BarFeed.handBack(plan.bar) else { return }
        await ctx.run(command)
    }
}
