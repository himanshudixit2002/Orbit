import Foundation

/// Caps Lock superpowers, written into Karabiner-Elements' config.
///
/// Orbit only touches the rules it owns (descriptions starting with "Orbit: ", plus the two rules
/// written before Orbit existed), so anything added in Karabiner's own window is kept.
public enum KarabinerConfig {
    public static let marker = "Orbit: "
    public static let capsLockDescription = marker + "Caps Lock is Escape when tapped, Hyper (⌘⌃⌥⇧) when held"
    public static let hyperAppsDescription = marker + "Hold Caps Lock + a letter to open an app"
    static let legacyDescriptions: Set<String> = [
        "Caps Lock: Escape when tapped, Hyper (⌘⌃⌥⇧) when held",
        "Hyper + letter opens an app"
    ]
    static let hyper = ["left_shift", "left_command", "left_control", "left_option"]

    static func isOrbitRule(_ rule: Any) -> Bool {
        guard let description = (rule as? [String: Any])?["description"] as? String else { return false }
        return description.hasPrefix(marker) || legacyDescriptions.contains(description)
    }

    /// The shell command a binding runs. Apps open by bundle id when known, so they survive renames;
    /// Orbit commands go through a link carrying this Mac's token (`link`), without bringing Orbit forward.
    public static func launchCommand(_ binding: HyperBinding, link: (OrbitCommand) -> String? = { _ in nil }) -> String {
        func app() -> String? {
            if let id = binding.bundleID, !id.isEmpty { return "-b \(Shell.quote(id))" }
            return binding.appName.isEmpty ? nil : "-a \(Shell.quote(binding.appName))"
        }
        switch binding.action {
        case .app: return "open \(app() ?? "-a Finder")"
        case .website(let url): return "open \(Shell.quote(url))"
        case .folder(let path): return "open \(app().map { $0 + " " } ?? "")\(Shell.quote(path))"
        case .orbit(let command): return link(command).map { "open -g \(Shell.quote($0))" } ?? "true"
        }
    }

    static func rules(_ settings: KeyboardSettings, link: (OrbitCommand) -> String? = { _ in nil }) -> [[String: Any]] {
        guard settings.capsLockEnabled else { return [] }
        let capsLock: [String: Any] = [
            "description": capsLockDescription,
            "manipulators": [[
                "type": "basic",
                "from": ["key_code": "caps_lock", "modifiers": ["optional": ["any"]]],
                "to": [["key_code": "left_shift", "modifiers": ["left_command", "left_control", "left_option"]]],
                "to_if_alone": [["key_code": "escape"]]
            ]]
        ]
        let apps: [String: Any] = [
            "description": hyperAppsDescription,
            "manipulators": settings.hyperApps.map { binding -> [String: Any] in [
                "type": "basic",
                "from": ["key_code": binding.key, "modifiers": ["mandatory": hyper]],
                "to": [["shell_command": launchCommand(binding, link: link)]]
            ]}
        ]
        return [capsLock, apps]
    }

    public struct Unreadable: LocalizedError {
        public var errorDescription: String? {
            "karabiner.json isn't valid JSON, so Orbit left it alone. Fix it in Karabiner-Elements, then try again."
        }
    }

    /// Returns `existing` with Orbit's rules replaced by ones built from `settings`.
    /// With no existing file, writes a minimal config Karabiner accepts; a file that isn't JSON is refused.
    public static func patched(_ existing: Data?, settings: KeyboardSettings, link: (OrbitCommand) -> String? = { _ in nil }) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else { throw Unreadable() }
            root = parsed
        }
        var profiles = root["profiles"] as? [[String: Any]] ?? []
        if profiles.isEmpty {
            profiles = [["name": "Default profile", "selected": true, "virtual_hid_keyboard": ["keyboard_type_v2": "ansi"]]]
        }
        let index = profiles.firstIndex { ($0["selected"] as? Bool) == true } ?? 0
        var profile = profiles[index]
        var complex = profile["complex_modifications"] as? [String: Any] ?? [:]
        var parameters = complex["parameters"] as? [String: Any] ?? [:]
        parameters["basic.to_if_alone_timeout_milliseconds"] = settings.tapTimeout
        complex["parameters"] = parameters
        let kept = (complex["rules"] as? [Any] ?? []).filter { !isOrbitRule($0) }
        complex["rules"] = rules(settings, link: link) + kept
        profile["complex_modifications"] = complex
        profiles[index] = profile
        root["profiles"] = profiles
        if root["global"] == nil { root["global"] = ["show_in_menu_bar": false] }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Whether the selected profile currently has Orbit's Caps Lock rule.
    public static func capsLockActive(in data: Data?) -> Bool {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = root["profiles"] as? [[String: Any]] else { return false }
        let profile = profiles.first { ($0["selected"] as? Bool) == true } ?? profiles.first
        let rules = (profile?["complex_modifications"] as? [String: Any])?["rules"] as? [Any] ?? []
        return rules.contains { rule in
            guard let description = (rule as? [String: Any])?["description"] as? String else { return false }
            return description == capsLockDescription || description == "Caps Lock: Escape when tapped, Hyper (⌘⌃⌥⇧) when held"
        }
    }
}
