import AppKit
import OrbitCore
import OrbitPlatform
import SwiftUI

/// The Dock and Finder settings Orbit shows, read fresh from macOS.
nonisolated struct DockFinderValues: Equatable, Sendable {
    var autohide = false
    var instantHide = false
    var showRecents = true
    var magnification = false
    var tileSize = 48.0
    var pathBar = false
    var statusBar = false
    var listView = false
    var foldersFirst = false
    var allExtensions = false
    var hiddenFiles = false
    var searchHere = false
    var screenshotShadow = true
    var screenshotFolder = ""
    var keyRepeat = 2.0
    var initialRepeat = 15.0

    static func read(_ read: (_ domain: String, _ key: String) -> PrefValue?) -> DockFinderValues {
        let dock = WatchedPreferences.dockDomain, finder = WatchedPreferences.finderDomain
        let shots = WatchedPreferences.screenshotDomain, global = WatchedPreferences.globalDomain
        func bool(_ d: String, _ k: String, _ fallback: Bool) -> Bool { read(d, k)?.boolValue ?? fallback }
        var v = DockFinderValues()
        v.autohide = bool(dock, "autohide", false)
        v.instantHide = (read(dock, "autohide-delay")?.doubleValue ?? 0.5) < 0.05
        v.showRecents = bool(dock, "show-recents", true)
        v.magnification = bool(dock, "magnification", false)
        v.tileSize = read(dock, "tilesize")?.doubleValue ?? 48
        v.pathBar = bool(finder, "ShowPathbar", false)
        v.statusBar = bool(finder, "ShowStatusBar", false)
        v.listView = read(finder, "FXPreferredViewStyle")?.stringValue == "Nlsv"
        v.foldersFirst = bool(finder, "_FXSortFoldersFirst", false)
        v.allExtensions = bool(global, "AppleShowAllExtensions", false)
        v.hiddenFiles = bool(finder, "AppleShowAllFiles", false)
        v.searchHere = read(finder, "FXDefaultSearchScope")?.stringValue == "SCcf"
        v.screenshotShadow = !bool(shots, "disable-shadow", false)
        v.screenshotFolder = read(shots, "location")?.stringValue ?? "~/Desktop"
        v.keyRepeat = read(global, "KeyRepeat")?.doubleValue ?? 6
        v.initialRepeat = read(global, "InitialKeyRepeat")?.doubleValue ?? 25
        return v
    }
}

/// The Dock's apps and the Dock and Finder settings, read together off the main thread (every read
/// asks macOS's preferences service).
nonisolated struct DockFinderReading: Equatable, Sendable {
    var tiles: [DockTile]
    var values: DockFinderValues

    static func read() -> DockFinderReading {
        Preferences.reading { read in
            DockFinderReading(tiles: DockModel.tiles(read(WatchedPreferences.dockDomain, "persistent-apps")),
                              values: DockFinderValues.read(read))
        }
    }
}

/// The tidy Dock from the original setup: everyday apps plus Developer and Downloads stacks.
enum DockPreset {
    static let apps = ["/Applications/Safari.app", "/Applications/Google Chrome.app", "/Applications/Warp.app",
                       "/Applications/Antigravity IDE.app", "/Applications/Antigravity.app", "/Applications/Claude.app",
                       "/Applications/ChatGPT.app", "/Applications/Postman.app", "/System/Applications/Notes.app",
                       "/Applications/WhatsApp.app", "/Applications/Spotify.app"]

    static func tiles() -> [DockTile] {
        apps.filter { FileManager.default.fileExists(atPath: $0) }.map {
            DockTile(path: $0, label: URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent)
        }
    }

