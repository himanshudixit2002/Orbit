import AppKit
import OrbitCore
import OrbitPlatform
import SwiftUI

/// How Orbit was started.
public enum LaunchOptions {
    /// Practice mode unless this is the installed app: dev builds and `--practice` never change the Mac.
    public static var mode: RunMode {
        let args = CommandLine.arguments
        if args.contains("--practice") { return .practice }
        if args.contains("--live") { return .live }
        guard let id = Bundle.main.bundleIdentifier, !id.hasSuffix(".dev") else { return .practice }
        return .live
    }
}

extension AppModel {
    /// Handles orbit:// links (see `OrbitLink` for the ones it knows; anything else is ignored).
    public func open(url: URL) {
        guard let command = OrbitLink.command(from: url) else { return }
        // The same link twice within a second is one request.
        let now = Date()
        if let last = lastLink, last.url == url, now.timeIntervalSince(last.at) < 1 { return }
        lastLink = (url, now)
        // A link without Orbit's own token (from a web page, say) asks before it changes anything.
        if !command.showsOrbit, OrbitLink.token(in: url) != ctx.store.linkToken, !confirmLink(command) { return }
        Task { await run(command, source: .link) }
    }

    /// Asks whether a link from outside Orbit may go ahead.
    static func askAboutLink(_ command: OrbitCommand) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Let a link \(command.summary)?"
        alert.informativeText = "A link asked Orbit to \(command.summary). The links on Orbit's Shortcuts page don't ask; links from anywhere else do, in case they're not yours."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Opens (or brings forward) the main window, with Orbit's Dock icon while it's open. Asked before
    /// Orbit can open windows (it's still starting), it opens as soon as it can.
    public func openMainWindow() {
        guard let openWindow else {
            mainWindowWanted = true
            return
        }
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate()
    }

    func windowOpenerReady(_ action: OpenWindowAction) {
        openWindow = action
        if mainWindowWanted {
            mainWindowWanted = false
            openMainWindow()
        }
    }
}

/// The Orbit icon in the macOS menu bar. Always on screen, so it also lends the model a way to open windows.
public struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        Image(systemName: model.attention.isEmpty ? "atom" : "exclamationmark.circle")
            .task { model.windowOpenerReady(openWindow) }
            .accessibilityLabel("Orbit")
    }
}

