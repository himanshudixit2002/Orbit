import AppKit
import OrbitCore
import OrbitPlatform

extension AppModel {
    /// Runs a command from outside Orbit's window (a link, a Shortcut or Siri, a widget, Control Center,
    /// the hotkey or the palette) and says what happened. Changes take the same path as the window's
    /// switches: one at a time, in the history with Undo, in the activity log. Requests from the
    /// background never open System Settings or a sheet by themselves; they say what's needed instead.
    @discardableResult
    public func run(_ command: OrbitCommand, source: CommandSource) async -> OrbitReply {
        if case .open(let destination) = command { return show(destination) }
        await waitForFirstCheck()
        switch command {
        case .setFeature(let id, let on):
            return await set(id, on: on, source: source)
        case .toggleFeature(let id):
            return await set(id, on: !state(id).isOn, source: source)
        case .setTheme(let theme):
            return await setTheme(theme, quiet: source.isBackground)
        case .startMode(let id):
            guard let mode = settings.modes.first(where: { $0.id == id }) else { return noMode(id) }
            if modes.active?.modeID == id { return OrbitReply(ok: true, message: "\(mode.name) mode is already on.") }
            return await toggleMode(mode)
        case .toggleMode(let id):
            guard let mode = settings.modes.first(where: { $0.id == id }) else { return noMode(id) }
            return await toggleMode(mode)
        case .stopMode:
            guard let active = modes.active else { return OrbitReply(ok: true, message: "No mode is on.") }
            let name = modes.name(active)
            await modes.stop()
            return OrbitReply(ok: modes.active == nil, message: modes.active == nil ? "\(name) mode is off." : "Orbit is still switching modes.")
        case .sortDownloads:
            let result = await performNow("sortNow", "Sorted Downloads", quiet: source.isBackground) { [actions] _ in
                await actions.sortDownloadsNow()
            }
            return OrbitReply(ok: result.ok, message: result.message)
        case .checkStatus:
            await refresh(deep: true)
            return statusSummary()
        case .open(let destination):
            return show(destination)
        }
    }

    /// Commands need to know what's on: the first check after launch is waited for (briefly).
    func waitForFirstCheck() async {
        guard !isSnapshot else { return }
        for _ in 0..<100 where status.checkedAt == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func set(_ id: FeatureID, on: Bool, source: CommandSource) async -> OrbitReply {
        let current = state(id)
        guard let change = featureChange(id, on: on) else {
            return OrbitReply(ok: false, message: "\(id.title) has no on/off switch. Open Orbit to use it.")
        }
        if current == .notInstalled {
            if !source.isBackground { show(.page(id.page)) }
            return OrbitReply(ok: false, message: "\(id.title) isn't installed yet. Orbit can set it up from its \(id.page.title) page.")
        }
        // Switching on something that needs the user's OK first: the window takes them there; from
        // the background, say what's needed.
        if on, current.needsAttention {
            if !source.isBackground {
                fix(id)
                return OrbitReply(ok: false, message: current.detail ?? "\(id.title) needs your attention.")
            }
            return OrbitReply(ok: false, message: "\(id.title) needs your OK first: \(current.detail ?? "open Orbit to see why.")")
        }
        if current.isOn == on {
            return OrbitReply(ok: true, message: "\(id.title) is already \(on ? "on" : "off").")
        }
        let result = await performNow(change.key, change.title, quiet: source.isBackground, change.work)
        return OrbitReply(ok: result.ok, message: result.message)
    }

    /// The change behind a feature's switch: its busy key, its title in the history, and the work.
    func featureChange(_ id: FeatureID, on: Bool) -> (key: String, title: String, work: Work)? {
        switch id {
        case .tiling:
            return ("tiling", on ? "Turned on window tiling" : "Turned off window tiling", { [actions] in
                try await actions.setTiling(on, policy: $0)
            })
        case .glow:
            return ("glow", on ? "Turned on the window glow" : "Turned off the window glow", { [actions] in
                try await actions.setGlow(on, policy: $0)
            })
        case .menuBar:
            return ("menuBar", on ? "Turned on the new menu bar" : "Turned off the new menu bar", { [actions] in
                try await actions.setMenuBar(on, policy: $0)
            })
        case .capsLock:
            var keyboard = settings.keyboard
            keyboard.capsLockEnabled = on
            return ("keyboard", on ? "Turned on Caps Lock superpowers" : "Turned off Caps Lock superpowers", { [actions, keyboard] _ in
                try await actions.applyKeyboard(keyboard)
            })
        case .downloads:
            return ("downloads", on ? "Turned on Downloads sorting" : "Turned off Downloads sorting", { [actions] _ in
                await actions.setDownloads(on)
            })
        case .raycast, .altTab, .ice, .syntaxHighlight, .terminalLook:
            return nil
        }
    }

    /// The change behind picking a theme.
    func themeChange(_ id: ThemeID) -> (title: String, work: Work) {
        let tmux = settings.themeTmux
        return ("Switched to the \(Palette.named(id).name) theme", { [actions] in
            try await actions.applyTheme(id, tmux: tmux, policy: $0)
        })
    }

    func setTheme(_ id: ThemeID, quiet: Bool) async -> OrbitReply {
        guard id != settings.theme else { return OrbitReply(ok: true, message: "\(Palette.named(id).name) is already the theme.") }
        let change = themeChange(id)
        settings.theme = id
        let result = await performNow("theme", change.title, quiet: quiet, change.work)
        if result.ok, settings.wallpaperFollowsTheme { setThemeWallpaper(Palette.named(id)) }
        return OrbitReply(ok: result.ok, message: result.message)
    }

    func toggleMode(_ mode: ModeDefinition) async -> OrbitReply {
        let wasOn = modes.active?.modeID == mode.id
        await modes.toggle(mode)
        let isOn = modes.active?.modeID == mode.id
        guard isOn != wasOn else { return OrbitReply(ok: false, message: "Orbit is still switching modes. Try again in a moment.") }
        return OrbitReply(ok: true, message: "\(mode.name) mode is \(isOn ? "on" : "off").")
    }

    func noMode(_ id: String) -> OrbitReply {
        OrbitReply(ok: false, message: "There's no mode called \"\(id)\". Your modes: \(settings.modes.map(\.name).joined(separator: ", ")).")
    }

    /// "8 of 10 are on. Window tiling needs attention: …"
    func statusSummary() -> OrbitReply {
        let issues = attention.map { "\($0.title) needs attention: \(state($0).detail ?? state($0).label)" }
        let summary = "\(doneCount) of \(coreFeatures.count) are on."
        return OrbitReply(ok: issues.isEmpty, message: ([summary] + issues).joined(separator: " "))
    }

    /// Shows part of Orbit, bringing it to the front.
    @discardableResult
    func show(_ destination: OrbitDestination) -> OrbitReply {
        switch destination {
        case .page(let page):
            openMainWindow()
            self.page = page
            return OrbitReply(ok: true, message: "Opened \(page.title).")
        case .setup:
            openMainWindow()
            showSetup = true
            return OrbitReply(ok: true, message: "Opened the guided setup.")
        case .panel:
            if let openWindow {
                openWindow(id: "panel")
                NSApp.activate()
            } else {
                openMainWindow()
            }
            return OrbitReply(ok: true, message: "Opened the quick panel.")
        case .palette:
            focusSearch()
            return OrbitReply(ok: true, message: "Opened search.")
        }
    }
}