    static func changes(home: URL) -> [Actions.PreferenceChange] {
        let dock = WatchedPreferences.dockDomain
        func folder(_ path: String, arrangement: Int, displayAs: Int, showAs: Int) -> PrefValue {
            .dict([
                "tile-data": .dict([
                    "file-data": .dict(["_CFURLString": .string(URL(fileURLWithPath: path, isDirectory: true).absoluteString),
                                        "_CFURLStringType": .int(15)]),
                    "arrangement": .int(arrangement), "displayas": .int(displayAs), "showas": .int(showAs), "file-type": .int(2)
                ]),
                "tile-type": .string("directory-tile")
            ])
        }
        return [
            .init(dock, "persistent-apps", DockModel.persistentApps(tiles())),
            .init(dock, "persistent-others", .array([
                folder(home.appending(path: "Developer").path(percentEncoded: false), arrangement: 1, displayAs: 1, showAs: 3),
                folder(home.appending(path: "Downloads").path(percentEncoded: false), arrangement: 2, displayAs: 0, showAs: 2)
            ])),
            .init(dock, "autohide", .bool(true)), .init(dock, "autohide-delay", .double(0)),
            .init(dock, "autohide-time-modifier", .double(0.35)), .init(dock, "show-recents", .bool(false)),
            .init(dock, "minimize-to-application", .bool(true)), .init(dock, "mineffect", .string("scale")),
            .init(dock, "mru-spaces", .bool(false)), .init(dock, "expose-group-apps", .bool(true))
        ]
    }

    static let finder: [Actions.PreferenceChange] = {
        let f = WatchedPreferences.finderDomain
        return [.init(f, "ShowPathbar", .bool(true)), .init(f, "ShowStatusBar", .bool(true)),
                .init(f, "FXPreferredViewStyle", .string("Nlsv")), .init(f, "_FXSortFoldersFirst", .bool(true)),
                .init(f, "FXDefaultSearchScope", .string("SCcf")), .init(f, "FXEnableExtensionChangeWarning", .bool(false))]
    }()
}

