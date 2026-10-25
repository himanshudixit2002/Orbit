import Foundation

/// A window as yabai describes it (`yabai -m query --windows`), with the fields a layout needs.
public struct YabaiWindow: Decodable, Sendable, Equatable {
    public struct Frame: Codable, Sendable, Hashable {
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double

        public init(x: Double, y: Double, w: Double, h: Double) {
            self.x = x
            self.y = y
            self.w = w
            self.h = h
        }

        /// Within a couple of points: windows land a point or so off where they were asked to go.
        func isClose(to other: Frame) -> Bool {
            abs(x - other.x) < 3 && abs(y - other.y) < 3 && abs(w - other.w) < 3 && abs(h - other.h) < 3
        }
    }

    public var id: Int
    public var app: String
    public var title: String
    public var space: Int
    public var frame: Frame
    public var isFloating: Bool
    public var isMinimized: Bool
    public var isHidden: Bool

    public init(id: Int, app: String, title: String = "", space: Int, frame: Frame, isFloating: Bool = false,
                isMinimized: Bool = false, isHidden: Bool = false) {
        self.id = id
        self.app = app
        self.title = title
        self.space = space
        self.frame = frame
        self.isFloating = isFloating
        self.isMinimized = isMinimized
        self.isHidden = isHidden
    }

    private enum CodingKeys: String, CodingKey {
        case id, app, title, space, frame
        case isFloating = "is-floating", isMinimized = "is-minimized", isHidden = "is-hidden"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        app = c.value(.app, or: "")
        title = c.value(.title, or: "")
        space = try c.decode(Int.self, forKey: .space)
        frame = try c.decode(Frame.self, forKey: .frame)
        isFloating = c.value(.isFloating, or: false)
        isMinimized = c.value(.isMinimized, or: false)
        isHidden = c.value(.isHidden, or: false)
    }

    /// Windows on screen (not minimised or hidden); anything unreadable is skipped.
    public static func parse(_ data: Data) -> [YabaiWindow] {
        ((try? JSONDecoder().decode([Lenient<YabaiWindow>].self, from: data)) ?? []).compactMap(\.value)
            .filter { !$0.isMinimized && !$0.isHidden }
    }
}

/// A desktop as yabai describes it (`yabai -m query --spaces`).
public struct YabaiSpace: Decodable, Sendable, Equatable {
    public var index: Int
    public var layout: TilingLayout
    public var isVisible: Bool

    public init(index: Int, layout: TilingLayout, isVisible: Bool = false) {
        self.index = index
        self.layout = layout
        self.isVisible = isVisible
    }

    private enum CodingKeys: String, CodingKey {
        case index, type
        case isVisible = "is-visible"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        layout = c.value(.type, or: .tiles)
        isVisible = c.value(.isVisible, or: false)
    }

    public static func parse(_ data: Data) -> [YabaiSpace] {
        ((try? JSONDecoder().decode([Lenient<YabaiSpace>].self, from: data)) ?? []).compactMap(\.value)
    }
}

/// One desktop's own window style, instead of the one the others share.
public struct SpaceLayout: Codable, Sendable, Hashable {
    public var space: Int
    public var layout: TilingLayout

    public init(space: Int, layout: TilingLayout) {
        self.space = space
        self.layout = layout
    }
}

/// A saved arrangement of windows: each desktop's style, and where its windows sit.
public struct WindowLayout: Codable, Sendable, Equatable, Identifiable {
    public struct Window: Codable, Sendable, Equatable {
        public var app: String
        public var title: String
        public var floating: Bool
        public var frame: YabaiWindow.Frame

        public init(app: String, title: String, floating: Bool, frame: YabaiWindow.Frame) {
            self.app = app
            self.title = title
            self.floating = floating
            self.frame = frame
        }
    }

    public struct Desktop: Codable, Sendable, Equatable {
        public var index: Int
        public var layout: TilingLayout
        /// Tiled windows in reading order (left to right, then top to bottom), floating ones with their frames.
        public var windows: [Window]

        public init(index: Int, layout: TilingLayout, windows: [Window]) {
            self.index = index
            self.layout = layout
            self.windows = windows
        }

