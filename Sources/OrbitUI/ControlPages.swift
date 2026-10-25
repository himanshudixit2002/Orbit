import AppKit
import OrbitCore
import OrbitPlatform
import SwiftUI

struct WindowsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(page: .windows)
            FeatureCard(title: "Arrange windows automatically",
                        blurb: "New windows slide into neat tiles that share the screen. Hold ⌥ (Option) and drag to move or resize one.",
                        symbol: FeatureID.tiling.symbol, hue: .cyan, state: model.state(.tiling), poweredBy: "yabai and skhd",
                        isBusy: model.isBusy("tiling"), illustration: AnyView(TilingIllustration()),
                        onToggle: { model.setTiling($0) }, onFix: { model.fix(.tiling) }) {
                TilingControls()
            }
            if model.state(.tiling).isOn { WindowLayoutsPanel() }
            FeatureCard(title: "Glow around the window you're using",
                        blurb: "A soft coloured outline shows which window is active, so you never type into the wrong one.",
                        symbol: FeatureID.glow.symbol, hue: .purple, state: model.state(.glow), poweredBy: "JankyBorders",
                        isBusy: model.isBusy("glow"),
                        illustration: AnyView(GlowIllustration(color: Color(model.settings.glow.color(in: model.palette)))),
                        onToggle: { model.setGlow($0) }) {
                GlowControls()
            }
            GlassPanel {
                HStack(spacing: 14) {
                    IconTile(symbol: "keyboard", hue: .orange, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Move windows with the keyboard").font(.headline)
                        Text("⌥ H J K L to jump between windows, ⌥ F for full screen, ⌥ / for every shortcut.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("See all shortcuts") { model.page = .keyboard }.buttonStyle(.glass)
                }
            }
        }
    }
}

/// Desktops with a style of their own, and saved window arrangements.
struct WindowLayoutsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var spaces: [YabaiSpace] = []
    @State private var name = ""

    var desktops: [Int] {
        let count = max(spaces.map(\.index).max() ?? 0, model.settings.tiling.spaceLayouts.map(\.space).max() ?? 0)
        return count == 0 ? [] : Array(1...count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionTitle(text: "Each desktop")
            GlassPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Give a desktop its own window style; the rest keep the one above.").foregroundStyle(.secondary)
                    if desktops.isEmpty { Text("Looking for desktops…").foregroundStyle(.tertiary) }
                    ForEach(desktops, id: \.self) { space in
                        SettingRow(title: "Desktop \(space)", detail: spaces.first { $0.index == space }?.isVisible == true ? "On screen now" : "") {
                            Picker("Desktop \(space)", selection: Binding(
                                get: { model.settings.tiling.spaceLayouts.first { $0.space == space }?.layout },
                                set: { model.setSpaceLayout(space, $0) })) {
                                Text("Same as the others").tag(TilingLayout?.none)
                                ForEach(TilingLayout.allCases) { Text($0.title).tag(Optional($0)) }
                            }
                            .labelsHidden().frame(width: 200)
                            .disabled(model.isBusy("spaceLayout-\(space)"))
                        }
                    }
                }
            }
            SectionTitle(text: "Saved arrangements")
            GlassPanel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("Name it, like Coding", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                            .onSubmit(save)
                        Button("Save how the windows sit now", action: save)
                            .buttonStyle(.glassProminent)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy("saveLayout"))
                    }
                    Text("Arranging puts each window back on its own desktop: macOS doesn't let Orbit move windows between desktops. Give an arrangement a Caps Lock key on the Keyboard page.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.settings.windowLayouts) { layout in
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.3.group").frame(width: 22).foregroundStyle(Hue.cyan.top)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(layout.name).font(.body.weight(.medium))
                                Text(layout.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Arrange") { Task { await model.run(.arrangeWindows(layout.name), source: .window) } }
                                .buttonStyle(.glass)
                                .disabled(model.isBusy("arrange"))
                            Menu {
                                Button("Save the windows as they are now") { model.saveWindowLayout(layout.name) }
                                Button("Delete", role: .destructive) { model.deleteWindowLayout(layout) }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.button).buttonStyle(.borderless).fixedSize()
                                .accessibilityLabel("More for \(layout.name)")
                        }
                    }
                }
            }
        }
        .task(id: model.journal.count) {
            if let now = await model.actions.windowsNow() { spaces = now.spaces }
        }
    }

    func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.saveWindowLayout(trimmed)
        name = ""
    }
}

