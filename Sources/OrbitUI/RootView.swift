import OrbitCore
import OrbitPlatform
import SwiftUI

extension FeatureID {
    var title: String {
        switch self {
        case .tiling: "Window tiling"
        case .glow: "Window glow"
        case .menuBar: "New menu bar"
        case .capsLock: "Caps Lock superpowers"
        case .downloads: "Auto-sort Downloads"
        case .raycast: "Raycast"
        case .altTab: "AltTab"
        case .ice: "Ice"
        case .syntaxHighlight: "Syntax Highlight"
        case .terminalLook: "Terminal colours"
        }
    }

    var blurb: String {
        switch self {
        case .tiling: "Windows arrange themselves side by side."
        case .glow: "A soft outline on the window you're using."
        case .menuBar: "A sleek floating bar with live stats."
        case .capsLock: "Tap for Escape, hold + a letter to open an app."
        case .downloads: "Downloads tidy themselves every hour."
        case .raycast: "Find and open anything from the keyboard."
        case .altTab: "⌘Tab with live window previews."
        case .ice: "Tucks menu bar icons out of the way."
        case .syntaxHighlight: "Coloured previews of code files in Finder."
        case .terminalLook: "Matching colours in your terminal tools."
        }
    }

    var shortTitle: String {
        switch self {
        case .tiling: "Tiling"
        case .glow: "Glow"
        case .menuBar: "Menu bar"
        case .capsLock: "Caps Lock"
        case .downloads: "Auto-sort"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .tiling: "rectangle.split.3x1.fill"
        case .glow: "sparkles.rectangle.stack.fill"
        case .menuBar: "menubar.rectangle"
        case .capsLock: "capslock.fill"
        case .downloads: "arrow.down.doc.fill"
        case .raycast: "magnifyingglass"
        case .altTab: "rectangle.on.rectangle"
        case .ice: "menubar.dock.rectangle"
        case .syntaxHighlight: "chevron.left.forwardslash.chevron.right"
        case .terminalLook: "terminal.fill"
        }
    }

    var hue: Hue {
        switch self {
        case .tiling: .cyan
        case .glow: .purple
        case .menuBar: .indigo
        case .capsLock: .orange
        case .downloads: .teal
        case .raycast: .red
        case .altTab: .blue
        case .ice: .cyan
        case .syntaxHighlight: .green
        case .terminalLook: .gray
        }
    }

    var page: Page {
        switch self {
        case .tiling, .glow: .windows
        case .menuBar: .menuBar
        case .capsLock: .keyboard
        case .downloads: .files
        case .raycast, .altTab, .ice, .syntaxHighlight: .apps
        case .terminalLook: .style
        }
    }
}

