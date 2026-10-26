import Foundation

/// What Orbit's widgets and Control Center switches show, written by the app whenever it changes (and
/// every ten minutes, so they can tell when Orbit has stopped).
public struct OrbitSnapshot: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case on, off, attention, notInstalled, checking

        public init(_ state: FeatureState) {
            switch state {
            case .on: self = .on
            case .off: self = .off
            case .notInstalled: self = .notInstalled
            case .needsPermission, .blocked: self = .attention
            case .working, .unknown: self = .checking
            }
        }
    }

    public struct Feature: Codable, Sendable, Equatable, Identifiable {
        public var id: FeatureID
        public var state: State
        /// What's wrong, in a sentence, when it needs attention.
        public var detail: String?

        public init(id: FeatureID, state: State, detail: String? = nil) {
            self.id = id
            self.state = state
            self.detail = detail
        }
    }

    public struct Mode: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var symbol: String

        public init(id: String, name: String, symbol: String) {
            self.id = id
            self.name = name
            self.symbol = symbol
        }
    }

    /// When Orbit last wrote it.
    public var written: Date
    /// False once Orbit has quit.
    public var running: Bool
    public var practice: Bool
    public var features: [Feature]
    public var modes: [Mode]
    public var activeMode: String?
    public var theme: ThemeID
    /// When Orbit was paused (everything it runs switched off); nil while it isn't. Optional so a
    /// snapshot written before pausing existed still reads.
    public var pausedSince: Date?

    public init(written: Date = Date(), running: Bool = true, practice: Bool = false, features: [Feature] = [],
                modes: [Mode] = [], activeMode: String? = nil, theme: ThemeID = .tokyoNight, pausedSince: Date? = nil) {
        self.written = written
        self.running = running
        self.practice = practice
        self.features = features
        self.modes = modes
        self.activeMode = activeMode
        self.theme = theme
        self.pausedSince = pausedSince
    }

    /// How often a running Orbit rewrites it, so the widgets can tell it's still there.
    public static let heartbeat: TimeInterval = 600

    public var done: Int { features.filter { $0.state == .on }.count }
    public var attention: [Feature] { features.filter { $0.state == .attention } }

    public func feature(_ id: FeatureID) -> Feature? { features.first { $0.id == id } }
    public func mode(_ id: String) -> Mode? { modes.first { $0.id == id } }

    /// Orbit said it was running and wrote within the last two heartbeats.
    public func isLive(now: Date = Date()) -> Bool {
        running && now.timeIntervalSince(written) < 2 * Self.heartbeat
    }

    /// The same things to show, whenever each was written.
    public func sameContent(as other: OrbitSnapshot) -> Bool {
        var mine = self
        mine.written = other.written
        return mine == other
    }
}
