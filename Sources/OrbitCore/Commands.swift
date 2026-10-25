import Foundation

/// Where the tools Orbit drives are installed. Homebrew's live under its prefix, found once: the
/// HOMEBREW_PREFIX setting if there is one, else /opt/homebrew (Apple silicon), else /usr/local (Intel).
public enum Tool {
    public static let homebrew: String = {
        if let prefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"], !prefix.isEmpty { return prefix }
        return ["/opt/homebrew", "/usr/local"].first { FileManager.default.isExecutableFile(atPath: $0 + "/bin/brew") }
            ?? "/opt/homebrew"
    }()
    public static let brew = homebrew + "/bin/brew"
    public static let yabai = homebrew + "/bin/yabai"
    public static let skhd = homebrew + "/bin/skhd"
    public static let borders = homebrew + "/bin/borders"
    public static let sketchybar = homebrew + "/bin/sketchybar"
    public static let bat = homebrew + "/bin/bat"
    public static let jq = homebrew + "/bin/jq"
    public static let tmux = homebrew + "/bin/tmux"
    /// Homebrew's git when it's there, else the one macOS ships.
    public static let git = FileManager.default.isExecutableFile(atPath: homebrew + "/bin/git") ? homebrew + "/bin/git" : "/usr/bin/git"
    public static let launchctl = "/bin/launchctl"
    public static let open = "/usr/bin/open"
    public static let osascript = "/usr/bin/osascript"
    public static let killall = "/usr/bin/killall"
    public static let pluginkit = "/usr/bin/pluginkit"
    public static let systemextensionsctl = "/usr/bin/systemextensionsctl"
    public static let hdiutil = "/usr/bin/hdiutil"
    public static let pkgutil = "/usr/sbin/pkgutil"
    public static let pmset = "/usr/bin/pmset"
    public static let shortcuts = "/usr/bin/shortcuts"
}

/// Background helpers Orbit switches on and off, with the names launchd knows them by.
public enum Helper: String, Sendable, Codable, CaseIterable {
    case yabai, skhd, borders, sketchybar, sorter

    public var label: String {
        switch self {
        case .yabai: "com.asmvik.yabai"
        case .skhd: "com.koekeishiya.skhd"
        case .borders: "sh.brew.borders"
        case .sketchybar: "sh.brew.sketchybar"
        case .sorter: "com.himanshu.sort-downloads"
        }
    }

    /// What the helper does, for messages.
    public var title: String {
        switch self {
        case .yabai: "window tiling"
        case .skhd: "the window shortcuts"
        case .borders: "the window glow"
        case .sketchybar: "the menu bar"
        case .sorter: "the Downloads sorter"
        }
    }

    /// Older yabai versions used this label; a leftover plist under it fights the current one.
    public static let staleYabaiLabel = "com.koekeishiya.yabai"

    public var brewFormula: String? {
        switch self {
        case .borders: "felixkratz/formulae/borders"
        case .sketchybar: "felixkratz/formulae/sketchybar"
        default: nil
        }
    }

    public var binary: String? {
        switch self {
        case .yabai: Tool.yabai
        case .skhd: Tool.skhd
        case .borders: Tool.borders
        case .sketchybar: Tool.sketchybar
        case .sorter: nil
        }
    }

    /// Where the helper writes its error messages (the sorter keeps its own log).
    public func errorLog(user: String) -> String? {
        switch self {
        case .yabai, .skhd: "/tmp/\(rawValue)_\(user).err.log"
        case .borders, .sketchybar: "\(Tool.homebrew)/var/log/\(rawValue)/\(rawValue).err.log"
        case .sorter: nil
        }
    }

    /// The process name to look for while it runs.
    public var processName: String? {
        switch self {
        case .sorter: nil
        default: rawValue
        }
    }
}

public enum ServiceVerb: String, Sendable {
    case start, stop, restart
}

/// Builders for every command Orbit runs, each tagged with its side effect and a plain-English summary.
public enum Commands {
    // MARK: launchd

    public static func launchctlPrint(_ label: String, uid: UInt32) -> Command {
        Command(Tool.launchctl, ["print", "gui/\(uid)/\(label)"], effect: .readOnly,
                summary: "Check whether \(label) is loaded", timeout: 5, okStatuses: [0, 113])
    }

