import OrbitCore
import SwiftUI

/// Something you can find with ⌘F: a page, a feature or a single setting.
struct SearchEntry: Identifiable, Equatable {
    let title: String
    let detail: String
    let symbol: String
    let page: Page
    let keywords: String
    var opensSetup = false

    var id: String { "\(page.rawValue)|\(title)" }
}

enum SearchIndex {
    static func entries(modes: [ModeDefinition]) -> [SearchEntry] {
        Page.allCases.map { SearchEntry(title: $0.title, detail: $0.blurb, symbol: $0.symbol, page: $0, keywords: "") }
            + settings
            + modes.map {
                SearchEntry(title: "\($0.name) mode", detail: $0.blurb, symbol: $0.symbol, page: .modes,
                            keywords: "mode " + ($0.openApps + $0.quitApps).joined(separator: " "))
            }
    }

    /// Entries whose words contain every word typed, best title matches first.
    static func results(for query: String, in entries: [SearchEntry]) -> [SearchEntry] {
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let phrase = words.joined(separator: " ")
        func rank(_ entry: SearchEntry) -> Int {
            let title = fold(entry.title)
            return title.hasPrefix(phrase) ? 0 : title.contains(phrase) ? 1 : 2
        }
        return entries
            .filter { entry in
                // An entry's own words only: matching its page's name would list every setting on that page.
                let text = fold("\(entry.title) \(entry.detail) \(entry.keywords)")
                return words.allSatisfy(text.contains)
            }
            .sorted { (rank($0), $0.title) < (rank($1), $1.title) }
    }