        private enum CodingKeys: String, CodingKey { case index, layout, windows }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            index = try c.decode(Int.self, forKey: .index)
            layout = c.value(.layout, or: .tiles)
            windows = c.value(.windows, or: [])
        }
    }

    public var id: UUID
    public var name: String
    public var saved: Date
    public var desktops: [Desktop]

    public init(id: UUID = UUID(), name: String, saved: Date = Date(), desktops: [Desktop]) {
        self.id = id
        self.name = name
        self.saved = saved
        self.desktops = desktops
    }

    /// What's on screen now, as a layout.
    public static func capture(name: String, windows: [YabaiWindow], spaces: [YabaiSpace], date: Date = Date()) -> WindowLayout {
        let desktops = spaces.sorted { $0.index < $1.index }.compactMap { space -> Desktop? in
            let here = readingOrder(windows.filter { $0.space == space.index })
            guard !here.isEmpty else { return nil }
            return Desktop(index: space.index, layout: space.layout,
                           windows: here.map { Window(app: $0.app, title: $0.title, floating: $0.isFloating, frame: $0.frame) })
        }
        return WindowLayout(name: name, saved: date, desktops: desktops)
    }

    /// Left to right, then top to bottom (a few points either way count as level).
    static func readingOrder(_ windows: [YabaiWindow]) -> [YabaiWindow] {
        windows.sorted {
            let (a, b) = ($0.frame, $1.frame)
            if abs(a.x - b.x) >= 8 { return a.x < b.x }
            if abs(a.y - b.y) >= 8 { return a.y < b.y }
            return $0.id < $1.id
        }
    }

    /// The apps in it, for a one-line description.
    public var summary: String {
        let apps = desktops.flatMap { $0.windows.map(\.app) }
        var seen = Set<String>()
        let names = apps.filter { seen.insert($0).inserted }
        let desktopCount = desktops.count == 1 ? "1 desktop" : "\(desktops.count) desktops"
        return "\(desktopCount): " + names.prefix(5).joined(separator: ", ") + (names.count > 5 ? " and \(names.count - 5) more" : "")
    }
}

/// One thing yabai does to put a layout back. Each works with macOS's System Integrity Protection on,
/// which is why moving windows to another desktop isn't among them.
public enum LayoutStep: Sendable, Equatable {
    case spaceLayout(space: Int, TilingLayout)
    case toggleFloat(window: Int)
    case move(window: Int, x: Double, y: Double)
    case resize(window: Int, w: Double, h: Double)
    case swap(Int, Int)
}

public struct LayoutPlan: Sendable, Equatable {
    public var steps: [LayoutStep] = []
    /// Saved windows that couldn't be put back, a sentence each.
    public var notes: [String] = []

    /// Steps after which windows have moved in ways the plan didn't foresee (they join or leave the tiling).
    public var reshapes: Bool {
        steps.contains {
            switch $0 {
            case .spaceLayout, .toggleFloat: true
            default: false
            }
        }
    }
}

public enum LayoutPlanner {
    /// The steps that turn the windows on screen into `layout`, as far as they can: each saved window
    /// goes to the window of the same app (the same title first) on its desktop.
    public static func plan(_ layout: WindowLayout, windows: [YabaiWindow], spaces: [YabaiSpace]) -> LayoutPlan {
        var plan = LayoutPlan()
        var used = Set<Int>()
        for desktop in layout.desktops {
            guard let space = spaces.first(where: { $0.index == desktop.index }) else {
                plan.notes.append("Desktop \(desktop.index) isn't there any more.")
                continue
            }
            if space.layout != desktop.layout { plan.steps.append(.spaceLayout(space: desktop.index, desktop.layout)) }
            let here = windows.filter { $0.space == desktop.index }
            var pairs: [(saved: WindowLayout.Window, now: YabaiWindow)] = []
            for saved in desktop.windows {
                let candidates = here.filter { $0.app == saved.app && !used.contains($0.id) }
                guard let match = candidates.first(where: { $0.title == saved.title }) ?? candidates.first else {
                    if let elsewhere = windows.first(where: { $0.app == saved.app && !used.contains($0.id) }) {
                        plan.notes.append("\(saved.app) is on desktop \(elsewhere.space), not \(desktop.index): macOS doesn't let Orbit move windows between desktops.")
                    } else {
                        plan.notes.append("\(saved.app) isn't open.")
                    }
                    continue
                }
                used.insert(match.id)
                pairs.append((saved, match))
            }
            for (saved, now) in pairs where saved.floating != now.isFloating {
                plan.steps.append(.toggleFloat(window: now.id))
            }
            for (saved, now) in pairs where saved.floating && !(now.isFloating && saved.frame.isClose(to: now.frame)) {
                plan.steps.append(.move(window: now.id, x: saved.frame.x, y: saved.frame.y))
                plan.steps.append(.resize(window: now.id, w: saved.frame.w, h: saved.frame.h))
            }
            // Tiled windows that are tiled now too: swap them into the saved order.
            let tiled = pairs.filter { !$0.saved.floating && !$0.now.isFloating }
            let wanted = tiled.map(\.now.id)
            var order = WindowLayout.readingOrder(tiled.map(\.now)).map(\.id)
            for position in wanted.indices where order[position] != wanted[position] {
                let other = order.firstIndex(of: wanted[position])!
                plan.steps.append(.swap(order[position], wanted[position]))
                order.swapAt(position, other)
            }
        }
        return plan
    }
}
