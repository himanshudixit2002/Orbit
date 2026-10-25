import Foundation

/// The window tiling cheat sheet (⌥ /) keeps its Caps Lock part up to date: Orbit rewrites only that
/// paragraph, from the current Hyper keys, and leaves everything else as the user wrote it.
public enum CheatSheet {
    public struct Extra: Sendable, Equatable {
        public var keys: String
        public var does: String

        public init(keys: String, does: String) {
            self.keys = keys
            self.does = does
        }
    }

    /// The Caps Lock paragraph.
    public static func block(capsLock: Bool, bindings: [HyperBinding], palette: HotKeySetting?, extras: [Extra] = []) -> [String] {
        func row(_ label: String, _ keys: String, _ does: String) -> String {
            let line = column(label, 15) + column(keys, 23) + does
            return String(line[..<(line.lastIndex { $0 != " " }.map(line.index(after:)) ?? line.startIndex)])
        }
        var lines: [String] = []
        if capsLock {
            lines.append(row("CAPS LOCK", "tap", "Escape"))
            // Three to a row, in the order the user keeps them.
            let cells = bindings.map { column("\($0.key.uppercased()) \(short($0.appName))", 13) }
            for (index, start) in stride(from: 0, to: cells.count, by: 3).enumerated() {
                let three = cells[start..<min(start + 3, cells.count)].joined()
                lines.append(index == 0 ? row("HYPER", "hold Caps Lock + …", three) : row("", "", three))
            }
        } else {
            lines.append(row("CAPS LOCK", "", "plain Caps Lock (superpowers are off in Orbit)"))
        }
        if let palette, palette.enabled {
            let keys = palette.modifiers == HotKeySetting.hyper && capsLock ? "Caps Lock + \(palette.key.lowercased())" : palette.label
            lines.append(row("ORBIT", keys, "command palette (⌘K in Orbit)"))
        }
        for extra in extras { lines.append(row("", extra.keys, extra.does)) }
        return lines
    }

    /// Text padded to a column, or followed by one space when it's wider (never cut short).
    static func column(_ text: String, _ width: Int) -> String {
        text.count < width ? text.padding(toLength: width, withPad: " ", startingAt: 0) : text + " "
    }

    /// "Google Chrome" → "Chrome", "Antigravity IDE" → "Antigravity".
    static func short(_ name: String) -> String {
        var name = name
        if name.hasPrefix("Google ") { name.removeFirst(7) }
        if name.hasSuffix(" IDE") { name.removeLast(4) }
        return name
    }

    /// The sheet with its Caps Lock paragraph (from the line starting "CAPS LOCK" to the next blank
    /// line) replaced; added at the end if it has none, or a new sheet when there's no file.
    public static func update(_ sheet: String?, block: [String]) -> String {
        guard let sheet else {
            return (["KEYBOARD CHEAT SHEET", String(repeating: "=", count: 20), ""] + block + [""]).joined(separator: "\n")
        }
        var lines = sheet.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("CAPS LOCK") }) else {
            let trimmed = sheet.hasSuffix("\n") ? String(sheet.dropLast()) : sheet
            return ([trimmed, ""] + block + [""]).joined(separator: "\n")
        }
        let end = lines[start...].firstIndex { $0.trimmingCharacters(in: .whitespaces).isEmpty } ?? lines.count
        lines.replaceSubrange(start..<end, with: block)
        return lines.joined(separator: "\n")
    }
}
