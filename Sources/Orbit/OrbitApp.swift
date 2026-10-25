import AppKit
import OrbitPlatform
import OrbitUI
import SwiftUI

@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppDelegate.model

    var body: some Scene {
        Window("Orbit", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 820)
        // Opened by the app delegate on a normal launch, never at login.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .textEditing) {
                Button("Search Orbit…") { model.focusSearch() }.keyboardShortcut("f")
            }
            CommandMenu("Orbit") {
                Button("Guided Setup…") { model.showSetup = true }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Check Everything Again") { Task { await model.refresh() } }.keyboardShortcut("r")
            }
        }

        Window("Orbit Quick Panel", id: "panel") {
            MenuBarPanel().environment(model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.topTrailing)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarPanel().environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let snapshotFolder: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-all"), args.count > i + 1 else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }()

    /// One model for the whole app. Snapshot runs get an inert one so nothing starts in the background.
    static let model: AppModel = snapshotFolder == nil
        ? AppModel.launch(mode: LaunchOptions.mode)
        : AppModel(ctx: SystemContext.make(mode: .practice))

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let folder = Self.snapshotFolder {
            let args = CommandLine.arguments
            let scenario = args.firstIndex(of: "--scenario").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } ?? "fresh"
            NSApp.windows.forEach { $0.orderOut(nil) }
            SnapshotHarness.run(to: folder, scenario: scenario)
            NSApp.terminate(nil)
            return
        }
        // Orbit lives in the menu bar: its Dock icon shows only while its main window is open.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // Looked at once the window has gone. A minimised one still needs the Dock to come back from.
            Task { @MainActor in
                let mainWindowOpen = NSApp.windows.contains { $0.title == "Orbit" && !($0 is NSPanel) && ($0.isVisible || $0.isMiniaturized) }
                if !mainWindowOpen { NSApp.setActivationPolicy(.accessory) }
            }
        }
        // Started at login, or in the background (`--background`, after an update): just the menu bar icon.
        // Started by a link: the link decides.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let quietly = launchedAtLogin || CommandLine.arguments.contains("--background")
        if !quietly, event == nil || event?.eventID == kAEOpenApplication || event?.eventID == kAEReopenApplication {
            Self.model.openMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A change cut off half done is worse than a quit that takes a moment: quitting waits for one under
    /// way, and gives the menu bar's numbers back to its own scripts.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.snapshotFolder == nil else { return .terminateNow }
        Task { @MainActor in
            await Self.model.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.model.openMainWindow() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { Self.model.open(url: $0) }
    }

    var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
