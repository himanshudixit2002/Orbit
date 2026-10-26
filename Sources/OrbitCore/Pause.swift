import Foundation

/// What was on when Orbit was paused, so Resume brings back exactly that. Saved (paused.json), so a
/// pause lasts through Orbit quitting and the Mac restarting: the helpers stay switched off.
public struct PausedState: Codable, Sendable, Equatable {
    /// The switches that were on: window tiling, the glow, the new menu bar, Caps Lock, Downloads.
    public var features: [FeatureID]
    /// The Instant Mac groups that were on.
    public var instant: [SpeedTweak.Group]
    /// The mode that was on, when it's one to start again: switched on by hand, with no timer.
    public var modeID: String?
    public var since: Date

    public init(features: [FeatureID] = [], instant: [SpeedTweak.Group] = [], modeID: String? = nil, since: Date = Date()) {
        self.features = PausePlan.offOrder.filter(features.contains)
        self.instant = SpeedTweak.Group.allCases.filter(instant.contains)
        self.modeID = modeID
        // Whole seconds, as it's saved: read back, it's the same pause.
        self.since = Date(timeIntervalSince1970: since.timeIntervalSince1970.rounded(.down))
    }

    private enum CodingKeys: String, CodingKey { case features, instant, modeID, since }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A switch or group a later Orbit added is skipped rather than costing the whole pause.
        features = (c.value(.features, or: [String]()) as [String]).compactMap(FeatureID.init(rawValue:))
        instant = (c.value(.instant, or: [String]()) as [String]).compactMap(SpeedTweak.Group.init(rawValue:))
        modeID = c.value(.modeID, or: nil)
        since = c.value(.since, or: Date())
    }
}

public enum PausePlan {
    /// The order things are switched off in: the new menu bar first (it hands tiling back the room it
    /// took, which rewrites tiling's config, so a hand-edited one is asked about before anything else).
    public static let offOrder: [FeatureID] = [.menuBar, .tiling, .glow, .capsLock, .downloads]
    /// And back on: tiling before the bar, so the bar can claim its room from it.
    public static let onOrder: [FeatureID] = [.tiling, .glow, .menuBar, .capsLock, .downloads]

    /// What a pause stops, in a sentence: "window tiling, the window glow and Work mode".
    public static func summary(_ state: PausedState, modeName: String?) -> String {
        var parts = state.features.map(\.inSentence)
        if !state.instant.isEmpty { parts.append("Instant Mac") }
        if let modeName { parts.append("\(modeName) mode") }
        guard let last = parts.popLast() else { return "nothing that was running" }
        return parts.isEmpty ? last : parts.joined(separator: ", ") + " and " + last
    }
}
