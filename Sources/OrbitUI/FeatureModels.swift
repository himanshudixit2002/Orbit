import AppKit
import Observation
import OrbitCore
import OrbitPlatform
import SwiftUI

/// Live system readings, sampled every two seconds only while something on screen shows them.
@Observable
final class MonitorModel {
    var latest = SystemSample()
    var history: [SystemSample] = []
    private let sampler = StatsSampler()
    private var task: Task<Void, Never>?
    private var watchers = 0
    static let historyLength = 60

    func startWatching() {
        watchers += 1
        guard task == nil else { return }
        task = Task { [weak self, sampler] in
            while !Task.isCancelled {
                let sample = await Task.detached { sampler.sample() }.value
                guard let self else { return }
                self.latest = sample
                self.history.append(sample)
                if self.history.count > Self.historyLength { self.history.removeFirst(self.history.count - Self.historyLength) }
                try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(300))
            }
        }
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        if watchers == 0 {
            task?.cancel()
            task = nil
        }
    }

    /// For snapshots and previews: a believable, steady reading.
    func fill(with sample: SystemSample) {
        latest = sample
        history = (0..<Self.historyLength).map { i in
            var s = sample
            let wave = sin(Double(i) / 5) * 0.12 + sin(Double(i) / 2.3) * 0.05
            s.cpu = max(0.02, min(1, sample.cpu + wave))
            s.download = max(0, sample.download * (1 + wave * 4))
            s.upload = max(0, sample.upload * (1 - wave * 3))
            return s
        }
    }
}

@Observable
final class ModesModel {
    let ctx: SystemContext
    @ObservationIgnored lazy var engine = ModeEngine(ctx: ctx)
    var active: ModeRecord?
    var working: String?
    /// Told when a mode goes on or off.
    @ObservationIgnored var changed: (() -> Void)?

    init(ctx: SystemContext) {
        self.ctx = ctx
        // A mode left on when Orbit last quit is still on, so switching it off can still put things back.
        active = ctx.store.activeMode
    }

    /// Keeps the Mac awake again for a mode that was on when Orbit last quit (the hold ended with Orbit).
    func resume() {
        guard let active, let mode = ctx.store.settings.modes.first(where: { $0.id == active.modeID }) else { return }
        engine.setKeepAwake(mode.keepAwake, reason: "Orbit \(mode.name) mode")
    }

    func name(_ record: ModeRecord) -> String {
        ctx.store.settings.modes.first { $0.id == record.modeID }?.name ?? record.modeID.capitalizedFirst
    }

    func toggle(_ mode: ModeDefinition) async {
        // One mode change at a time: another one mid-way would lose this one's record of what to put back.
        guard working == nil else { return }
        working = mode.id
        defer { working = nil }
        // Through the change lane: a mode switches tiling and apps, which other changes also touch.
        if let current = active {
            await switchOff(current)
            if current.modeID == mode.id { return }
        }
        // Saved as soon as it's on, so it outlives Orbit quitting.
        active = await ctx.lane.run("\(mode.name) mode") { [engine, store = ctx.store] in
            let record = await engine.apply(mode)
            store.setActiveMode(record)
            return record
        }
        ctx.activity.record(ActivityRecord(.change, "Switched on \(mode.name) mode"))
        changed?()
    }

    func stop() async {
        guard working == nil, let current = active else { return }
        working = current.modeID
        defer { working = nil }
        await switchOff(current)
    }

    private func switchOff(_ current: ModeRecord) async {
        let name = name(current)
        await ctx.lane.run("Switch off \(name) mode") { [engine, store = ctx.store] in
            await engine.revert(current)
            store.setActiveMode(nil)
        }
        active = nil
        ctx.activity.record(ActivityRecord(.change, "Switched off \(name) mode"))
        changed?()
    }
}

@Observable
final class CleanupModel {
    let ctx: SystemContext
    var items: [CleanupItem] = []
    var scanning = false
    var scannedAt: Date?
    var trashSize: Int64 = 0
    var trashed: Set<String> = []

    init(ctx: SystemContext) { self.ctx = ctx }