public struct RootView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    public init() {}

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 214, ideal: 236, max: 290)
        } detail: {
            ZStack(alignment: .bottom) {
                AuroraBackground(palette: model.palette)
                ScrollView {
                    Group {
                        if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                            PageView(page: model.page).id(model.page)
                        } else {
                            SearchResultsView()
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 26)
                    .frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
                if let toast = model.toast {
                    ToastView(toast: toast,
                              undo: toast.journalID.map { id in { model.undo(id) } },
                              dismiss: { withAnimation { model.toast = nil } })
                        .padding(.bottom, 24)
                        .transition(Motion.transition(.move(edge: .bottom).combined(with: .opacity)))
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.isPractice {
                        Label("Practice mode", systemImage: "graduationcap.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.orange)
                            .help("Nothing on your Mac changes. Changes are listed on the Health page.")
                    }
                    Button { model.showSetup = true } label: { Label("Guided setup", systemImage: "wand.and.stars") }
                        .help("Run the guided setup again")
                    Button { Task { await model.refresh() } } label: { Label("Check again", systemImage: "arrow.clockwise") }
                        .help("Check everything again")
                }
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: Text("Search Orbit  ⌘F"))
        .searchFocused($searchFocused)
        .onSubmit(of: .search) {
            let results = SearchIndex.results(for: model.searchText, in: SearchIndex.entries(modes: model.settings.modes))
            if let first = results.first { model.open(first) }
        }
        .onChange(of: model.searchRequest) { searchFocused = true }
        .sheet(isPresented: $model.showSetup) {
            SetupView().environment(model)
        }
        .sheet(item: $model.conflict) { conflict in
            ConflictSheet(conflict: conflict).environment(model)
        }
        .alert(Text("Undo “\(model.undoQuestion?.entry.title ?? "")”?"),
               isPresented: Binding(get: { model.undoQuestion != nil }, set: { if !$0 { model.undoQuestion = nil } }),
               presenting: model.undoQuestion) { question in
            Button("Undo Anyway", role: .destructive) { model.undo(question.entry.id, evenIfOvertaken: true) }
            Button("Cancel", role: .cancel) {}
        } message: { question in
            let later = question.later.map { "“\($0.title)”" }.joined(separator: ", ")
            Text("Since then, \(later) changed some of the same things. Undoing this now also undoes that part of \(question.later.count == 1 ? "it" : "them").")
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding<Page?>(get: { model.page }, set: { if let page = $0 { model.page = page } })
        List(selection: selection) {
            HStack(spacing: 10) {
                OrbitLogo(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Orbit").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Your Mac, your way").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .selectionDisabled()
            ForEach(["", "Look", "Control", "System", "Care"], id: \.self) { group in
                Section(group) {
                    ForEach(Page.allCases.filter { $0.group == group }) { page in
                        row(page).tag(page)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    func row(_ page: Page) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: page.symbol, hue: page.hue, size: 24)
            Text(page.title)
            Spacer()
            let issues = model.attention.filter { $0.page == page }.count
            if issues > 0 {
                Text("\(issues)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.orange, in: Capsule())
                    .accessibilityLabel("\(issues) need attention")
            }
        }
        .padding(.vertical, 2)
    }
}

struct PageView: View {
    let page: Page

    var body: some View {
        switch page {
        case .home: HomePage()
        case .style: StylePage()
        case .windows: WindowsPage()
        case .menuBar: MenuBarPage()
        case .keyboard: KeyboardPage()
        case .files: FilesPage()
        case .modes: ModesPage()
        case .monitor: MonitorPage()
        case .cleanup: CleanupPage()
        case .dockFinder: DockFinderPage()
        case .apps: AppsPage()
        case .health: HealthPage()
        }
    }
}

extension AppModel {
    /// orbit://panel, orbit://page/windows, orbit://setup
    func handle(_ url: URL) {
        guard url.scheme == "orbit" || url.scheme == "orbitdev" else { return }
        switch url.host() {
        case "page":
            if let page = Page(rawValue: url.lastPathComponent) { self.page = page }
        case "setup":
            showSetup = true
        case "panel":
            if let openWindow {
                openWindow(id: "panel")
            } else {
                openMainWindow()
            }
        default:
            // Not something to show: Orbit stays where it is.
            return
        }
        NSApp.activate()
    }

    /// Flips a feature from a quick switch, or sends the user where they can fix it.
    func toggle(_ id: FeatureID) {
        let state = state(id)
        if state.needsAttention { return fix(id) }
        if state == .notInstalled { page = id.page; return }
        let on = !state.isOn
        switch id {
        case .tiling: setTiling(on)
        case .glow: setGlow(on)
        case .menuBar: setMenuBar(on)
        case .capsLock:
            var keyboard = settings.keyboard
            keyboard.capsLockEnabled = on
            applyKeyboard(keyboard)
        case .downloads: setDownloads(on)
        case .terminalLook: applyTheme(settings.theme)
        case .raycast, .altTab, .ice, .syntaxHighlight:
            if let app = ManagedApp.all.first(where: { $0.id == id }) { open(app) }
        }
    }
}
