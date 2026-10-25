import AppKit
import OrbitCore
import SwiftUI

/// Every way to reach Orbit without opening it: the command palette and its hotkey, Siri and
/// Shortcuts, widgets, Control Center, Focus, and links.
struct ShortcutsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(page: .shortcuts)

            GlassPanel(glow: Hue.indigo.top) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        IconTile(symbol: "command", hue: .indigo, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Command palette").font(.headline)
                            Text("Type what you want (a switch, a theme, a mode, a page) and press Return. Press ⌘K in Orbit, or the shortcut below anywhere.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Open it") { model.showPalette() }.buttonStyle(.glassProminent)
                    }
                    HotKeyRow()
                }
            }

            SectionTitle(text: "Siri and Shortcuts")
            GlassPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Say these to Siri, type them in Spotlight, or use Orbit's actions in the Shortcuts app. They work even when Orbit's window is closed.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Self.phrases, id: \.self) { phrase in
                        Label("“\(phrase)”", systemImage: "waveform").font(.callout)
                    }
                    HStack {
                        Spacer()
                        Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
                            .buttonStyle(.glass)
                    }
                }
            }

            SectionTitle(text: "Widgets, Control Center and Focus")
            GlassPanel {
                VStack(alignment: .leading, spacing: 12) {
                    help("rectangle.3.group.fill", "Desktop widgets",
                         "Right-click the desktop, choose Edit Widgets and search for Orbit: one shows how the Mac is set up with quick switches, one has your modes.")
                    help("switch.2", "Control Center",
                         "Open Control Center, click Edit Controls and search for Orbit: switches for tiling, the glow, the menu bar, Caps Lock and any mode, and Sort Downloads.")
                    help("moon.fill", "Focus",
                         "In System Settings › Focus, pick a Focus, then Add Filter › Orbit and choose a mode. It switches on with the Focus and off when it ends.")
                    HStack {
                        Spacer()
                        Button("Open Focus settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                        .buttonStyle(.glass)
                    }
                }
            }

            SectionTitle(text: "Links")
            GlassPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use these from Raycast, scripts or other apps. A change made by a link shows a notification with Undo.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(links, id: \.link) { item in
                        HStack {
                            Text(item.link).font(.callout.monospaced()).textSelection(.enabled)
                            Text(item.does).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.link, forType: .string)
                                model.show(Toast(ok: true, message: "Copied \(item.link)", journalID: nil))
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Copy \(item.link)")
                        }
                    }
                }
            }
        }
    }

    func help(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 26).foregroundStyle(Hue.indigo.top)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static let phrases = ["Toggle Window tiling in Orbit", "Start Focus mode with Orbit", "Stop the mode in Orbit",
                          "Switch Orbit to Nord", "Sort my Downloads with Orbit", "Check my Mac with Orbit", "Open Monitor in Orbit"]

    var links: [(link: String, does: String)] {
        let scheme = model.isPractice ? "orbitdev" : "orbit"
        let examples: [(OrbitCommand, String)] = [
            (.toggleFeature(.tiling), "tiling on or off"), (.setFeature(.glow, on: true), "glow on"),
            (.setTheme(.nord), "Nord theme"), (.toggleMode("focus"), "Focus mode on or off"), (.stopMode, "stop the mode"),
            (.sortDownloads, "sort Downloads"), (.checkStatus, "check everything"), (.open(.palette), "command palette"),
            (.open(.page(.monitor)), "open Monitor")
        ]
        return examples.compactMap { command, does in OrbitLink.url(for: command, scheme: scheme).map { ($0.absoluteString, does) } }
    }
}

/// The palette's shortcut: shows it, records a new one (warning about clashes) or switches it off.
struct HotKeyRow: View {
    @Environment(AppModel.self) private var model
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        let current = model.settings.hotKey ?? .standard
        SettingRow(title: "Shortcut from anywhere",
                   detail: problem ?? (current.enabled && !model.hotKeyRegistered && !model.isSnapshot
                                       ? "Another app already uses \(current.label): record a different one." : hint(current))) {
            HStack(spacing: 8) {
                Button(recording ? "Press the new shortcut…" : current.label) { recording ? stop() : start() }
                    .buttonStyle(.glass)
                    .disabled(!current.enabled)
                Toggle("On", isOn: Binding(get: { current.enabled }, set: { on in
                    var changed = current
                    changed.enabled = on
                    model.setHotKey(changed)
                }))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .onDisappear { stop() }
    }

    func hint(_ hotKey: HotKeySetting) -> String {
        hotKey.modifiers == HotKeySetting.hyper ? "With Caps Lock superpowers on, that's Caps Lock + \(hotKey.key)." : "Click it to record a new one."
    }

    func start() {
        problem = nil
        recording = true
        // The current shortcut steps aside while a new one is recorded.
        model.hotKey.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    func record(_ event: NSEvent) {
        if event.keyCode == 53 { return stop() }   // Esc: keep the old one
        let hotKey = HotKeySetting(keyCode: UInt32(event.keyCode), modifiers: Self.carbon(event.modifierFlags),
                                   key: Self.name(event))
        guard hotKey.isUsable else {
            problem = "Use at least two of ⌃ ⌥ ⇧ ⌘ with a key."
            return
        }
        if let clash = HotKeyClash.check(hotKey, skhdrc: model.ctx.files.read(model.ctx.paths.skhdrc).map { String(decoding: $0, as: UTF8.self) }) {
            problem = clash
            return
        }
        stop()
        model.setHotKey(hotKey)
        if !model.hotKeyRegistered { problem = "Another app already uses \(hotKey.label)." }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { model.applyHotKey() }
        recording = false
    }

    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= HotKeySetting.command }
        if flags.contains(.shift) { carbon |= HotKeySetting.shift }
        if flags.contains(.option) { carbon |= HotKeySetting.option }
        if flags.contains(.control) { carbon |= HotKeySetting.control }
        return carbon
    }

    static func name(_ event: NSEvent) -> String {
        let special: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                          122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                                          101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let name = special[event.keyCode] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}