struct TilingControls: View {
    @Environment(AppModel.self) private var model
    @State private var tiling = TilingSettings()
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            SettingRow(title: "Style", detail: tiling.layout.blurb) {
                Picker("Style", selection: $tiling.layout) {
                    ForEach(TilingLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                .onChange(of: tiling.layout) { if loaded, tiling != model.settings.tiling { model.applyTiling(tiling) } }
            }
            SettingRow(title: "Space between windows", detail: "\(tiling.gap) points") {
                Slider(value: Binding(get: { Double(tiling.gap) }, set: { tiling.gap = Int($0) }), in: 0...30, step: 2) { editing in
                    if !editing { model.applyTiling(tiling) }
                }
                .frame(width: 300)
            }
            SettingRow(title: "Space around the edges", detail: "\(tiling.padding) points") {
                Slider(value: Binding(get: { Double(tiling.padding) }, set: { tiling.padding = Int($0) }), in: 0...40, step: 2) { editing in
                    if !editing { model.applyTiling(tiling) }
                }
                .frame(width: 300)
            }
            DisclosureGroup("More options") {
                TilingMoreOptions(tiling: $tiling) { model.applyTiling(tiling) }
                    .padding(.top, 8)
            }
        }
        .onChange(of: tiling.newWindowsFirst) { if loaded, tiling != model.settings.tiling { model.applyTiling(tiling) } }
        .onChange(of: tiling.autoBalance) { if loaded, tiling != model.settings.tiling { model.applyTiling(tiling) } }
        .onChange(of: tiling.focusFollowsMouse) { if loaded, tiling != model.settings.tiling { model.applyTiling(tiling) } }
        .onChange(of: tiling.mouseFollowsFocus) { if loaded, tiling != model.settings.tiling { model.applyTiling(tiling) } }
        .onAppear {
            tiling = model.settings.tiling
            DispatchQueue.main.async { loaded = true }
        }
        // Undo can change the saved settings while this shows: follow them, unless a change made here is on its way.
        .onChange(of: model.settings.tiling) { _, saved in
            if !model.isBusy("tilingSettings"), tiling != saved { tiling = saved }
        }
    }
}

