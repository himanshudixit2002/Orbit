import Foundation

/// Every file and folder Orbit reads or manages. Rooted at a home folder so tests can use a temporary one.
public struct Paths: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func at(_ relative: String) -> URL { home.appending(path: relative) }

    /// `~/…` form of a path inside the home folder, for messages.
    public func tilde(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        var homePath = home.path(percentEncoded: false)
        if homePath.hasSuffix("/") { homePath.removeLast() }
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    // Window tiling and shortcuts
    public var yabairc: URL { at(".config/yabai/yabairc") }
    public var skhdrc: URL { at(".config/skhd/skhdrc") }
    public var cheatsheet: URL { at(".config/skhd/CHEATSHEET.md") }

    // Glow borders and menu bar
    public var bordersrc: URL { at(".config/borders/bordersrc") }
    public var sketchybarDir: URL { at(".config/sketchybar") }
    public var sketchybarrc: URL { at(".config/sketchybar/sketchybarrc") }
    public var sketchybarColors: URL { at(".config/sketchybar/colors.sh") }
    public var sketchybarSettings: URL { at(".config/sketchybar/settings.sh") }

    // Keyboard
    public var karabinerJSON: URL { at(".config/karabiner/karabiner.json") }

    // Downloads sorter
    public var sorterScript: URL { at(".local/bin/sort-downloads") }
    public var sorterApp: URL { at("Library/Application Support/DownloadsSorter/Downloads Sorter.app") }
    public var sorterLog: URL { at("Library/Logs/sort-downloads.log") }
    /// Touched by the sorter each time it gets into Downloads, whether or not it had anything to sort.
    public var sorterChecked: URL { at("Library/Logs/sort-downloads.checked") }

    // Background helpers
    public var launchAgents: URL { at("Library/LaunchAgents") }
    public func launchAgent(_ label: String) -> URL { launchAgents.appending(path: "\(label).plist") }

    // Terminal look
    public var batConfig: URL { at(".config/bat/config") }
    public var batTheme: URL { at(".config/bat/themes/orbit.tmTheme") }
    public var btopConf: URL { at(".config/btop/btop.conf") }
    public var btopTheme: URL { at(".config/btop/themes/orbit.theme") }
    public var lazygitConfig: URL { at("Library/Application Support/lazygit/config.yml") }
    public var fastfetchConfig: URL { at(".config/fastfetch/config.jsonc") }
    public var tmuxConf: URL { at(".tmux.conf") }
    public var cheatSheet: URL { at(".config/skhd/CHEATSHEET.md") }
    public var tmuxTheme: URL { at(".config/tmux/orbit-theme.conf") }

    // Folders
    public var desktop: URL { at("Desktop") }
    public var documents: URL { at("Documents") }
    public var downloads: URL { at("Downloads") }
    public var developer: URL { at("Developer") }
    public var pictures: URL { at("Pictures") }
    public var desktopMoveLog: URL { at("Developer/.desktop-move-log.tsv") }
    public var macBackups: URL { at("Documents/Mac Backups") }
    public var wallpapers: URL { at("Pictures/Wallpapers/Orbit") }
    public var trash: URL { at(".Trash") }

    // Orbit's own state
    public var support: URL { at("Library/Application Support/Orbit") }
    public var settingsFile: URL { support.appending(path: "settings.json") }
    public var journalFile: URL { support.appending(path: "journal.json") }
    public var baselineFile: URL { support.appending(path: "baseline.json") }
    public var registryFile: URL { support.appending(path: "managed-files.json") }
    public var backups: URL { support.appending(path: "Backups") }
    public var practiceRoot: URL { support.appending(path: "Practice") }
}