    var total: Int64 { items.filter { !trashed.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan(includeDownloads: Bool) async {
        scanning = true
        let scanner = CleanupScanner(ctx)
        items = await scanner.scan(includeDownloads: includeDownloads)
        trashSize = await Task.detached { scanner.trashSize() }.value
        trashed = []
        scannedAt = Date()
        scanning = false
    }
}

extension AppModel {
    // MARK: Style

    func applyTheme(_ id: ThemeID) {
        let change = themeChange(id)
        settings.theme = id
        perform("theme", change.title, change.work)
        if settings.wallpaperFollowsTheme { setThemeWallpaper(Palette.named(id)) }
    }

    func setTmuxTheme(_ on: Bool) {
        settings.themeTmux = on
        if on {
            applyTheme(settings.theme)
        } else {
            perform("tmux", "Stopped theming tmux") { [actions] _ in try await actions.removeTmuxTheme() }
        }
    }

    func setWallpaperFollowsTheme(_ on: Bool) {
        ctx.store.updateSettings { $0.wallpaperFollowsTheme = on }
        settings = ctx.store.settings
        if on { setThemeWallpaper(palette) } else { restoreOriginalWallpaper() }
    }

    /// Draws the theme's wallpaper at each screen's full resolution and shows it.
    func setThemeWallpaper(_ p: Palette) {
        let practice = isPractice
        let folder = practice ? ctx.paths.practiceRoot.appending(path: "Wallpapers") : ctx.paths.wallpapers
        for screen in NSScreen.screens {
            let width = Int(screen.frame.width * screen.backingScaleFactor)
            let height = Int(screen.frame.height * screen.backingScaleFactor)
            Task {
                do {
                    let url = try await Task.detached { try WallpaperRenderer.file(p, width: width, height: height, folder: folder) }.value
                    if practice {
                        ctx.practiceLog.record("Would set the \(p.name) wallpaper", url.path(percentEncoded: false))
                        practiceLog = ctx.practiceLog.all
                    } else {
                        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true
                        ])
                    }
                } catch {
                    show(Toast(ok: false, message: "Couldn't set the wallpaper: \(error.localizedDescription)", journalID: nil))
                }
            }
        }
    }

    func restoreOriginalWallpaper() {
        guard let path = ctx.store.baseline?.wallpaper, !isPractice else { return }
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
        }
    }

    /// macOS sets wallpapers one desktop at a time, so each desktop gets the theme when you first visit it.
    func spaceChanged() {
        guard settings.wallpaperFollowsTheme, !isPractice, let screen = NSScreen.main,
              let current = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        let name = current.lastPathComponent
        let wanted = WallpaperRenderer.fileName(palette, width: Int(screen.frame.width * screen.backingScaleFactor),
                                                height: Int(screen.frame.height * screen.backingScaleFactor))
        let original = ctx.store.baseline?.wallpaper
        if name != wanted, name.hasPrefix("orbit-") || current.path(percentEncoded: false) == original {
            setThemeWallpaper(palette)
        }
    }

    // MARK: Keyboard

    func applyKeyboard(_ keyboard: KeyboardSettings) {
        settings.keyboard = keyboard
        perform("keyboard", keyboard.capsLockEnabled ? "Changed Caps Lock shortcuts" : "Turned off Caps Lock superpowers") { [actions] _ in
            try await actions.applyKeyboard(keyboard)
        }
    }

    func installKarabiner() {
        Task { await installKarabinerNow() }
    }

    /// Installs Karabiner (macOS asks for the password), then writes the Caps Lock rules.
    func installKarabinerNow() async -> Bool {
        let installer = KarabinerInstaller(ctx: ctx)
        installer.onChange = { [weak self] step in self?.karabinerStep = step }
        await installer.install()
        var ok = false
        if case .done = installer.step {
            let keyboard = settings.keyboard
            ok = await performNow("keyboard", "Turned on Caps Lock superpowers", quiet: true) { [actions] _ in
                try await actions.applyKeyboard(keyboard)
            }.ok
        }
        await refresh()
        return ok
    }

    // MARK: Cleanup

    func trash(_ item: CleanupItem) {
        cleanup.trashed.insert(item.id)
        let scanner = CleanupScanner(ctx)
        perform("cleanup-\(item.id)", "Moved \(item.title.lowercased()) to the Trash") { _ in scanner.trash(item) }
    }
}

/// Asks for live readings only while the window showing them can actually be seen. A window behind
/// others, minimised or on another desktop stays "on screen" as far as SwiftUI's appear and
/// disappear go, and would otherwise keep sampling and redrawing every two seconds.
struct LiveStats: ViewModifier {
    let monitor: MonitorModel
    @State private var watching = false

    func body(content: Content) -> some View {
        content
            .background(WindowVisibility { set($0) })
            .onDisappear { set(false) }
    }

    private func set(_ on: Bool) {
        guard on != watching else { return }
        watching = on
        if on { monitor.startWatching() } else { monitor.stopWatching() }
    }
}

extension View {
    func liveStats(_ monitor: MonitorModel) -> some View { modifier(LiveStats(monitor: monitor)) }
}

/// Tells whether the window holding this view is visible: not covered, minimised or on another desktop.
struct WindowVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> Watcher { Watcher(changed: changed) }
    func updateNSView(_ watcher: Watcher, context: Context) { watcher.changed = changed }

    final class Watcher: NSView {
        var changed: (Bool) -> Void
        private var observer: NSObjectProtocol?

        init(changed: @escaping (Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        func report() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            // Told after AppKit's own update, so SwiftUI state doesn't change in the middle of one.
            Task { [weak self] in self?.changed(visible) }
        }
    }
}
