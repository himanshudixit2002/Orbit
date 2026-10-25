import Foundation

/// What Orbit shows in the menu bar's CPU, memory, clock and mode items.
public struct BarFeedValues: Sendable, Equatable {
    /// Percent across all cores; nil until there are two readings to compare.
    public var cpu: Int?
    public var memory: String
    public var clock: String
    /// The Orbit mode that's on, by name.
    public var mode: String?

    public init(cpu: Int?, memory: String, clock: String, mode: String? = nil) {
        self.cpu = cpu
        self.memory = memory
        self.clock = clock
        self.mode = mode
    }
}

/// Orbit keeps the bar's busiest items up to date itself: one `sketchybar --set` every few seconds
/// instead of the bar running each item's script (four or five processes a run, ~170 a minute in all).
/// Meanwhile the scripts still run once a minute, so the bar carries on if Orbit stops, and they go back
/// to their usual pace when Orbit quits.
public enum BarFeed {
    public static let interval: Duration = .seconds(3)
    /// How often the fed items' own scripts run while Orbit feeds them.
    public static let fallbackSeconds = 60

    /// The items Orbit feeds, with how often their scripts run when it doesn't.
    public static func items(_ bar: BarSettings) -> [(name: String, usualFrequency: Int)] {
        var items: [(String, Int)] = []
        if bar.showCPU { items.append(("cpu", SketchyBarConfig.cpuFrequency)) }
        if bar.showMemory { items.append(("memory", SketchyBarConfig.memoryFrequency)) }
        if bar.showClock { items.append(("clock", SketchyBarConfig.clockFrequency)) }
        return items
    }

    /// Whether Orbit has anything to feed: the stats and clock, or the mode (which only Orbit knows).
    public static func feeds(_ bar: BarSettings) -> Bool { !items(bar).isEmpty || bar.showMode }

    /// Whole percent, as the bar's script shows it (rounded down, at most 100).
    public static func cpuPercent(_ load: Double) -> Int { min(100, max(0, Int(load * 100))) }

    /// Green, amber when busy, red when very busy: the script's colours.
    public static func cpuColor(_ percent: Int, palette: Palette) -> String {
        (percent > 90 ? palette.red : percent > 70 ? palette.yellow : palette.green).argb()
    }

    /// "8.1G": memory in use, as the script shows it.
    public static func memoryLabel(_ bytes: UInt64) -> String {
        String(format: "%.1fG", Double(bytes) / 1_073_741_824)
    }

    /// "Sun 25 Oct  14:05", as the bar's own clock script writes it in the same format.
    public static func clockLabel(_ date: Date, format: ClockFormat = .dayDateTime, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format.dateFormat
        return formatter.string(from: date)
    }

    /// One call setting the items whose values changed since `last` (all of them when `last` is nil),
    /// each with its script slowed to the fallback pace. Nil when there's nothing to send.
    public static func command(_ values: BarFeedValues, last: BarFeedValues?, bar: BarSettings, palette: Palette) -> Command? {
        var arguments: [String] = []
        let slow = "update_freq=\(fallbackSeconds)"
        for (name, _) in items(bar) {
            switch name {
            case "cpu":
                guard let cpu = values.cpu, last == nil || last?.cpu != cpu else { continue }
                arguments += ["--set", name, "label=\(cpu)%", "icon.color=\(cpuColor(cpu, palette: palette))", slow]
            case "memory":
                guard last == nil || last?.memory != values.memory else { continue }
                arguments += ["--set", name, "label=\(values.memory)", slow]
            default:
                guard last == nil || last?.clock != values.clock else { continue }
                arguments += ["--set", name, "label=\(values.clock)", slow]
            }
        }
        if bar.showMode, last == nil || last?.mode != values.mode {
            arguments += ["--set", "mode"] + (values.mode.map { ["drawing=on", "label=\($0)"] } ?? ["drawing=off"])
        }
        guard !arguments.isEmpty else { return nil }
        return Command(Tool.sketchybar, arguments, effect: .display, summary: "Update the menu bar's numbers", timeout: 5)
    }

    /// Hands the items back to their scripts at their usual pace (Orbit is quitting).
    public static func handBack(_ bar: BarSettings) -> Command? {
        let arguments = items(bar).flatMap { ["--set", $0.name, "update_freq=\($0.usualFrequency)"] }
        guard !arguments.isEmpty else { return nil }
        return Command(Tool.sketchybar, arguments, effect: .display, summary: "Let the menu bar update its own numbers again", timeout: 5)
    }
}
