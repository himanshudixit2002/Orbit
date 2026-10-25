import Foundation
import OrbitCore

/// What the running app does for App Intents (Shortcuts, Siri, Focus, widgets, Control Center).
@MainActor
public protocol OrbitCommandHandling: AnyObject {
    func run(_ command: OrbitCommand, source: CommandSource) async -> OrbitReply
    /// A Focus with an Orbit mode set came on (`modeID`) or went off (nil).
    func focusChanged(to modeID: String?) async
}

/// How App Intents reach the app. The app registers itself as soon as it starts; the intents say they
/// run in the app (`allowedExecutionTargets = .main`), so in the widget extension nothing here is used.
@MainActor
public enum OrbitBridge {
    public static weak var handler: (any OrbitCommandHandling)?

    public static func run(_ command: OrbitCommand, source: CommandSource) async -> OrbitReply {
        guard let handler = await ready() else { return OrbitReply(ok: false, message: "Orbit didn't start in time. Try again.") }
        return await handler.run(command, source: source)
    }

    public static func focusChanged(to modeID: String?) async {
        await ready()?.focusChanged(to: modeID)
    }

    /// macOS may have just started Orbit to run this: it gets a few seconds to finish starting.
    private static func ready() async -> (any OrbitCommandHandling)? {
        for _ in 0..<100 where handler == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return handler
    }
}