    static let settings: [SearchEntry] = [
        SearchEntry(title: "Arrange windows automatically", detail: "Turn window tiling on or off", symbol: "rectangle.split.3x1.fill",
                    page: .windows, keywords: "tiling tile yabai split layout organise organize"),
        SearchEntry(title: "Window style", detail: "Tiles, one at a time, or free", symbol: "square.grid.2x2",
                    page: .windows, keywords: "stack float bsp layout"),
        SearchEntry(title: "Space between windows", detail: "Gaps between windows and around the edges", symbol: "arrow.left.and.right",
                    page: .windows, keywords: "gap padding margin spacing"),
        SearchEntry(title: "Glow around the active window", detail: "Turn the window glow on or off", symbol: "sparkles.rectangle.stack.fill",
                    page: .windows, keywords: "border outline highlight jankyborders focus"),
        SearchEntry(title: "Glow colour and thickness", detail: "Match the theme or pick your own colour", symbol: "paintbrush.pointed.fill",
                    page: .windows, keywords: "color colour width size soft halo"),
        SearchEntry(title: "Floating menu bar", detail: "Turn the new menu bar on or off", symbol: "menubar.rectangle",
                    page: .menuBar, keywords: "sketchybar top bar status bar"),
        SearchEntry(title: "What the bar shows", detail: "Desktops, app, Spotify, processor, memory, volume, network, clock",
                    symbol: "checklist", page: .menuBar,
                    keywords: "spotify music song cpu memory ram volume wifi network ip clock time spaces desktops"),
        SearchEntry(title: "Caps Lock superpowers", detail: "Escape when tapped, Hyper when held", symbol: "capslock.fill",
                    page: .keyboard, keywords: "caps lock escape esc hyper karabiner"),
        SearchEntry(title: "Open apps with Caps Lock", detail: "Pick the app for each letter", symbol: "command",
                    page: .keyboard, keywords: "shortcut hotkey launch app letter hyper"),
        SearchEntry(title: "Window shortcuts", detail: "Every keyboard shortcut for windows", symbol: "keyboard",
                    page: .keyboard, keywords: "skhd hotkeys keys cheat sheet option alt"),
        SearchEntry(title: "Themes", detail: "Tokyo Night, Catppuccin, Dracula, Nord, Rosé Pine, Sunset", symbol: "paintpalette.fill",
                    page: .style, keywords: "theme colours colors look tokyo night catppuccin dracula nord rose pine sunset dark"),
        SearchEntry(title: "Wallpaper", detail: "A wallpaper drawn in your theme's colours", symbol: "photo.fill",
                    page: .style, keywords: "background desktop picture image"),
        SearchEntry(title: "Terminal colours", detail: "bat, git diffs, btop, lazygit, fastfetch and tmux", symbol: "terminal.fill",
                    page: .style, keywords: "terminal bat delta git btop lazygit fastfetch tmux colours colors"),
        SearchEntry(title: "Auto-sort Downloads", detail: "Downloads go into folders by type every hour", symbol: "arrow.down.doc.fill",
                    page: .files, keywords: "downloads sort organise organize folders tidy"),
        SearchEntry(title: "Tidy the Desktop", detail: "Move loose files into folders in Documents", symbol: "desktopcomputer",
                    page: .files, keywords: "desktop clean tidy organise organize clutter mess"),
        SearchEntry(title: "Where your things live", detail: "Projects, Documents, Downloads and backups", symbol: "folder.fill",
                    page: .files, keywords: "projects developer documents folders"),
        SearchEntry(title: "Keep the Mac awake", detail: "Part of the Work, Focus and Present modes", symbol: "sun.max.fill",
                    page: .modes, keywords: "awake sleep caffeine amphetamine screen on"),
        SearchEntry(title: "New mode", detail: "Make a mode of your own", symbol: "plus.circle.fill",
                    page: .modes, keywords: "custom create add mode edit change"),
        SearchEntry(title: "Processor", detail: "Live CPU use, per core", symbol: "cpu",
                    page: .monitor, keywords: "cpu processor load busy slow"),
        SearchEntry(title: "Memory", detail: "How much memory is in use", symbol: "memorychip",
                    page: .monitor, keywords: "ram memory pressure"),
        SearchEntry(title: "Network speed", detail: "Live download and upload", symbol: "network",
                    page: .monitor, keywords: "internet wifi speed download upload bandwidth"),
        SearchEntry(title: "Storage", detail: "Free space on your Mac", symbol: "internaldrive",
                    page: .monitor, keywords: "disk space free storage full"),
        SearchEntry(title: "Free up space", detail: "Clear caches and old downloads safely", symbol: "sparkles",
                    page: .cleanup, keywords: "clean junk cache caches trash derived data xcode npm space storage full"),
        SearchEntry(title: "Dock apps", detail: "Choose and order the apps in the Dock", symbol: "dock.rectangle",
                    page: .dockFinder, keywords: "dock icons apps add remove"),
        SearchEntry(title: "Hide the Dock", detail: "Auto-hide, and how fast it appears", symbol: "rectangle.bottomhalf.inset.filled",
                    page: .dockFinder, keywords: "autohide hide dock delay instant"),
        SearchEntry(title: "Dock size and magnification", detail: "Icon size and zoom under the pointer", symbol: "plus.magnifyingglass",
                    page: .dockFinder, keywords: "dock size icons magnify zoom bigger smaller"),
        SearchEntry(title: "Finder options", detail: "Path bar, status bar, list view, folders first", symbol: "folder",
                    page: .dockFinder, keywords: "finder path status list view folders first search"),
        SearchEntry(title: "Show hidden files", detail: "Files whose names start with a dot", symbol: "eye",
                    page: .dockFinder, keywords: "hidden dotfiles show invisible"),
        SearchEntry(title: "File extensions", detail: "Always show .pdf, .png and the rest", symbol: "doc.text",
                    page: .dockFinder, keywords: "extensions file types names"),
        SearchEntry(title: "Screenshots", detail: "Where they're saved, and window shadows", symbol: "camera.viewfinder",
                    page: .dockFinder, keywords: "screenshot screen capture save folder shadow"),
        SearchEntry(title: "Key repeat speed", detail: "How fast a held key repeats", symbol: "keyboard",
                    page: .dockFinder, keywords: "typing keyboard repeat speed delay"),
        SearchEntry(title: "Raycast", detail: "Find and open anything from the keyboard", symbol: "magnifyingglass",
                    page: .apps, keywords: "launcher spotlight search"),
        SearchEntry(title: "AltTab", detail: "⌘Tab with live window previews", symbol: "rectangle.on.rectangle",
                    page: .apps, keywords: "cmd command tab switcher previews windows"),
        SearchEntry(title: "Ice", detail: "Tuck menu bar icons out of the way", symbol: "menubar.dock.rectangle",
                    page: .apps, keywords: "menu bar icons hide bartender"),
        SearchEntry(title: "Syntax Highlight", detail: "Coloured code previews in Finder", symbol: "chevron.left.forwardslash.chevron.right",
                    page: .apps, keywords: "quick look preview code space bar"),
        SearchEntry(title: "Undo a change", detail: "Every change Orbit made, each with Undo", symbol: "arrow.uturn.backward.circle",
                    page: .health, keywords: "undo revert history changes recent"),
        SearchEntry(title: "Back to before Orbit", detail: "Put everything back the way it was", symbol: "clock.arrow.circlepath",
                    page: .health, keywords: "restore reset original before uninstall"),
        SearchEntry(title: "Make the Mac instant", detail: "Take out the animations you wait for", symbol: "bolt.fill",
                    page: .speed, keywords: "speed fast faster quick snappy animation instant slow performance"),
        SearchEntry(title: "What slows the Mac down", detail: "The Speed check, with a fix for each", symbol: "gauge.with.dots.needle.67percent",
                    page: .speed, keywords: "slow speed check heavy apps memory leftovers siri"),
        SearchEntry(title: "Apps using the most", detail: "Memory and processor by app, with Quit", symbol: "memorychip",
                    page: .speed, keywords: "memory cpu processor heavy quit apps ram"),
        SearchEntry(title: "Save or import your setup", detail: "A copy of Orbit's settings and config files", symbol: "square.and.arrow.down",
                    page: .health, keywords: "profile export import backup dotfiles copy another mac migrate"),
        SearchEntry(title: "Window arrangements", detail: "Save how windows sit and put them back", symbol: "rectangle.3.group",
                    page: .windows, keywords: "layout arrange save restore desktop windows"),
        SearchEntry(title: "Backups", detail: "Copies saved before each change", symbol: "externaldrive.fill",
                    page: .health, keywords: "backup copies saved"),
        SearchEntry(title: "Open Orbit at login", detail: "Start Orbit when you log in", symbol: "power",
                    page: .health, keywords: "login startup launch at login start"),
        SearchEntry(title: "Checkup", detail: "Check everything is working, and fix what isn't", symbol: "stethoscope",
                    page: .health, keywords: "deep check diagnose troubleshoot problems fix permissions broken not working"),
        SearchEntry(title: "Guided setup", detail: "Run the step-by-step setup again", symbol: "wand.and.stars",
                    page: .home, keywords: "wizard onboarding setup start begin", opensSetup: true)
    ]
}

