import AppKit
import OrbitCore
import OrbitPlatform
import OrbitShared

extension AppModel: OrbitCommandHandling {
    /// A Focus with an Orbit mode set came on (that mode starts) or ended: the mode it started stops,
    /// unless the user has switched modes since.
    public func focusChanged(to modeID: String?) async {
        let key = "focusStartedMode"
        if let modeID {
            if await run(.startMode(modeID), source: .focus).ok { focusDefaults.set(modeID, forKey: key) }
        } else if let started = focusDefaults.string(forKey: key) {
            focusDefaults.removeObject(forKey: key)
            if modes.active?.modeID == started { await run(.stopMode, source: .focus) }
        }
    }
}

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
        case .arrangeWindows(let name):
            guard let layout = settings.windowLayouts.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                let saved = settings.windowLayouts.map(\.name)
                return OrbitReply(ok: false, message: saved.isEmpty ? "No window layouts are saved yet. Save one on the Windows page."
                                                                    : "There's no layout called \"\(name)\". Saved: \(saved.joined(separator: ", ")).")
            }
            let result = await performNow("arrange", "Arranged the windows as \"\(layout.name)\"", quiet: source.isBackground) { [actions] _ in
                await actions.arrangeWindows(layout)
            }
            return OrbitReply(ok: result.ok, message: result.message)
        case .checkStatus:
            await refresh(deep: true)
            return statusSummary()
        case .setPaused(let pause):
            return pause ? await pauseOrbit(quiet: source.isBackground) : await resumeOrbit(quiet: source.isBackground)
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
        if result.ok, source == .link { noticeLinkChange(change.title) }
        return OrbitReply(ok: result.ok, message: result.message)
    }

    /// A link can come from anywhere: what it changed shows in a notification, with Undo.
    func noticeLinkChange(_ title: String) {
        guard let entry = journal.last(where: { $0.title == title && !$0.undone }), Date().timeIntervalSince(entry.date) < 10 else { return }
        notifier?.send(.changed, key: "link \(entry.id)", title: title, body: "A link asked Orbit to do this. Undo puts it back.") { [weak self] in
            self?.undo(entry.id)
        }
    }

    /// Something that newly needs the user (a permission taken away, say), while Orbit's window isn't in
    /// front: one notice per feature every six hours at most, with Fix. Not on the first check after
    /// launch (nothing is new then), and not for a helper the watchdog has already reported.
    @discardableResult
    func noticeNewAttention() -> [FeatureID] {
        let now = Set(attention)
        defer { lastAttention = now }
        guard let before = lastAttention, paused == nil else { return [] }
        let new = now.subtracting(before).sorted(by: { $0.rawValue < $1.rawValue }).filter { !reportedByWatchdog($0) }
        for id in new {
            notifier?.send(.attention, key: "attention \(id)", title: "\(id.title) needs your attention",
                           body: state(id).detail ?? "Open Orbit to see why.", page: .health, every: 6 * 3600) { [weak self] in
                self?.fix(id)
            }
        }
        return new
    }

    func reportedByWatchdog(_ id: FeatureID) -> Bool {
        switch id {
        case .tiling: !keepsStopping.isDisjoint(with: [Helper.yabai, .skhd])
        case .glow: keepsStopping.contains(.borders)
        case .menuBar: keepsStopping.contains(.sketchybar)
        default: false
        }
    }

    /// The change behind a feature's switch: its busy key, its title in the history, and the work.
    func featureChange(_ id: FeatureID, on: Bool) -> (key: String, title: String, work: Work)? {
        guard id.isSwitchable else { return nil }
        return (id == .capsLock ? "keyboard" : id.rawValue, "Turned \(on ? "on" : "off") \(id.inSentence)", { [actions] in
            try await actions.setFeature(id, on: on, policy: $0)
        })
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
            showPalette()
            return OrbitReply(ok: true, message: "Opened the command palette.")
        }
    }
}