/// Renders every page to PNG files without clicking anything: `Orbit --snapshot-all <folder> [scenario]`.
@MainActor
public enum SnapshotHarness {
    public static func run(to folder: URL, scenario: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel(ctx: SystemContext.make(mode: .practice))
        model.isSnapshot = true
        model.status = status(for: scenario)
        var sample = SystemSample()
        sample.cpu = 0.23
        sample.perCore = [0.42, 0.31, 0.18, 0.55, 0.08, 0.12, 0.05, 0.1]
        sample.memoryUsed = 11_800_000_000
        sample.memoryTotal = 17_179_869_184
        sample.diskFree = 65_000_000_000
        sample.diskTotal = 245_000_000_000
        sample.download = 420_000
        sample.upload = 38_000
        model.monitor.fill(with: sample)
        if scenario == "all-on" || scenario == "paused" {
            model.modes.active = ModeRecord(modeID: "work")
        }
        if scenario == "paused" {
            model.paused = PausedState(features: PausePlan.order, instant: SpeedTweak.Group.allCases, modeID: "work",
                                       since: Date().addingTimeInterval(-25 * 60))
        }
        for (name, appearance) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
            for page in Page.allCases {
                model.page = page
                render(RootView().environment(model), size: CGSize(width: 1180, height: 820), appearance: appearance,
                       to: folder.appending(path: "\(scenario)-\(name)-\(page.rawValue).png"))
            }
            render(MenuBarPanel().environment(model), size: CGSize(width: 340, height: 430), appearance: appearance,
                   to: folder.appending(path: "\(scenario)-\(name)-panel.png"))
            render(SetupView().environment(model), size: CGSize(width: 880, height: 700), appearance: appearance,
                   to: folder.appending(path: "\(scenario)-\(name)-setup.png"))
            renderExtras(model, appearance: appearance, to: folder, prefix: "\(scenario)-\(name)")
        }
    }

    /// The sheets and search page, filled with believable content.
    static func renderExtras(_ model: AppModel, appearance: NSAppearance?, to folder: URL, prefix: String) {
        model.searchText = "dock"
        render(RootView().environment(model), size: CGSize(width: 1180, height: 820), appearance: appearance,
               to: folder.appending(path: "\(prefix)-search.png"))
        model.searchText = ""

        let current = YabaiConfig.render(model.settings, barReserved: 40)
        let edited = current
            .replacingOccurrences(of: "window_gap            10", with: "window_gap            4")
            .replacingOccurrences(of: "# Hold option", with: "# my own tweak\nyabai -m config window_opacity on\n\n# Hold option")
        let conflict = Conflict(file: .yabairc, proposed: current) {}
        render(ConflictPreview(conflict: conflict, onDisk: edited).environment(model), size: CGSize(width: 780, height: 640),
               appearance: appearance, to: folder.appending(path: "\(prefix)-conflict.png"))

        render(ModeEditor(mode: ModeDefinition.defaults[0], isNew: false).environment(model), size: CGSize(width: 740, height: 700),
               appearance: appearance, to: folder.appending(path: "\(prefix)-mode-editor.png"))

        let desktop = model.ctx.paths.desktop
        let plan = ["Note from ChatGPT.txt", "PORTFOLIO_PLAN.md", "Screenshot 2026-10-25.png", "trip.mov",
                    "open.spotify.com.webloc", "resume.pdf", "Toggle_Naukri_Bot.command"].map {
            TidyMove(source: desktop.appending(path: $0), destination: DesktopTidy.destination(for: $0))
        }
        render(TidyPlanSheet(plan: plan).environment(model), size: CGSize(width: 580, height: 560), appearance: appearance,
               to: folder.appending(path: "\(prefix)-tidy.png"))
    }

    static func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance?, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        defer { window.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func status(for scenario: String) -> SystemStatus {
        var s = SystemStatus()
        s.checkedAt = Date()
        s.tiling.installed = true
        s.glow.installed = true
        s.menuBar.installed = true
        s.downloads.installed = true
        s.downloads.run = .loaded(running: false, pid: nil, lastExit: 0)
        let now = Date()
        s.downloads.log.entries = [
            .init(date: now.addingTimeInterval(-3600), file: "HimanshuDixitResume.pdf", folder: "Documents"),
            .init(date: now.addingTimeInterval(-3500), file: "bug-hunter.zip", folder: "Archives"),
            .init(date: now.addingTimeInterval(-200), file: "screenshot-wallpaper.png", folder: "Images")
        ]
        for app in ManagedApp.all {
            var a = AppStatus()
            a.installed = true
            if app.quickLookExtension != nil { a.quickLook = .enabled }
            s.apps[app.id] = a
        }
        switch scenario {
        case "all-on":
            s.tiling.yabai = .loaded(running: true, pid: 1, lastExit: nil)
            s.tiling.skhd = .loaded(running: true, pid: 2, lastExit: nil)
            s.glow.run = .loaded(running: true, pid: 3, lastExit: nil)
            s.menuBar.run = .loaded(running: true, pid: 4, lastExit: nil)
            s.menuBar.macMenuBarHidden = true
            s.keyboard = KeyboardStatus()
            s.keyboard.installed = true
            s.keyboard.driver = .enabled
            s.keyboard.running = true
            s.keyboard.rulesActive = true
            s.terminalThemed = true
            for id in [FeatureID.raycast, .altTab, .ice] { s.apps[id]?.running = true }
        case "needs-permission":
            s.tiling.yabaiPlistExists = true
            s.tiling.problem = .notAllowedInBackground
            s.keyboard.installed = true
            s.keyboard.driver = .waitingForApproval
            s.downloads.log.lastError = .init(date: now, message: "cannot read Downloads")
            s.apps[.syntaxHighlight]?.quickLook = .notRegistered
        case "paused":
            s.terminalThemed = true
        default:
            s.glow.run = .loaded(running: true, pid: 3, lastExit: nil)
            s.terminalThemed = true
        }
        return s
    }
}
