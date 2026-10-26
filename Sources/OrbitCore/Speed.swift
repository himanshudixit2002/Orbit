import Foundation

/// Changes that take the waiting out of macOS: its own animations, set as user preferences (what
/// `defaults` writes), each group switched on and off with Undo.
public struct SpeedTweak: Sendable, Equatable {
    public enum Group: String, Codable, CaseIterable, Sendable, Identifiable {
        case windows, sheets, dock, finder

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .windows: "Instant windows"
            case .sheets: "Faster sheets and Quick Look"
            case .dock: "Faster Dock and Mission Control"
            case .finder: "No Finder animations"
            }
        }

        public var blurb: String {
            switch self {
            case .windows: "Windows open and close at once instead of zooming."
            case .sheets: "Save dialogs, Quick Look and full screen switch with almost no animation."
            case .dock: "The Dock slides in twice as fast and app icons stop bouncing."
            case .finder: "Finder windows, Get Info and columns appear without animating."
            }
        }

        public var symbol: String {
            switch self {
            case .windows: "macwindow"
            case .sheets: "eye"
            case .dock: "dock.rectangle"
            case .finder: "folder"
            }
        }
    }

    public let group: Group
    public let domain: String
    public let key: String
    public let value: PrefValue

    public init(_ group: Group, _ domain: String, _ key: String, _ value: PrefValue) {
        self.group = group
        self.domain = domain
        self.key = key
        self.value = value
    }

    /// Durations are doubles and switches booleans, as macOS stores them: a value written with another
    /// type reads back different, and the "already like this" check would never match.
    public static let all: [SpeedTweak] = {
        let global = WatchedPreferences.globalDomain, dock = WatchedPreferences.dockDomain, finder = WatchedPreferences.finderDomain
        return [
            SpeedTweak(.windows, global, "NSAutomaticWindowAnimationsEnabled", .bool(false)),
            SpeedTweak(.sheets, global, "NSWindowResizeTime", .double(0.001)),
            SpeedTweak(.sheets, global, "QLPanelAnimationDuration", .double(0)),
            SpeedTweak(.sheets, global, "NSToolbarFullScreenAnimationDuration", .double(0)),
            SpeedTweak(.sheets, global, "NSBrowserColumnAnimationSpeedMultiplier", .double(0)),
            SpeedTweak(.dock, dock, "autohide-time-modifier", .double(0.15)),
            SpeedTweak(.dock, dock, "expose-animation-duration", .double(0.1)),
            SpeedTweak(.dock, dock, "launchanim", .bool(false)),
            SpeedTweak(.finder, finder, "DisableAllAnimations", .bool(true))
        ]
    }()

    public static func tweaks(in group: Group) -> [SpeedTweak] { all.filter { $0.group == group } }

    /// Whether a value read back is this tweak's. Numbers compare by value, whatever their type.
    public func isApplied(_ current: PrefValue?) -> Bool { PrefValue.same(value, current) }

    /// The groups whose every tweak is in place, given a way to read preferences.
    public static func groupsOn(_ read: (String, String) -> PrefValue?) -> Set<Group> {
        Set(Group.allCases.filter { group in tweaks(in: group).allSatisfy { $0.isApplied(read($0.domain, $0.key)) } })
    }
}

/// Preferences as they were at some moment: set ones by value, and which weren't set.
public struct PreferenceSnapshot: Codable, Sendable, Equatable {
    public var values: [String: PrefValue] = [:]
    public var unset: [String] = []

    public init() {}

    public func knows(_ id: String) -> Bool { values[id] != nil || unset.contains(id) }

    /// The value it had (nil: it wasn't set, or isn't known).
    public func value(_ id: String) -> PrefValue? { values[id] }

    public mutating func record(_ id: String, _ value: PrefValue?) {
        forget(id)
        if let value { values[id] = value } else { unset.append(id) }
    }

    public mutating func forget(_ id: String) {
        values[id] = nil
        unset.removeAll { $0 == id }
    }
}

public struct SpeedSettings: Codable, Sendable, Equatable {
    /// What each instant tweak replaced when it was switched on ("domain|key"), put back when it goes off.
    public var before = PreferenceSnapshot()
    /// A quiet notice with Quit when an app you aren't using takes a lot of memory or processor.
    public var heavyAppNotices = true

    public init() {}

    private enum CodingKeys: String, CodingKey { case before, heavyAppNotices }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        before = c.value(.before, or: PreferenceSnapshot())
        heavyAppNotices = c.value(.heavyAppNotices, or: true)
    }
}

extension PrefValue {
    /// The same setting, whatever number type macOS hands back: 0.3 stored as a float reads as
    /// 0.30000001…, 44 may come back as 44.0, and a switch may be 1 rather than true.
    public static func same(_ a: PrefValue?, _ b: PrefValue?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (.some(let x), .some(let y)): x.sameMeaning(as: y)
        default: false
        }
    }

    func sameMeaning(as other: PrefValue) -> Bool {
        switch (self, other) {
        case (.double(let a), .double(let b)): abs(a - b) < 0.0005
        case (.double(let a), .int(let b)), (.int(let b), .double(let a)): abs(a - Double(b)) < 0.0005
        case (.bool(let a), .int(let b)), (.int(let b), .bool(let a)): a == (b != 0)
        default: self == other
        }
    }
}