    public static func launchctlPrintDisabled(uid: UInt32) -> Command {
        Command(Tool.launchctl, ["print-disabled", "gui/\(uid)"], effect: .readOnly,
                summary: "List switched-off background helpers", timeout: 5)
    }

    public static func launchctlEnable(_ label: String, uid: UInt32) -> Command {
        Command(Tool.launchctl, ["enable", "gui/\(uid)/\(label)"], effect: .service,
                summary: "Allow \(label) to start at login", timeout: 5)
    }

    public static func launchctlDisable(_ label: String, uid: UInt32) -> Command {
        Command(Tool.launchctl, ["disable", "gui/\(uid)/\(label)"], effect: .service,
                summary: "Keep \(label) from starting at login", timeout: 5)
    }

    /// Loads a launch agent. Status 5 means it was already loaded.
    public static func launchctlBootstrap(_ plist: URL, uid: UInt32) -> Command {
        Command(Tool.launchctl, ["bootstrap", "gui/\(uid)", plist.path(percentEncoded: false)], effect: .service,
                summary: "Start the background helper \(plist.deletingPathExtension().lastPathComponent)",
                timeout: 10, okStatuses: [0, 5, 37])
    }

    /// Starts a loaded helper that has stopped.
    public static func launchctlKickstart(_ label: String, uid: UInt32) -> Command {
        Command(Tool.launchctl, ["kickstart", "gui/\(uid)/\(label)"], effect: .service,
                summary: "Start \(label) again", timeout: 10)
    }

    /// Unloads a launch agent. Status 3 and 113 mean it wasn't loaded.
    public static func launchctlBootout(_ label: String, uid: UInt32) -> Command {
        Command(Tool.launchctl, ["bootout", "gui/\(uid)/\(label)"], effect: .service,
                summary: "Stop the background helper \(label)", timeout: 10, okStatuses: [0, 3, 36, 113])
    }

    // MARK: Tiling

    public static func yabaiService(_ verb: ServiceVerb) -> Command {
        Command(Tool.yabai, ["--\(verb.rawValue)-service"], effect: .service,
                summary: "\(verb.rawValue.capitalized) window tiling", timeout: 15, okStatuses: [0, 1])
    }

    public static func skhdService(_ verb: ServiceVerb) -> Command {
        Command(Tool.skhd, ["--\(verb.rawValue)-service"], effect: .service,
                summary: "\(verb.rawValue.capitalized) the window shortcuts", timeout: 15, okStatuses: [0, 1])
    }

    public static func yabaiQueryDisplays() -> Command {
        Command(Tool.yabai, ["-m", "query", "--displays"], effect: .readOnly,
                summary: "Ask window tiling which displays it sees", timeout: 3)
    }

    /// Adds, removes or reapplies a yabai rule (`yabai -m rule …`).
    public static func yabaiRule(_ arguments: [String], summary: String) -> Command {
        Command(Tool.yabai, ["-m", "rule"] + arguments, effect: .service, summary: summary, timeout: 5, okStatuses: [0, 1])
    }

    public static func yabaiConfig(_ key: String, _ value: String) -> Command {
        Command(Tool.yabai, ["-m", "config", key, value], effect: .service,
                summary: "Set window tiling's \(key) to \(value)", timeout: 3)
    }

    public static func yabaiLayout(_ layout: TilingLayout) -> Command {
        Command(Tool.yabai, ["-m", "config", "layout", layout.rawValue], effect: .service,
                summary: "Arrange windows as \(layout.title.lowercased())", timeout: 3)
    }

    // MARK: Homebrew

    /// A project's branch, how far it is from its upstream, and what changed.
    public static func gitStatus(_ folder: String) -> Command {
        Command(Tool.git, ["-C", folder, "status", "--porcelain=v2", "--branch"], effect: .readOnly,
                summary: "Look at a project's git status", timeout: 10)
    }

    public static func gitInit(_ folder: String) -> Command {
        Command(Tool.git, ["-C", folder, "init"], effect: .userFiles, summary: "Start using git in \(URL(fileURLWithPath: folder).lastPathComponent)",
                timeout: 15)
    }

