import AppKit
import OrbitCore
import OrbitPlatform
import QuartzCore
import SwiftUI

/// Things the guided setup can switch on.
enum SetupChoice: String, CaseIterable, Identifiable {
    case theme, tiling, glow, menuBar, capsLock, downloads, dock, finder, raycast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .theme: "One look everywhere"
        case .tiling: "Windows that arrange themselves"
        case .glow: "A glow on the active window"
        case .menuBar: "A floating menu bar"
        case .capsLock: "Caps Lock superpowers"
        case .downloads: "Downloads that tidy themselves"
        case .dock: "A tidy Dock"
        case .finder: "A smarter Finder"
        case .raycast: "Raycast at login"
        }
    }

    var symbol: String {
        switch self {
        case .theme: "paintpalette.fill"
        case .tiling: FeatureID.tiling.symbol
        case .glow: FeatureID.glow.symbol
        case .menuBar: FeatureID.menuBar.symbol
        case .capsLock: FeatureID.capsLock.symbol
        case .downloads: FeatureID.downloads.symbol
        case .dock: "dock.rectangle"
        case .finder: "folder.fill"
        case .raycast: "magnifyingglass"
        }
    }

    var hue: Hue {
        switch self {
        case .theme: .pink
        case .tiling: .cyan
        case .glow: .purple
        case .menuBar: .indigo
        case .capsLock: .orange
        case .downloads: .teal
        case .dock: .blue
        case .finder: .cyan
        case .raycast: .red
        }
    }

    var blurb: String {
        switch self {
        case .theme: "The glow, the menu bar and the terminal share your favourite colours."
        case .tiling: "New windows share the screen side by side."
        case .glow: "Always see which window you're typing in."
        case .menuBar: "Desktops, music and live stats in a sleek bar."
        case .capsLock: "Tap for Escape, hold + a letter to open an app."
        case .downloads: "Files sort themselves into folders every hour."
        case .dock: "Your 11 everyday apps, hiding until you need it."
        case .finder: "Path bar, list view, folders first."
        case .raycast: "The fast keyboard launcher starts with your Mac."
        }
    }

    /// What changes, in plain words, for the review step.
    var changes: String {
        switch self {
        case .theme: "Colours for the glow, menu bar and terminal tools"
        case .tiling: "Starts window tiling and its keyboard shortcuts"
        case .glow: "Starts the window glow"
        case .menuBar: "Starts the new menu bar and lets the Mac's own one hide until you point at the top"
        case .capsLock: "Installs Karabiner-Elements (macOS asks for your password) and sets up Caps Lock"
        case .downloads: "Sorts Downloads every hour"
        case .dock: "Replaces the Dock's apps and makes it hide until you point at it"
        case .finder: "Shows the path bar and status bar, lists folders first"
        case .raycast: "Adds Raycast to the apps that open at login"
        }
    }
}

