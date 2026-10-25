import Foundation

/// The global shortcut that opens Orbit's command palette from anywhere (Hyper+Space unless changed).
/// Codes and modifier flags are the Carbon ones `RegisterEventHotKey` takes.
public struct HotKeySetting: Codable, Sendable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    /// The key as typed, for showing: "Space", "K".
    public var key: String
    public var enabled: Bool

    public init(keyCode: UInt32, modifiers: UInt32, key: String, enabled: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
        self.enabled = enabled
    }

    // Carbon's modifier flags (cmdKey, shiftKey, optionKey, controlKey) and the space bar's key code.
    public static let command: UInt32 = 0x100
    public static let shift: UInt32 = 0x200
    public static let option: UInt32 = 0x800
    public static let control: UInt32 = 0x1000
    public static let hyper = command | shift | option | control
    public static let spaceKeyCode: UInt32 = 49

    /// Caps Lock held is Hyper (⌃⌥⇧⌘) with Orbit's keyboard setup, so Caps Lock + Space.
    public static let standard = HotKeySetting(keyCode: spaceKeyCode, modifiers: hyper, key: "Space")

    /// "Hyper + Space", or "⌃⌥⌘K".
    public var label: String {
        if modifiers & Self.hyper == Self.hyper { return "Hyper + \(key)" }
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + key
    }

    /// At least two modifiers, or ⌘ or ⌃ with one more key: a single modifier with a letter would get
    /// in the way of typing.
    public var isUsable: Bool {
        let count = [Self.command, Self.shift, Self.option, Self.control].filter { modifiers & $0 != 0 }.count
        return count >= 2
    }
}

/// Whether a shortcut is already taken, by macOS itself or by a window tiling binding in skhdrc.
public enum HotKeyClash {
    static let system: [(HotKeySetting, String)] = [
        (HotKeySetting(keyCode: 49, modifiers: HotKeySetting.command, key: "Space"), "Spotlight"),
        (HotKeySetting(keyCode: 49, modifiers: HotKeySetting.command | HotKeySetting.option, key: "Space"), "Finder's search window"),
        (HotKeySetting(keyCode: 49, modifiers: HotKeySetting.control, key: "Space"), "switching keyboard languages"),
        (HotKeySetting(keyCode: 49, modifiers: HotKeySetting.control | HotKeySetting.option, key: "Space"), "switching keyboard languages"),
        (HotKeySetting(keyCode: 49, modifiers: HotKeySetting.control | HotKeySetting.command, key: "Space"), "Emoji & Symbols"),
        (HotKeySetting(keyCode: 12, modifiers: HotKeySetting.control | HotKeySetting.command, key: "Q"), "locking the screen")
    ]

    /// Why the shortcut is taken, or nil when it's free.
    public static func check(_ hotKey: HotKeySetting, skhdrc: String?) -> String? {
        if let (_, owner) = system.first(where: { $0.0.keyCode == hotKey.keyCode && $0.0.modifiers == hotKey.modifiers }) {
            return "macOS already uses \(hotKey.label) for \(owner)."
        }
        for binding in skhdBindings(skhdrc ?? "") where binding.modifiers == hotKey.modifiers && binding.key == hotKey.key.lowercased() {
            return "Window tiling already uses \(hotKey.label) (in skhdrc)."
        }
        return nil
    }

    /// skhd's bindings ("cmd + shift - k : …", "hyper - space : …") as modifier flags and key names.
    static func skhdBindings(_ text: String) -> [(modifiers: UInt32, key: String)] {
        text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { return nil }
            let combo = line[..<colon]
            guard let dash = combo.range(of: " - ", options: .backwards) else { return nil }
            let key = combo[dash.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            var modifiers: UInt32 = 0
            for part in combo[..<dash.lowerBound].split(separator: "+") {
                switch part.trimmingCharacters(in: .whitespaces).lowercased() {
                case "cmd": modifiers |= HotKeySetting.command
                case "shift": modifiers |= HotKeySetting.shift
                case "alt": modifiers |= HotKeySetting.option
                case "ctrl": modifiers |= HotKeySetting.control
                case "hyper": modifiers |= HotKeySetting.hyper
                case "meh": modifiers |= HotKeySetting.shift | HotKeySetting.option | HotKeySetting.control
                default: return nil
                }
            }
            return (modifiers, key)
        }
    }
}
