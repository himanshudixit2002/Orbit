import Foundation
import OrbitCore

/// Every change to the Mac runs here: one at a time, in the order asked for. Changes with different
/// purposes still share files (a theme and the glow both write bordersrc; the menu bar and tiling both
/// write yabairc), so two at once could each overwrite the other's work. A Swift actor wouldn't do:
/// it lets the next call in whenever the current one waits.
public final class ChangeLane: Sendable {
    public typealias Job = @Sendable () async -> Void

    private struct State {
        var running: String?
        var waiting = 0
    }

    private let jobs: AsyncStream<Job>.Continuation
    private let state = Locked(State())
    /// Set while a change runs, so one that asks for another runs it straight away instead of waiting
    /// behind itself for ever.
    @TaskLocal static var inside = false

    public init() {
        let (stream, jobs) = AsyncStream.makeStream(of: Job.self)
        self.jobs = jobs
        Task.detached(priority: .userInitiated) {
            for await job in stream {
                await ChangeLane.$inside.withValue(true) { await job() }
            }
        }
    }

    /// Runs `work` after every change asked for before it, and hands back its result.
    public func run<T: Sendable>(_ title: String, _ work: @escaping @Sendable () async -> T) async -> T {
        if Self.inside { return await work() }
        state.withLock { $0.waiting += 1 }
        return await withCheckedContinuation { done in
            jobs.yield { [state] in
                state.withLock { $0.running = title; $0.waiting -= 1 }
                let result = await work()
                state.withLock { $0.running = nil }
                done.resume(returning: result)
            }
        }
    }

    /// Nothing running and nothing waiting.
    public var isIdle: Bool { state.withLock { $0.running == nil && $0.waiting == 0 } }

    /// What's being changed right now, for "Finishing …" messages.
    public var currentTitle: String? { state.current.running }
}