/// Tiling's finer points: where new windows go, how splits share, and what the pointer does.
struct TilingMoreOptions: View {
    @Binding var tiling: TilingSettings
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow(title: "New windows open", detail: placementDetail) {
                Picker("New windows", selection: $tiling.newWindowsFirst) {
                    Text("Left").tag(true)
                    Text("Right").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            SettingRow(title: "First window's share", detail: "\(Int((tiling.splitRatio * 100).rounded()))% of a split") {
                Slider(value: $tiling.splitRatio, in: 0.3...0.7, step: 0.05) { editing in
                    if !editing { apply() }
                }
                .frame(width: 300)
            }
            SettingRow(title: "Keep windows the same size", detail: "Every window gets an equal share") {
                Toggle("Balance", isOn: $tiling.autoBalance).toggleStyle(.switch).labelsHidden()
            }
            SettingRow(title: "Pointing at a window", detail: focusDetail) {
                Picker("Focus", selection: $tiling.focusFollowsMouse) {
                    ForEach(FocusFollowsMouse.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            SettingRow(title: "Pointer follows the keyboard", detail: "Moving between windows with ⌥ H J K L moves the pointer too") {
                Toggle("Pointer follows", isOn: $tiling.mouseFollowsFocus).toggleStyle(.switch).labelsHidden()
            }
            FloatingAppsEditor()
        }
    }

    var placementDetail: String {
        tiling.newWindowsFirst ? "On the left of (or above) the window they split" : "On the right of (or below) the window they split"
    }

    var focusDetail: String {
        tiling.focusFollowsMouse == .off ? "Click a window to use it" : "The window under the pointer becomes the active one"
    }
}

/// The apps whose windows float instead of tiling.
struct FloatingAppsEditor: View {
    @Environment(AppModel.self) private var model
    @State private var apps: [String] = []
    @State private var loaded = false

    var body: some View {
        AppChips(title: "Apps that float", subtitle: "Their windows stay where you put them instead of tiling.",
                 apps: $apps, installed: model.appCatalog.apps)
            .onAppear {
                apps = model.settings.floatingApps
                model.appCatalog.refresh()
                DispatchQueue.main.async { loaded = true }
            }
            .onChange(of: apps) { if loaded, apps != model.settings.floatingApps { model.applyFloatingApps(apps) } }
            .onChange(of: model.settings.floatingApps) { _, saved in
                if !model.isBusy("floatingApps"), apps != saved { apps = saved }
            }
    }
}

struct GlowControls: View {
    @Environment(AppModel.self) private var model
    @State private var glow = GlowSettings()
    @State private var loaded = false

    var color: Binding<Color> {
        Binding(get: { Color(glow.customColor) }, set: { newValue in
            let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .systemBlue
            glow.customColor = RGB(r: UInt8(ns.redComponent * 255), g: UInt8(ns.greenComponent * 255), b: UInt8(ns.blueComponent * 255))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            SettingRow(title: "Colour", detail: glow.useThemeColor ? "Follows your theme (\(model.palette.name))" : "Your own colour") {
                HStack(spacing: 12) {
                    Toggle("Match theme", isOn: $glow.useThemeColor).toggleStyle(.switch)
                    if !glow.useThemeColor {
                        ColorPicker("Glow colour", selection: color, supportsOpacity: false).labelsHidden()
                    }
                }
            }
            SettingRow(title: "Soft glow", detail: "A blurred halo instead of a crisp line") {
                Toggle("Soft glow", isOn: $glow.glow).toggleStyle(.switch).labelsHidden()
            }
            SettingRow(title: "Thickness", detail: String(format: "%.0f points", glow.width)) {
                Slider(value: $glow.width, in: 2...14, step: 1) { editing in
                    if !editing { model.applyGlow(glow) }
                }
                .frame(width: 300)
            }
            SettingRow(title: "Corners", detail: glow.style == .round ? "Rounded, like the windows" : "Square") {
                Picker("Corners", selection: $glow.style) {
                    Text("Round").tag(BorderStyle.round)
                    Text("Square").tag(BorderStyle.square)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            AppChips(title: "Apps without a glow", subtitle: "Their windows get no outline (pop-up helpers, launchers).",
                     apps: $glow.ignoredApps, installed: model.appCatalog.apps)
        }
        .onChange(of: glow.style) { if loaded, glow != model.settings.glow { model.applyGlow(glow) } }
        .onChange(of: glow.ignoredApps) { if loaded, glow != model.settings.glow { model.applyGlow(glow) } }
        .onChange(of: glow.useThemeColor) { if loaded, glow != model.settings.glow { model.applyGlow(glow) } }
        .onChange(of: glow.glow) { if loaded, glow != model.settings.glow { model.applyGlow(glow) } }
        .onChange(of: glow.customColor) { if loaded, !glow.useThemeColor, glow != model.settings.glow { model.applyGlow(glow) } }
        .onAppear {
            glow = model.settings.glow
            model.appCatalog.refresh()
            DispatchQueue.main.async { loaded = true }
        }
        .onChange(of: model.settings.glow) { _, saved in
            if !model.isBusy("glowSettings"), glow != saved { glow = saved }
        }
    }
}

struct MenuBarPage: View {
    @Environment(AppModel.self) private var model
    @State private var bar = BarSettings()
    @State private var loaded = false

    func shown(_ item: BarItem) -> Binding<Bool> {
        Binding(get: { bar.isShown(item) }, set: { bar.setShown(item, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(page: .menuBar)
            FeatureCard(title: "Floating menu bar",
                        blurb: "A rounded glass bar across the top with your desktops, the current app, music and live stats. The Mac's own menus slide down when you point at the top of the screen.",
                        symbol: FeatureID.menuBar.symbol, hue: .indigo, state: model.state(.menuBar), poweredBy: "SketchyBar",
                        isBusy: model.isBusy("menuBar"), illustration: AnyView(MenuBarIllustration(palette: model.palette)),
                        onToggle: { model.setMenuBar($0) }, onFix: { model.fix(.menuBar) }) {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    Text("Show in the bar").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                        ForEach(BarItem.allCases) { item in
                            Toggle(isOn: shown(item)) {
                                Label(item.title, systemImage: item.symbol)
                            }
                            .toggleStyle(.button)
                            .buttonStyle(.glass)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(item.blurb)
                        }
                    }
                    Text("Where they sit").font(.headline).padding(.top, 4)
                    Text("Click an item to move it along, or to another part of the bar.").font(.caption).foregroundStyle(.secondary)
                    BarLayoutEditor(bar: $bar)
                    SettingRow(title: "Position", detail: bar.position == .top ? "Across the top; the Mac's own menus slide down when you point there"
                                                                             : "Along the bottom; the Mac's own menu bar stays at the top") {
                        Picker("Position", selection: $bar.position) {
                            Text("Top").tag(BarPosition.top)
                            Text("Bottom").tag(BarPosition.bottom)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                    }
                    SettingRow(title: "Clock", detail: BarFeed.clockLabel(Date(), format: bar.clockFormat)) {
                        Picker("Clock", selection: $bar.clockFormat) {
                            ForEach(ClockFormat.allCases) { format in
                                Text(BarFeed.clockLabel(Date(), format: format)).tag(format)
                            }
                        }
                        .labelsHidden().frame(width: 220)
                    }
                    .disabled(!bar.showClock)
                    SettingRow(title: "Hide empty desktops", detail: "Only desktops with windows, and the ones on screen, get a number") {
                        Toggle("Hide empty desktops", isOn: $bar.hideEmptySpaces).toggleStyle(.switch).labelsHidden()
                    }
                    .disabled(!bar.showSpaces)
                    SettingRow(title: "Height", detail: "\(bar.height) points") {
                        Slider(value: Binding(get: { Double(bar.height) }, set: { bar.height = Int($0) }), in: 26...44, step: 2)
                            .frame(width: 260)
                    }
                    SettingRow(title: "Gap from the edge", detail: "\(bar.yOffset) points from the \(bar.position.rawValue) of the screen") {
                        Slider(value: Binding(get: { Double(bar.yOffset) }, set: { bar.yOffset = Int($0) }), in: 0...14, step: 1)
                            .frame(width: 260)
                    }
                    Label("Tip: click the Apple logo in the bar to open Orbit's quick panel.", systemImage: "lightbulb.fill")
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
        }
        .onChange(of: bar) { if loaded, bar != model.settings.bar { model.applyBar(bar) } }
        .onAppear {
            bar = model.settings.bar
            DispatchQueue.main.async { loaded = true }
        }
        .onChange(of: model.settings.bar) { _, saved in
            if !model.isBusy("barSettings"), bar != saved { bar = saved }
        }
    }
}

/// The bar's three parts with the items shown in each, in order; each item's menu moves it.
struct BarLayoutEditor: View {
    @Binding var bar: BarSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(BarSide.allCases) { side in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(side.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    let items = bar.items(on: side)
                    if items.isEmpty {
                        Text("Nothing here").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(items) { item in chip(item, side: side, first: item == items.first, last: item == items.last) }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func chip(_ item: BarItem, side: BarSide, first: Bool, last: Bool) -> some View {
        Menu {
            Button("Move left", systemImage: "arrow.left") { bar.move(item, by: -1) }.disabled(first)
            Button("Move right", systemImage: "arrow.right") { bar.move(item, by: 1) }.disabled(last)
            Divider()
            ForEach(BarSide.allCases.filter { $0 != side }) { other in
                Button("Move to the \(other.title.lowercased())") { bar.setSide(item, other) }
            }
            Divider()
            Button("Hide", systemImage: "eye.slash") { bar.setShown(item, false) }
        } label: {
            Label(item.title, systemImage: item.symbol).font(.caption)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .accessibilityHint("Moves \(item.title) in the bar")
    }
}

struct KeyboardPage: View {
    @Environment(AppModel.self) private var model
    @State private var keyboard = KeyboardSettings()

    var installing: Bool {
        switch model.karabinerStep {
        case .idle, .done, .failed: false
        default: true
        }
    }

    var stepText: String? {
        switch model.karabinerStep {
        case .idle, .done: nil
        case .downloading: "Downloading Karabiner-Elements…"
        case .checking: "Checking the installer is genuine…"
        case .waitingForPassword: "Type your Mac password in the window macOS just opened."
        case .installing: "Installing…"
        case .finishing: "Almost done. Follow Karabiner's steps to allow its keyboard driver."
        case .failed(let why): why
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(page: .keyboard)
            FeatureCard(title: "Caps Lock superpowers",
                        blurb: "Tap Caps Lock for Escape. Hold it and press a letter to jump straight to an app.",
                        symbol: FeatureID.capsLock.symbol, hue: .orange, state: model.state(.capsLock), poweredBy: "Karabiner-Elements",
                        isBusy: model.isBusy("keyboard") || installing, illustration: AnyView(KeyboardIllustration()),
                        onToggle: { on in
                            keyboard.capsLockEnabled = on
                            model.applyKeyboard(keyboard)
                        },
                        onFix: { model.fix(.capsLock) }, onInstall: { model.installKarabiner() }) {
                VStack(alignment: .leading, spacing: 10) {
                    if let stepText {
                        Label(stepText, systemImage: installing ? "hourglass" : "exclamationmark.triangle.fill")
                            .foregroundStyle(installing ? Color.secondary : Color.orange)
                    }
                    Divider()
                    Text("Hold Caps Lock and press…").font(.headline)
                    VStack(spacing: 6) {
                        ForEach($keyboard.hyperApps) { $binding in
                            HyperKeyRow(binding: $binding, freeKeys: freeKeys(keeping: binding.key), apps: appChoices(including: binding),
                                        modes: model.settings.modes, layouts: model.settings.windowLayouts.map(\.name), save: { model.applyKeyboard(keyboard) }) {
                                keyboard.hyperApps.removeAll { $0.key == binding.key }
                                model.applyKeyboard(keyboard)
                            }
                        }
                    }
                    HStack {
                        Button {
                            guard let key = freeKeys(keeping: nil).first else { return }
                            keyboard.hyperApps.append(HyperBinding(key: key, appName: "Finder", appPath: "/System/Library/CoreServices/Finder.app"))
                            model.applyKeyboard(keyboard)
                        } label: { Label("Add a key", systemImage: "plus") }
                            .buttonStyle(.glass)
                            .disabled(freeKeys(keeping: nil).isEmpty)
                        Spacer()
                    }
                    SettingRow(title: "Tap for Escape", detail: "A tap shorter than \(keyboard.tapTimeout) ms is Escape; hold longer for Hyper.") {
                        Slider(value: Binding(get: { Double(keyboard.tapTimeout) }, set: { keyboard.tapTimeout = Int($0) }), in: 150...500, step: 25) { editing in
                            if !editing { model.applyKeyboard(keyboard) }
                        }
                        .frame(width: 260)
                    }
                }
            }
            GlassPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        IconTile(symbol: "command", hue: .cyan, size: 36)
                        VStack(alignment: .leading) {
                            Text("Window shortcuts").font(.headline)
                            Text("They work while window tiling is on. ⌥ is the Option key.").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(ShortcutCatalog.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(group.items, id: \.keys) { item in
                                HStack(spacing: 6) {
                                    ForEach(item.keys.split(separator: " ").map(String.init), id: \.self) { KeyCap(text: $0) }
                                    Text(item.does).padding(.leading, 6)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            keyboard = model.settings.keyboard
            model.appCatalog.refresh()
        }
        .onChange(of: model.settings.keyboard) { _, saved in
            if !model.isBusy("keyboard"), keyboard != saved { keyboard = saved }
        }
    }

    /// Letters and digits no other key uses (and this one's own).
    func freeKeys(keeping key: String?) -> [String] {
        let used = Set(keyboard.hyperApps.map(\.key)).subtracting([key].compactMap { $0 })
        return HyperBinding.keys.filter { !used.contains($0) }
    }

    func appChoices(including binding: HyperBinding) -> [InstalledApp] {
        let apps = model.appCatalog.apps
        return apps.contains { $0.path == binding.appPath } ? apps : [InstalledApp(name: binding.appName, path: binding.appPath)] + apps
    }
}

/// One Caps Lock key: which key, what it does, and what with.
struct HyperKeyRow: View {
    enum Kind: String, CaseIterable {
        case app = "App", website = "Website", folder = "Folder", orbit = "Orbit"
    }

    @Binding var binding: HyperBinding
    let freeKeys: [String]
    let apps: [InstalledApp]
    let modes: [ModeDefinition]
    var layouts: [String] = []
    let save: () -> Void
    let remove: () -> Void
    @State private var website = ""

    var kind: Kind {
        switch binding.action {
        case .app: .app
        case .website: .website
        case .folder: .folder
        case .orbit: .orbit
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(freeKeys, id: \.self) { key in
                    Button(key.uppercased()) {
                        binding.key = key
                        save()
                    }
                }
            } label: { KeyCap(text: binding.key.uppercased()) }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("Key \(binding.key.uppercased())")
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            Picker("Does", selection: Binding(get: { kind }, set: change)) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 100)
            detail
            Spacer(minLength: 4)
            Button(action: remove) { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove Caps Lock + \(binding.key.uppercased())")
        }
        .onAppear { if case .website(let url) = binding.action { website = url } }
    }

    @ViewBuilder
    var detail: some View {
        switch binding.action {
        case .app:
            Picker("App", selection: Binding(get: { binding.appPath }, set: { path in
                binding.appPath = path
                binding.appName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                binding.bundleID = nil
                save()
            })) {
                ForEach(apps, id: \.path) { Text($0.name).tag($0.path) }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
        case .website:
            TextField("https://…", text: $website)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .onSubmit {
                    let trimmed = website.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    website = trimmed.contains("://") ? trimmed : "https://" + trimmed
                    binding.action = .website(website)
                    save()
                }
        case .folder(let path):
            Button(path.isEmpty ? "Choose a folder…" : URL(fileURLWithPath: path).lastPathComponent) { chooseFolder() }
                .buttonStyle(.glass)
            Text("in \(binding.appName.isEmpty ? "Finder" : binding.appName)").font(.caption).foregroundStyle(.secondary)
        case .orbit(let command):
            Picker("Orbit", selection: Binding(get: { command }, set: { binding.action = .orbit($0); save() })) {
                ForEach(orbitChoices, id: \.1) { Text($0.0).tag($0.1) }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
        }
    }

    /// Switching what a key does: an Orbit action works at once; a website or folder waits to be given.
    func change(_ kind: Kind) {
        switch kind {
        case .app:
            binding.action = .app
            if binding.appPath.isEmpty {
                binding.appName = "Finder"
                binding.appPath = "/System/Library/CoreServices/Finder.app"
            }
            save()
        case .website:
            binding.action = .website(website)
        case .folder:
            binding.action = .folder("")
            chooseFolder()
        case .orbit:
            binding.action = .orbit(.open(.palette))
            save()
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Developer")
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.action = .folder(url.path(percentEncoded: false))
        save()
    }

    var orbitChoices: [(String, OrbitCommand)] {
        [("Command palette", .open(.palette)), ("Open Orbit", .open(.page(.home))), ("Window tiling on or off", .toggleFeature(.tiling)),
         ("Glow on or off", .toggleFeature(.glow)), ("Menu bar on or off", .toggleFeature(.menuBar)), ("Sort Downloads", .sortDownloads),
         ("Check everything", .checkStatus), ("Stop the mode", .stopMode)]
            + modes.map { ("\($0.name) mode on or off", OrbitCommand.toggleMode($0.id)) }
            + layouts.map { ("Arrange windows: \($0)", OrbitCommand.arrangeWindows($0)) }
    }
}

/// A keyboard key, drawn.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .padding(.horizontal, 8)
            .frame(minWidth: 28, minHeight: 26)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.35)))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 1.5)
    }
}

/// Every window shortcut, in plain words.
enum ShortcutCatalog {
    struct Item { let keys: String; let does: String }
    struct Group { let title: String; let items: [Item] }

    static let groups: [Group] = [
        Group(title: "Move around", items: [
            Item(keys: "⌥ H/J/K/L", does: "Jump to the window left, below, above or right"),
            Item(keys: "⇧ ⌥ H/J/K/L", does: "Swap with that window"),
            Item(keys: "⌃ ⌥ H/J/K/L", does: "Move the window into a new split there"),
            Item(keys: "⌃ ⇧ H/J/K/L", does: "Make the window smaller or bigger")
        ]),
        Group(title: "One window", items: [
            Item(keys: "⌥ F", does: "Full screen (keeps the gaps)"),
            Item(keys: "⌥ T", does: "Float it in the middle, again to tile it"),
            Item(keys: "⇧ ⌥ C", does: "Float it, medium size")
        ]),
        Group(title: "The whole screen", items: [
            Item(keys: "⌥ E", does: "Make every window the same size"),
            Item(keys: "⌥ R", does: "Rotate the layout"),
            Item(keys: "⌃ ⌥ B", does: "Tiles"),
            Item(keys: "⌃ ⌥ S", does: "One at a time (stack)"),
            Item(keys: "⌃ ⌥ D", does: "Free, like normal macOS"),
            Item(keys: "⌃ ⌥ Q", does: "Turn tiling off or on")
        ]),
        Group(title: "Handy", items: [
            Item(keys: "⌥ Return", does: "Open Warp"),
            Item(keys: "⌥ /", does: "Show this list as a cheat sheet")
        ])
    ]
}