struct DockFinderPage: View {
    @Environment(AppModel.self) private var model
    @State private var tiles: [DockTile] = []
    @State private var dockEdited = false
    @State private var values = DockFinderValues()
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(page: .dockFinder)
            GlassPanel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        IconTile(symbol: "dock.rectangle", hue: .blue, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apps in your Dock").font(.headline)
                            Text("Reorder with the arrows, remove what you don't use, then press Apply.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            ForEach(model.appCatalog.apps, id: \.path) { app in
                                Button(app.name) {
                                    tiles.append(DockTile(path: app.path, label: app.name))
                                    dockEdited = true
                                }
                            }
                        } label: { Label("Add app", systemImage: "plus") }
                            .menuStyle(.button)
                            .buttonStyle(.glass)
                            .fixedSize()
                        Button("Tidy preset") {
                            tiles = DockPreset.tiles()
                            dockEdited = true
                        }
                        .buttonStyle(.glass)
                        .help("The 11 everyday apps from your original setup")
                    }
                    VStack(spacing: 4) {
                        ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                            HStack(spacing: 10) {
                                if tile.isApp {
                                    Image(nsImage: Icons.of(tile.path)).resizable().frame(width: 26, height: 26)
                                } else {
                                    Image(systemName: "rectangle.dashed").frame(width: 26, height: 26).foregroundStyle(.secondary)
                                }
                                Text(tile.label).foregroundStyle(tile.isApp ? .primary : .secondary)
                                Spacer()
                                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                                    .buttonStyle(.borderless).disabled(index == 0).accessibilityLabel("Move \(tile.label) up")
                                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                                    .buttonStyle(.borderless).disabled(index == tiles.count - 1).accessibilityLabel("Move \(tile.label) down")
                                Button {
                                    tiles.remove(at: index)
                                    dockEdited = true
                                } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                                    .buttonStyle(.borderless).accessibilityLabel("Remove \(tile.label)")
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(.background.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    HStack {
                        Text("\(tiles.filter(\.isApp).count) apps").foregroundStyle(.secondary)
                        Spacer()
                        Button("Discard changes") {
                            dockEdited = false
                            reload()
                        }
                        .disabled(!dockEdited)
                        Button("Apply to Dock") {
                            model.setPreferences("Updated the Dock apps",
                                                 [.init(WatchedPreferences.dockDomain, "persistent-apps", DockModel.persistentApps(tiles))])
                            dockEdited = false
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!dockEdited)
                    }
                }
            }

            SectionTitle(text: "Dock")
            GlassPanel {
                VStack(spacing: 10) {
                    toggle("Hide the Dock until you point at it", $values.autohide, WatchedPreferences.dockDomain, "autohide")
                    SettingRow(title: "Show it instantly", detail: "No wait before it slides in") {
                        Toggle("Instant", isOn: Binding(get: { values.instantHide }, set: { on in
                            values.instantHide = on
                            model.setPreferences("Changed how fast the Dock appears",
                                                 [.init(WatchedPreferences.dockDomain, "autohide-delay", on ? .double(0) : nil)])
                        })).toggleStyle(.switch).labelsHidden()
                    }
                    toggle("Show recent apps", $values.showRecents, WatchedPreferences.dockDomain, "show-recents")
                    toggle("Magnify icons under the pointer", $values.magnification, WatchedPreferences.dockDomain, "magnification")
                    SettingRow(title: "Icon size", detail: "\(Int(values.tileSize)) points") {
                        Slider(value: $values.tileSize, in: 24...96, step: 4) { editing in
                            if !editing {
                                model.setPreferences("Changed the Dock size", [.init(WatchedPreferences.dockDomain, "tilesize", .int(Int(values.tileSize)))])
                            }
                        }
                        .frame(width: 260)
                    }
                }
            }

            SectionTitle(text: "Finder")
            GlassPanel {
                VStack(spacing: 10) {
                    toggle("Show the folder path at the bottom", $values.pathBar, WatchedPreferences.finderDomain, "ShowPathbar")
                    toggle("Show the status bar (items and free space)", $values.statusBar, WatchedPreferences.finderDomain, "ShowStatusBar")
                    SettingRow(title: "Open folders as a list") {
                        Toggle("List", isOn: Binding(get: { values.listView }, set: { on in
                            values.listView = on
                            model.setPreferences("Changed the Finder view", [.init(WatchedPreferences.finderDomain, "FXPreferredViewStyle",
                                                                                   .string(on ? "Nlsv" : "icnv"))])
                        })).toggleStyle(.switch).labelsHidden()
                    }
                    toggle("Keep folders on top", $values.foldersFirst, WatchedPreferences.finderDomain, "_FXSortFoldersFirst")
                    toggle("Show every file extension", $values.allExtensions, WatchedPreferences.globalDomain, "AppleShowAllExtensions")
                    toggle("Show hidden files", $values.hiddenFiles, WatchedPreferences.finderDomain, "AppleShowAllFiles")
                    SettingRow(title: "Search the folder you're in", detail: "Instead of the whole Mac") {
                        Toggle("Search here", isOn: Binding(get: { values.searchHere }, set: { on in
                            values.searchHere = on
                            model.setPreferences("Changed where Finder searches", [.init(WatchedPreferences.finderDomain, "FXDefaultSearchScope",
                                                                                         on ? .string("SCcf") : nil)])
                        })).toggleStyle(.switch).labelsHidden()
                    }
                    Text("Finder restarts briefly to show changes; open windows come back.").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SectionTitle(text: "Screenshots and typing")
            GlassPanel {
                VStack(spacing: 10) {
                    SettingRow(title: "Save screenshots to", detail: values.screenshotFolder) {
                        Button("Choose…") { chooseScreenshotFolder() }.buttonStyle(.glass)
                    }
                    SettingRow(title: "Shadow around window screenshots") {
                        Toggle("Shadow", isOn: Binding(get: { values.screenshotShadow }, set: { on in
                            values.screenshotShadow = on
                            model.setPreferences("Changed screenshot shadows", [.init(WatchedPreferences.screenshotDomain, "disable-shadow", on ? nil : .bool(true))])
                        })).toggleStyle(.switch).labelsHidden()
                    }
                    SettingRow(title: "Key repeat speed", detail: "Faster feels snappier when you hold a key. Applies after you log out and back in.") {
                        Slider(value: Binding(get: { 16 - values.keyRepeat }, set: { values.keyRepeat = 16 - $0 }), in: 1...15, step: 1) { editing in
                            if !editing {
                                model.setPreferences("Changed key repeat", [.init(WatchedPreferences.globalDomain, "KeyRepeat", .int(Int(values.keyRepeat)))])
                            }
                        }
                        .frame(width: 260)
                    }
                }
            }

            Button(role: .destructive) { confirmReset = true } label: {
                Label("Put the Dock and Finder back to Apple's defaults", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.glass)
            .confirmationDialog("Reset the Dock and Finder?", isPresented: $confirmReset) {
                Button("Reset to Apple's defaults", role: .destructive) { model.resetDockAndFinder() }
            } message: {
                Text("Your Dock goes back to the apps it came with. You can undo this on the Health page.")
            }
        }
        .onAppear {
            // What was read last time shows straight away; a fresh read follows.
            if let last = model.dockFinder { show(last) }
            reload()
            model.appCatalog.refresh()
        }
        .onChange(of: model.journal.count) { if !dockEdited { reload() } }
    }

    func reload() {
        Task { show(await model.readDockFinder()) }
    }

    /// Shows what was read, keeping Dock edits the user hasn't applied yet.
    func show(_ reading: DockFinderReading) {
        if !dockEdited { tiles = reading.tiles }
        values = reading.values
    }

    func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard tiles.indices.contains(target) else { return }
        tiles.swapAt(index, target)
        dockEdited = true
    }

    func toggle(_ title: String, _ value: Binding<Bool>, _ domain: String, _ key: String) -> some View {
        SettingRow(title: title) {
            Toggle(title, isOn: Binding(get: { value.wrappedValue }, set: { on in
                value.wrappedValue = on
                model.setPreferences("Changed \"\(title.lowercased())\"", [.init(domain, key, .bool(on))])
            }))
            .toggleStyle(.switch)
            .labelsHidden()
        }
    }

    func chooseScreenshotFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        values.screenshotFolder = url.path(percentEncoded: false)
        model.setPreferences("Changed where screenshots go",
                             [.init(WatchedPreferences.screenshotDomain, "location", .string(url.path(percentEncoded: false)))])
    }
}