struct SetupTask: Identifiable {
    enum State: Equatable { case waiting, running, done, failed(String) }
    let id: SetupChoice
    var state: State = .waiting
}

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var choices: Set<SetupChoice> = Set(SetupChoice.allCases)
    @State private var theme: ThemeID = .tokyoNight
    @State private var tasks: [SetupTask] = []
    @State private var applying = false
    @State private var celebrate = false

    let titles = ["Welcome", "Choose", "Review", "Set up", "Allow", "Done"]

    var body: some View {
        ZStack {
            AuroraBackground(palette: Palette.named(theme))
            VStack(spacing: 0) {
                Group {
                    switch step {
                    case 0: welcome
                    case 1: choose
                    case 2: review
                    case 3: apply
                    case 4: permissions
                    default: done
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(Motion.transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                          removal: .move(edge: .leading).combined(with: .opacity))))
                footer
            }
            if celebrate, !Motion.reduced { Confetti().allowsHitTesting(false) }
        }
        .frame(width: 880, height: 700)
        .onAppear { theme = model.settings.theme }
        // A hand-edited file found during setup asks here, on top of the setup sheet.
        .sheet(item: Binding(get: { model.conflict }, set: { model.conflict = $0 })) { conflict in
            ConflictSheet(conflict: conflict).environment(model)
        }
    }

    // MARK: Steps

    var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            OrbitLogo(size: 110)
            Text("Welcome to Orbit").font(.system(size: 40, weight: .bold, design: .rounded))
            Text("Let's make your Mac look amazing and work the way you do.\nIt takes about two minutes, and everything can be undone.")
                .multilineTextAlignment(.center)
                .font(.title3)
                .foregroundStyle(.secondary)
            if model.isPractice {
                Label("Practice mode: nothing on your Mac will change.", systemImage: "graduationcap.fill").foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(40)
    }

    var choose: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What would you like?").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Everything is picked already. Untick anything you'd rather skip.").foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(SetupChoice.allCases) { choice in
                        let on = choices.contains(choice)
                        Button {
                            if on { choices.remove(choice) } else { choices.insert(choice) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                IconTile(symbol: choice.symbol, hue: on ? choice.hue : .gray, size: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(choice.title).font(.headline).foregroundStyle(.primary)
                                    Text(choice.blurb).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(on ? choice.hue.top : .secondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .glassEffect(on ? .regular.tint(choice.hue.top.opacity(0.25)).interactive() : .regular.interactive(),
                                     in: .rect(cornerRadius: 16))
                        .accessibilityLabel("\(choice.title), \(on ? "selected" : "not selected")")
                    }
                }
                if choices.contains(.theme) {
                    Text("Theme").font(.headline).padding(.top, 8)
                    HStack(spacing: 10) {
                        ForEach(Palette.all) { p in
                            Button { theme = p.id } label: {
                                VStack(spacing: 6) {
                                    Circle()
                                        .fill(LinearGradient(colors: [Color(p.accent), Color(p.accent2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 36, height: 36)
                                        .overlay(Circle().stroke(.white, lineWidth: theme == p.id ? 3 : 0))
                                        .shadow(color: Color(p.accent).opacity(theme == p.id ? 0.8 : 0), radius: 8)
                                    Text(p.name).font(.caption).foregroundStyle(theme == p.id ? .primary : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .padding(32)
    }

    var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Here's what will change").font(.system(size: 28, weight: .bold, design: .rounded))
            GlassPanel {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(SetupChoice.allCases.filter(choices.contains)) { choice in
                        Label {
                            Text(choice == .theme ? "\(choice.changes) (\(Palette.named(theme).name))" : choice.changes)
                        } icon: {
                            Image(systemName: choice.symbol).foregroundStyle(choice.hue.top)
                        }
                    }
                }
            }
            Label("A backup of everything is saved first. You can undo any of it on the Health page.",
                  systemImage: "lifepreserver.fill")
                .foregroundStyle(.secondary)
            if choices.contains(.capsLock) && model.state(.capsLock) == .notInstalled {
                Label("macOS will ask for your Mac password once, to install the Caps Lock helper.", systemImage: "lock.fill")
                    .foregroundStyle(.orange)
            }
            if choices.contains(.menuBar) || choices.contains(.raycast) {
                Label("macOS may ask \"Orbit wants to control System Events\". Click OK: it's how Orbit tucks the old menu bar away.",
                      systemImage: "hand.raised.fill")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(32)
    }

    var apply: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(applying ? "Setting things up…" : "All done here").font(.system(size: 28, weight: .bold, design: .rounded))
            GlassPanel {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(tasks) { task in
                        HStack(spacing: 12) {
                            Group {
                                switch task.state {
                                case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                                case .running: ProgressView().controlSize(.small)
                                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                }
                            }
                            .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(task.id.title)
                                if case .failed(let why) = task.state { Text(why).font(.caption).foregroundStyle(.orange) }
                                if task.id == .capsLock, task.state == .running, let text = karabinerText {
                                    Text(text).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .animation(Motion.animation(.spring(duration: 0.3)), value: task.state)
                    }
                }
            }
            Spacer()
        }
        .padding(32)
        .task { if tasks.isEmpty { await runTasks() } }
    }

    var karabinerText: String? {
        switch model.karabinerStep {
        case .downloading: "Downloading…"
        case .checking: "Checking the installer is genuine…"
        case .waitingForPassword: "Type your Mac password in the window macOS opened."
        case .installing: "Installing…"
        case .finishing: "Opening Karabiner…"
        default: nil
        }
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A few quick OKs").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("macOS protects your keyboard and screen, so it asks you before helpers can use them. Each row turns green by itself once allowed.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(permissionRows, id: \.title) { row in
                        GlassPanel(padding: 14, radius: 16, glow: row.done ? .green : nil) {
                            HStack(spacing: 12) {
                                Image(systemName: row.done ? "checkmark.circle.fill" : "hand.raised.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(row.done ? .green : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title).font(.headline)
                                    Text(row.how).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if !row.done, let action = row.action {
                                    Button(row.button, action: action).buttonStyle(.glassProminent)
                                }
                            }
                        }
                    }
                    if permissionRows.isEmpty {
                        Label("Nothing needs your OK. Lovely!", systemImage: "checkmark.seal.fill").font(.title3).foregroundStyle(.green)
                    }
                }
            }
        }
        .padding(32)
        .task {
            while !Task.isCancelled, step == 4 {
                await model.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    struct PermissionRow {
        let title: String
        let how: String
        let done: Bool
        let button: String
        let action: (() -> Void)?
    }

    var permissionRows: [PermissionRow] {
        var rows: [PermissionRow] = []
        let tiling = model.state(.tiling)
        if choices.contains(.tiling) {
            if model.status.tiling.backgroundBlocked {
                rows.append(PermissionRow(title: "Let window tiling run in the background",
                                          how: "In Login Items & Extensions, under Allow in the Background, switch on yabai and skhd.",
                                          done: false, button: "Open Settings") { model.openSettings(.loginItems, fixingTiling: true) })
            }
            rows.append(PermissionRow(title: "Let window tiling move windows",
                                      how: "In Privacy & Security → Accessibility, switch on yabai and skhd.",
                                      done: tiling.isOn, button: "Open Settings") { model.openSettings(.accessibility, fixingTiling: true) })
        }
        if choices.contains(.capsLock), model.state(.capsLock) != .notInstalled {
            rows.append(PermissionRow(title: "Allow the Caps Lock keyboard driver",
                                      how: "Karabiner shows a guide: allow its driver in Login Items & Extensions, and Input Monitoring for its two helpers.",
                                      done: model.status.keyboard.driver == .enabled, button: "Open Settings") { model.openSettings(.loginItems) })
        }
        if choices.contains(.downloads), case .needsPermission = model.state(.downloads) {
            rows.append(PermissionRow(title: "Let the sorter open Downloads",
                                      how: "Press Sort now, then click Allow when macOS asks about \"Downloads Sorter\".",
                                      done: false, button: "Sort now") { model.sortDownloadsNow() })
        }
        for app in ManagedApp.all where app.id == .altTab || app.id == .ice {
            if model.status.apps[app.id]?.installed == true {
                rows.append(PermissionRow(title: "Allow \(app.name)",
                                          how: "Open \(app.name) and follow its steps: switch it on under Accessibility and Screen Recording.",
                                          done: false, button: "Open \(app.name)") { model.open(app) })
            }
        }
        if let syntax = ManagedApp.all.first(where: { $0.id == .syntaxHighlight }),
           case .needsPermission = model.state(.syntaxHighlight) {
            rows.append(PermissionRow(title: "Turn on coloured code previews",
                                      how: "Open Syntax Highlight once so macOS starts using it.",
                                      done: false, button: "Open it") { model.open(syntax) })
        }
        return rows
    }

    var done: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 64)).foregroundStyle(Hue.pink.gradient)
            Text("Your Mac is ready").font(.system(size: 40, weight: .bold, design: .rounded))
            VStack(alignment: .leading, spacing: 10) {
                tip("keyboard", "Press ⌥ / any time to see every window shortcut.")
                tip("capslock.fill", "Tap Caps Lock for Escape; hold it + T for Warp, B for Chrome, O for Orbit.")
                tip("menubar.rectangle", "Click the Apple logo in the new bar for Orbit's quick panel.")
            }
            .padding(20)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            Spacer()
        }
        .padding(40)
        .onAppear {
            celebrate = true
            model.completeSetupFlag()
        }
    }

    func tip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.title3)
    }

    var footer: some View {
        HStack {
            // Esc closes the guide like "Not now" (it stays in the toolbar), but not while it's setting
            // things up. A key equivalent works wherever the keyboard focus is.
            Button("Close the guide") {
                model.completeSetup()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(applying)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            if step > 0 && step < 3 {
                Button("Back") { withAnimation(Motion.animation(.spring(duration: 0.4))) { step -= 1 } }.buttonStyle(.glass)
            } else if step == 0 {
                Button("Not now") {
                    model.completeSetup()
                    dismiss()
                }
                .buttonStyle(.glass)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<titles.count, id: \.self) { i in
                    Capsule().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: i == step ? 22 : 7, height: 7)
                }
            }
            .animation(Motion.animation(.spring(duration: 0.3)), value: step)
            .accessibilityLabel("Step \(step + 1) of \(titles.count): \(titles[step])")
            Spacer()
            Button(nextTitle) { next() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled((step == 1 && choices.isEmpty) || (step == 3 && applying))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    var nextTitle: String {
        switch step {
        case 0: "Let's go"
        case 2: "Set it up"
        case 5: "Start using Orbit"
        default: "Continue"
        }
    }

    func next() {
        if step == 5 {
            model.completeSetup()
            dismiss()
            return
        }
        withAnimation(Motion.animation(.spring(duration: 0.45))) { step += 1 }
    }

    // MARK: Running the setup

    func runTasks() async {
        applying = true
        let order: [SetupChoice] = [.theme, .tiling, .glow, .menuBar, .downloads, .dock, .finder, .raycast, .capsLock]
        tasks = order.filter(choices.contains).map { SetupTask(id: $0) }
        for index in tasks.indices {
            tasks[index].state = .running
            let result = await run(tasks[index].id)
            tasks[index].state = result.ok ? .done : .failed(result.message)
        }
        applying = false
        try? await Task.sleep(for: .milliseconds(600))
        withAnimation(Motion.animation(.spring(duration: 0.45))) { step = 4 }
    }

    func run(_ choice: SetupChoice) async -> (ok: Bool, message: String) {
        let actions = model.actions
        let home = model.ctx.paths.home
        switch choice {
        case .theme:
            let id = theme
            let tmux = model.settings.themeTmux
            return await model.performNow("theme", "Switched to the \(Palette.named(id).name) theme", quiet: true) {
                try await actions.applyTheme(id, tmux: tmux, policy: $0)
            }
        case .tiling:
            return await model.performNow("tiling", "Turned on window tiling", quiet: true) { try await actions.setTiling(true, policy: $0) }
        case .glow:
            return await model.performNow("glow", "Turned on the window glow", quiet: true) { try await actions.setGlow(true, policy: $0) }
        case .menuBar:
            return await model.performNow("menuBar", "Turned on the new menu bar", quiet: true) { try await actions.setMenuBar(true, policy: $0) }
        case .downloads:
            return await model.performNow("downloads", "Turned on Downloads sorting", quiet: true) { _ in await actions.setDownloads(true) }
        case .dock:
            let changes = DockPreset.changes(home: home)
            return await model.performNow("dock", "Tidied the Dock", quiet: true) { _ in
                await actions.setPreferences(changes, message: "The Dock is tidy.")
            }
        case .finder:
            return await model.performNow("finder", "Made Finder smarter", quiet: true) { _ in
                await actions.setPreferences(DockPreset.finder, message: "Finder is set up.")
            }
        case .raycast:
            guard let raycast = ManagedApp.all.first(where: { $0.id == .raycast }) else { return (false, "Raycast isn't installed.") }
            let login = await model.performNow("raycast", "Raycast opens at login", quiet: true) { _ in await actions.setLoginItem(raycast, on: true) }
            _ = await model.performNow("raycastOpen", "Opened Raycast", quiet: true) { _ in await actions.open(raycast) }
            return login
        case .capsLock:
            if model.state(.capsLock) == .notInstalled {
                let ok = await model.installKarabinerNow()
                if case .failed(let why) = model.karabinerStep { return (false, why) }
                return (ok, ok ? "" : "Karabiner isn't ready yet.")
            }
            var keyboard = model.settings.keyboard
            keyboard.capsLockEnabled = true
            let settled = keyboard
            return await model.performNow("keyboard", "Turned on Caps Lock superpowers", quiet: true) { _ in try await actions.applyKeyboard(settled) }
        }
    }
}

extension AppModel {
    /// Marks setup as finished without closing the window (the last step still shows).
    func completeSetupFlag() {
        ctx.store.updateSettings { $0.setupCompleted = true }
        settings = ctx.store.settings
    }
}

/// A short burst of confetti in the theme's colours.
struct Confetti: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        DispatchQueue.main.async {
            let emitter = CAEmitterLayer()
            emitter.emitterPosition = CGPoint(x: view.bounds.midX, y: view.bounds.maxY + 10)
            emitter.emitterShape = .line
            emitter.emitterSize = CGSize(width: view.bounds.width, height: 1)
            let colors: [NSColor] = [.systemPink, .systemPurple, .systemBlue, .systemTeal, .systemYellow, .systemOrange]
            emitter.emitterCells = colors.map { color in
                let cell = CAEmitterCell()
                cell.birthRate = 9
                cell.lifetime = 5
                cell.velocity = 260
                cell.velocityRange = 120
                cell.emissionLongitude = -.pi / 2
                cell.emissionRange = .pi / 5
                cell.yAcceleration = -260
                cell.spin = 3
                cell.spinRange = 4
                cell.scale = 0.6
                cell.scaleRange = 0.3
                cell.color = color.cgColor
                cell.contents = Confetti.piece
                return cell
            }
            view.layer?.addSublayer(emitter)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { emitter.birthRate = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { emitter.removeFromSuperlayer() }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static let piece: CGImage? = {
        let size = 12
        guard let ctx = CGContext(data: nil, width: size, height: size / 2, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size / 2))
        return ctx.makeImage()
    }()
}
