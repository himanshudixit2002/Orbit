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
        }
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
        }
        .onChange(of: glow.useThemeColor) { if loaded, glow != model.settings.glow { model.applyGlow(glow) } }
        .onChange(of: glow.glow) { if loaded, glow != model.settings.glow { model.applyGlow(glow) } }
        .onChange(of: glow.customColor) { if loaded, !glow.useThemeColor, glow != model.settings.glow { model.applyGlow(glow) } }
        .onAppear {
            glow = model.settings.glow
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

    var items: [(String, String, WritableKeyPath<BarSettings, Bool>)] {
        [("Desktops", "square.grid.3x1.below.line.grid.1x2", \.showSpaces), ("Current app", "app.badge", \.showFrontApp),
         ("Spotify song", "music.note", \.showSpotify), ("Processor", "cpu", \.showCPU), ("Memory", "memorychip", \.showMemory),
         ("Volume", "speaker.wave.2.fill", \.showVolume), ("Network", "wifi", \.showNetwork), ("Clock", "clock.fill", \.showClock)]
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
                        ForEach(items, id: \.0) { item in
                            Toggle(isOn: $bar[dynamicMember: item.2]) {
                                Label(item.0, systemImage: item.1)
                            }
                            .toggleStyle(.button)
                            .buttonStyle(.glass)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
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

extension BarSettings {
    subscript(dynamicMember keyPath: WritableKeyPath<BarSettings, Bool>) -> Bool {
        get { self[keyPath: keyPath] }
        set { self[keyPath: keyPath] = newValue }
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 8) {
                        ForEach($keyboard.hyperApps) { $binding in
                            HStack(spacing: 10) {
                                KeyCap(text: binding.key.uppercased())
                                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                Picker("App", selection: Binding(get: { binding.appPath }, set: { path in
                                    binding.appPath = path
                                    binding.appName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                                    binding.bundleID = nil
                                    model.applyKeyboard(keyboard)
                                })) {
                                    ForEach(appChoices(including: binding), id: \.path) { app in
                                        Text(app.name).tag(app.path)
                                    }
                                }
                                .labelsHidden()
                            }
                        }
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

    func appChoices(including binding: HyperBinding) -> [InstalledApp] {
        let apps = model.appCatalog.apps
        return apps.contains { $0.path == binding.appPath } ? apps : [InstalledApp(name: binding.appName, path: binding.appPath)] + apps
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
