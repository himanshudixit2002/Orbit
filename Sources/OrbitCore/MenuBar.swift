import Foundation

/// One thing the menu bar can show.
public enum BarItem: String, Codable, CaseIterable, Sendable, Identifiable {
    case spaces, frontApp, mode, git, spotify, music, services, disk, cpu, memory, volume, network, clock

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .spaces: "Desktops"
        case .frontApp: "Current app"
        case .mode: "Orbit mode"
        case .git: "Git branch"
        case .spotify: "Spotify song"
        case .music: "Music song"
        case .services: "Dev services"
        case .disk: "Free space"
        case .cpu: "Processor"
        case .memory: "Memory"
        case .volume: "Volume"
        case .network: "Network"
        case .clock: "Clock"
        }
    }

    public var symbol: String {
        switch self {
        case .spaces: "square.grid.3x1.below.line.grid.1x2"
        case .frontApp: "app.badge"
        case .mode: "sparkles"
        case .git: "arrow.triangle.branch"
        case .spotify: "music.note"
        case .music: "music.quarternote.3"
        case .services: "server.rack"
        case .disk: "internaldrive"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .volume: "speaker.wave.2.fill"
        case .network: "wifi"
        case .clock: "clock.fill"
        }
    }

    /// What it shows, for the settings.
    public var blurb: String {
        switch self {
        case .mode: "The Orbit mode that's on"
        case .git: "The branch of the project in the window you're using"
        case .music: "The song playing in Apple Music"
        case .services: "How many Homebrew services are running"
        case .disk: "Free space on your Mac's disk"
        default: title
        }
    }

    /// Numbers that share the stats pill when they sit side by side.
    public var isStat: Bool { [.services, .disk, .cpu, .memory, .volume, .network].contains(self) }

    /// The bar's own name for its (main) item.
    public var barName: String {
        switch self {
        case .spaces: "space"
        case .frontApp: "front_app"
        case .network: "wifi"
        default: rawValue
        }
    }
}

public enum BarSide: String, Codable, CaseIterable, Sendable, Identifiable {
    case left, center, right

    public var id: String { rawValue }
    public var title: String { self == .center ? "Middle" : rawValue.capitalized }
}

public enum BarPosition: String, Codable, CaseIterable, Sendable, Identifiable {
    case top, bottom

    public var id: String { rawValue }
}

/// How the clock reads.
public enum ClockFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case dayDateTime, dayDateTime12, time, time12

    public var id: String { rawValue }

    /// For `date '+…'` in the bar's own script.
    public var strftime: String {
        switch self {
        case .dayDateTime: "%a %d %b  %H:%M"
        case .dayDateTime12: "%a %d %b  %-I:%M %p"
        case .time: "%H:%M"
        case .time12: "%-I:%M %p"
        }
    }

    /// The same, for Orbit's own updates (`BarFeed`).
    public var dateFormat: String {
        switch self {
        case .dayDateTime: "EEE dd MMM  HH:mm"
        case .dayDateTime12: "EEE dd MMM  h:mm a"
        case .time: "HH:mm"
        case .time12: "h:mm a"
        }
    }
}

/// An item and the side of the bar it sits on.
public struct BarPlacement: Codable, Sendable, Hashable {
    public var item: BarItem
    public var side: BarSide

    public init(_ item: BarItem, _ side: BarSide) {
        self.item = item
        self.side = side
    }
}

extension BarSettings {
    /// The usual layout, from the left: desktops and the app, the song in the middle, numbers and the clock.
    public static let defaultLayout: [BarPlacement] = [
        BarPlacement(.spaces, .left), BarPlacement(.frontApp, .left), BarPlacement(.mode, .left), BarPlacement(.git, .left),
        BarPlacement(.spotify, .center), BarPlacement(.music, .center),
        BarPlacement(.services, .right), BarPlacement(.disk, .right), BarPlacement(.cpu, .right), BarPlacement(.memory, .right),
        BarPlacement(.volume, .right), BarPlacement(.network, .right), BarPlacement(.clock, .right)
    ]

    public func isShown(_ item: BarItem) -> Bool {
        switch item {
        case .spaces: showSpaces
        case .frontApp: showFrontApp
        case .mode: showMode
        case .git: showGit
        case .spotify: showSpotify
        case .music: showMusic
        case .services: showServices
        case .disk: showDisk
        case .cpu: showCPU
        case .memory: showMemory
        case .volume: showVolume
        case .network: showNetwork
        case .clock: showClock
        }
    }

    public mutating func setShown(_ item: BarItem, _ on: Bool) {
        switch item {
        case .spaces: showSpaces = on
        case .frontApp: showFrontApp = on
        case .mode: showMode = on
        case .git: showGit = on
        case .spotify: showSpotify = on
        case .music: showMusic = on
        case .services: showServices = on
        case .disk: showDisk = on
        case .cpu: showCPU = on
        case .memory: showMemory = on
        case .volume: showVolume = on
        case .network: showNetwork = on
        case .clock: showClock = on
        }
    }

    /// Every item once, in order: the saved layout, then any it doesn't mention, at the end of their usual side.
    public var placements: [BarPlacement] {
        var seen = Set<BarItem>()
        var all = layout.filter { seen.insert($0.item).inserted }
        all += Self.defaultLayout.filter { !seen.contains($0.item) }
        return all
    }

    /// The items shown on one side, from left to right.
    public func items(on side: BarSide) -> [BarItem] {
        placements.filter { $0.side == side && isShown($0.item) }.map(\.item)
    }

    public func side(of item: BarItem) -> BarSide {
        placements.first { $0.item == item }?.side ?? .right
    }

    /// Swaps an item with the next shown item on its side, to the left (-1) or right (+1).
    public mutating func move(_ item: BarItem, by step: Int) {
        var all = placements
        guard let from = all.firstIndex(where: { $0.item == item }), step != 0 else { return }
        let side = all[from].side
        var to = from + step.signum()
        while all.indices.contains(to), !(all[to].side == side && isShown(all[to].item)) { to += step.signum() }
        guard all.indices.contains(to) else { return }
        all.swapAt(from, to)
        layout = all
    }

    /// Moves an item to the end (the right) of another side.
    public mutating func setSide(_ item: BarItem, _ side: BarSide) {
        var all = placements
        guard let index = all.firstIndex(where: { $0.item == item }), all[index].side != side else { return }
        var placement = all.remove(at: index)
        placement.side = side
        all.append(placement)
        layout = all
    }
}