struct SearchResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        let results = SearchIndex.results(for: query, in: SearchIndex.entries(modes: model.settings.modes))
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                IconTile(symbol: "magnifyingglass", hue: .blue, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(results.isEmpty ? "Nothing matches “\(query)”." : "\(results.count) result\(results.count == 1 ? "" : "s") for “\(query)”. Press Return for the first.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            if results.isEmpty {
                GlassPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Try one of these:").font(.headline)
                        HStack(spacing: 8) {
                            ForEach(["dock", "theme", "caps lock", "wallpaper", "undo", "space"], id: \.self) { word in
                                Button(word) { model.searchText = word }.buttonStyle(.glass)
                            }
                        }
                    }
                }
            }
            VStack(spacing: 10) {
                ForEach(results) { entry in
                    Button { model.open(entry) } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: entry.symbol, hue: entry.page.hue, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.headline)
                                Text(entry.detail).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.page.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary.opacity(0.5), in: Capsule())
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .contentShape(.rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                    .accessibilityLabel("\(entry.title), on the \(entry.page.title) page")
                }
            }
        }
    }
}

extension AppModel {
    /// Goes to a search result and clears the search.
    func open(_ entry: SearchEntry) {
        page = entry.page
        searchText = ""
        if entry.opensSetup { showSetup = true }
    }
}