struct AppsPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage("orbit.confirmedPermissions") private var confirmedRaw = ""

    var confirmed: Set<String> { Set(confirmedRaw.split(separator: ",").map(String.init)) }

    func setConfirmed(_ key: String, _ on: Bool) {
        var set = confirmed
        if on { set.insert(key) } else { set.remove(key) }
        confirmedRaw = set.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(page: .apps)
            ForEach(ManagedApp.all) { app in
                let state = model.state(app.id)
                GlassPanel(glow: state.isOn ? app.id.hue.top : nil) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 14) {
                            if FileManager.default.fileExists(atPath: app.path) {
                                Image(nsImage: Icons.of(app.path)).resizable().frame(width: 48, height: 48)
                            } else {
                                IconTile(symbol: app.symbol, hue: app.id.hue, size: 44)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 10) {
                                    Text(app.name).font(.title3.weight(.semibold))
                                    StatusPill(state: model.isBusy(app.id.rawValue) ? .working("Working…") : state)
                                }
                                Text(app.blurb).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if state == .notInstalled {
                                Button("Install") { model.install(app) }.buttonStyle(.glassProminent).disabled(model.isBusy(app.id.rawValue))
                            } else {
                                Button("Open") { model.open(app) }.buttonStyle(.glass)
                                if app.quickLookExtension == nil {
                                    Menu {
                                        Button("Open at login") { model.setLoginItem(app, on: true) }
                                        Button("Don't open at login") { model.setLoginItem(app, on: false) }
                                    } label: { Image(systemName: "power") }
                                        .menuStyle(.button).buttonStyle(.glass).fixedSize()
                                        .help("Open \(app.name) when you log in")
                                }
                            }
                        }
                        let needs = app.permissions.filter { $0 != .firstOpen }
                        if state != .notInstalled, !needs.isEmpty {
                            Divider()
                            Text("macOS asks you to allow \(app.name) to:").font(.subheadline.weight(.semibold))
                            ForEach(needs, id: \.self) { permission in
                                let key = "\(app.id.rawValue).\(permission.rawValue)"
                                HStack {
                                    Toggle(isOn: Binding(get: { confirmed.contains(key) }, set: { setConfirmed(key, $0) })) {
                                        Text(permission == .accessibility ? "Control windows (Accessibility)" : "See window previews (Screen Recording)")
                                    }
                                    .toggleStyle(.checkbox)
                                    Spacer()
                                    Button("Open Settings") { model.openSettings(.for(permission)) }.buttonStyle(.glass)
                                }
                            }
                            Text("Tick each one after you switch \(app.name) on in System Settings.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct HealthPage: View {
    @Environment(AppModel.self) private var model
    @State private var confirm: Confirm?
    @State private var storage: Int64?
    @State private var activity: [ActivityRecord] = []

    static func symbol(_ kind: ActivityRecord.Kind) -> String {
        switch kind {
        case .change: "slider.horizontal.3"
        case .command: "terminal"
        case .watchdog: "stethoscope"
        case .notice: "bell"
        }
    }

    enum Confirm: String, Identifiable {
        case baseline, dock, projects
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(page: .health)
            GlassPanel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Checkup").font(.title3.weight(.semibold))
                        Spacer()
                        if model.deepChecking { ProgressView().controlSize(.small) }
                        Button("Deep check") { Task { await model.refresh(deep: true) } }
                            .buttonStyle(.glass)
                            .disabled(model.deepChecking)
                            .help("Also asks macOS which helpers it blocks in the background (takes a few seconds)")
                    }
                    ForEach(FeatureID.allCases) { id in
                        let state = model.state(id)
                        HStack(spacing: 10) {
                            IconTile(symbol: id.symbol, hue: id.hue, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(id.title)
                                if let detail = state.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            StatusPill(state: state)
                            if state.needsAttention {
                                Button("Fix") { model.fix(id) }.buttonStyle(.glassProminent)
                            } else {
                                Button("Open") { model.page = id.page }.buttonStyle(.glass)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            SectionTitle(text: "Recent changes")
            GlassPanel {
                VStack(alignment: .leading, spacing: 8) {
                    if model.journal.isEmpty {
                        Text("Nothing changed yet. Everything you change in Orbit shows up here, with an Undo button.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.journal.reversed().prefix(15)) { entry in
                        HStack {
                            Image(systemName: entry.failed ? "exclamationmark.triangle.fill"
                                  : entry.undone ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                                .foregroundStyle(entry.failed ? Color.orange : entry.undone ? Color.secondary : Color.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title).strikethrough(entry.undone)
                                if entry.failed, let message = entry.message {
                                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer()
                            Text(entry.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                            if !entry.undone, !entry.actions.isEmpty {
                                Button("Undo") { model.undo(entry.id) }.buttonStyle(.glass).disabled(model.isBusy("undo"))
                            }
                        }
                    }
                }
            }

            SectionTitle(text: "Activity")
            GlassPanel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("What Orbit did lately, including what it put right by itself.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy diagnostics") { model.copyDiagnostics() }
                            .buttonStyle(.glass)
                            .help("Copies a report of Orbit's state, without your name or home folder, to paste into a message")
                    }
                    if let problem = model.ctx.store.saveProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    if activity.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                    ForEach(activity) { record in
                        HStack(spacing: 8) {
                            Image(systemName: Self.symbol(record.kind))
                                .foregroundStyle(record.ok ? Color.secondary : Color.orange)
                                .frame(width: 18)
                            Text(record.title).lineLimit(1)
                            if let detail = record.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(record.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .task {
                // Read from memory while this page shows (the task ends when it goes).
                while !Task.isCancelled {
                    let latest = model.ctx.activity.recent(12)
                    if latest != activity { activity = latest }
                    try? await Task.sleep(for: .seconds(3))
                }
            }

            SectionTitle(text: "Start over")
            GlassPanel {
                VStack(alignment: .leading, spacing: 12) {
                    restoreRow("Back to before Orbit", "Settings, config files and helpers go back to how they were when Orbit first opened.",
                               "clock.arrow.circlepath", .baseline)
                    restoreRow("Dock and Finder to Apple's defaults", "Clears every Dock and Finder tweak, including ones from before Orbit.",
                               "dock.arrow.down.rectangle", .dock)
                    restoreRow("Put projects back on the Desktop", "Moves the projects tidied into ~/Developer back where they were.",
                               "desktopcomputer", .projects)
                    HStack {
                        Text(storage.map { "Every change is backed up first. Orbit's own files take \(bytes($0)); backups Undo can no longer use clear away by themselves." }
                             ?? "Every change is backed up first.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Show backups") { NSWorkspace.shared.open(model.ctx.store.root.appending(path: "Backups")) }
                            .buttonStyle(.glass)
                    }
                    .task { storage = await model.storageUsed() }
                }
            }

            SectionTitle(text: "Orbit")
            GlassPanel {
                VStack(spacing: 10) {
                    SettingRow(title: "Open Orbit when you log in",
                               detail: model.loginNeedsApproval ? "Switched off in System Settings › General › Login Items. Turn it on to allow it there."
                                   : "Starts quietly in the menu bar, with no window, so the quick panel and fixes are always ready.") {
                        Toggle("Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                    SettingRow(title: "Notices", detail: "When something goes wrong while Orbit is in the background, a notice waits quietly in Notification Center.") {
                        Button("Show as banners") { Task { _ = await model.notifier?.askForBanners() } }
                            .buttonStyle(.glass)
                            .disabled(model.notifier == nil)
                    }
                    SettingRow(title: "Mode", detail: model.isPractice ? "Practice: nothing on your Mac changes." : "Live: changes apply to your Mac.") {
                        Text(model.isPractice ? "Practice" : "Live").foregroundStyle(model.isPractice ? .orange : .green).bold()
                    }
                }
            }

            if model.isPractice {
                SectionTitle(text: "Practice log: what would have happened")
                GlassPanel {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.practiceLog.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                        ForEach(model.practiceLog.reversed().prefix(40)) { entry in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.summary)
                                if !entry.detail.isEmpty {
                                    Text(entry.detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { which in
            Button("Yes, go ahead", role: .destructive) {
                switch which {
                case .baseline: model.restoreBaseline()
                case .dock: model.resetDockAndFinder()
                case .projects: model.putProjectsBack()
                }
            }
        } message: { _ in
            Text("A backup is saved first, and you can undo this from Recent changes.")
        }
    }

    var confirmTitle: String {
        switch confirm {
        case .baseline: "Go back to how things were before Orbit?"
        case .dock: "Reset the Dock and Finder to Apple's defaults?"
        case .projects: "Move the projects back onto the Desktop?"
        case nil: ""
        }
    }

    func restoreRow(_ title: String, _ detail: String, _ symbol: String, _ which: Confirm) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Hue.red.top).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore…") { confirm = which }.buttonStyle(.glass)
        }
    }
}