    /// Your own processes listening for connections (without root, lsof only sees yours).
    public static func listeningPorts() -> Command {
        Command("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"], effect: .readOnly, summary: "List what's listening",
                timeout: 10, okStatuses: [0, 1])
    }

    public static func brewServicesInfo() -> Command {
        Command(Tool.brew, ["services", "info", "--all", "--json"], effect: .readOnly,
                summary: "List Homebrew background helpers", timeout: 20)
    }

    public static func brewService(_ verb: ServiceVerb, _ formula: String, name: String) -> Command {
        Command(Tool.brew, ["services", verb.rawValue, formula], effect: .service,
                summary: "\(verb.rawValue.capitalized) \(name)", timeout: 40)
    }

    public static func brewInstallCask(_ cask: String, name: String) -> Command {
        Command(Tool.brew, ["install", "--cask", cask], effect: .appControl,
                summary: "Download and install \(name)", timeout: 900)
    }

    public static func brewFetchCask(_ cask: String, name: String) -> Command {
        Command(Tool.brew, ["fetch", "--cask", cask], effect: .appControl,
                summary: "Download \(name)", timeout: 900)
    }

    public static func brewCachePath(cask: String) -> Command {
        Command(Tool.brew, ["--cache", "--cask", cask], effect: .readOnly,
                summary: "Find the downloaded \(cask) installer", timeout: 20)
    }

    // MARK: Borders and menu bar

    public static func bordersApply(_ options: [String]) -> Command {
        Command(Tool.borders, options, effect: .service, summary: "Update the window glow", timeout: 5)
    }

    public static func sketchybarReload() -> Command {
        Command(Tool.sketchybar, ["--reload"], effect: .service, summary: "Reload the menu bar", timeout: 10)
    }

    public static func sketchybarQueryBar() -> Command {
        Command(Tool.sketchybar, ["--query", "bar"], effect: .readOnly, summary: "Check the menu bar", timeout: 3)
    }

    // MARK: Apps and settings

    public static func openApp(at path: String, name: String, background: Bool = false) -> Command {
        Command(Tool.open, (background ? ["-g", "-j"] : []) + [path], effect: .appControl,
                summary: "Open \(name)", timeout: 15, captureOutput: false)
    }

    public static func openURL(_ url: String, summary: String) -> Command {
        Command(Tool.open, [url], effect: .appControl, summary: summary, timeout: 10, captureOutput: false)
    }

    public static func killall(_ process: String, summary: String) -> Command {
        Command(Tool.killall, [process], effect: .systemSetting, summary: summary, timeout: 5, okStatuses: [0, 1])
    }

    public static func appleScript(_ source: String, effect: SideEffect, summary: String) -> Command {
        Command(Tool.osascript, ["-e", source], effect: effect, summary: summary, timeout: 30)
    }

    public static func pluginkitMatch(_ identifier: String) -> Command {
        Command(Tool.pluginkit, ["-m", "-i", identifier], effect: .readOnly,
                summary: "Check the Quick Look extension", timeout: 5)
    }

    public static func systemExtensions() -> Command {
        Command(Tool.systemextensionsctl, ["list"], effect: .readOnly,
                summary: "List system extensions", timeout: 10)
    }

    public static func gitConfigGet(_ key: String) -> Command {
        Command(Tool.git, ["config", "--global", "--get", key], effect: .readOnly,
                summary: "Read git's \(key) setting", timeout: 5, okStatuses: [0, 1])
    }

    public static func gitConfigSet(_ key: String, _ value: String) -> Command {
        Command(Tool.git, ["config", "--global", key, value], effect: .userFiles,
                summary: "Set git's \(key) to \(value)", timeout: 5)
    }

    public static func gitConfigUnset(_ key: String) -> Command {
        Command(Tool.git, ["config", "--global", "--unset", key], effect: .userFiles,
                summary: "Remove git's \(key) setting", timeout: 5, okStatuses: [0, 5])
    }

    public static func batCacheBuild() -> Command {
        Command(Tool.bat, ["cache", "--build"], effect: .userFiles,
                summary: "Refresh the terminal colour themes", timeout: 60)
    }
}
