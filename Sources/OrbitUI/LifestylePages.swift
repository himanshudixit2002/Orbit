import AppKit
import Charts
import OrbitCore
import OrbitPlatform
import SwiftUI

struct StylePage: View {
    @Environment(AppModel.self) private var model
    @State private var preview: NSImage?
    @State private var previewTheme: ThemeID?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(page: .style)
            GlassPanel(padding: 0, radius: 22, glow: Color(model.palette.accent)) {
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let preview {
                            Image(nsImage: preview).resizable().aspectRatio(16 / 9, contentMode: .fill)
                        } else {
                            Rectangle().fill(Color(model.palette.bgDark)).aspectRatio(16 / 9, contentMode: .fit)
                        }
                    }
                    .frame(maxHeight: 280)
                    .clipped()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.palette.name).font(.system(size: 28, weight: .bold, design: .rounded))
                        Text(model.palette.tagline).font(.title3)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .padding(22)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .task(id: model.settings.theme) { await renderPreview(model.settings.theme) }

            SectionTitle(text: "Pick a look")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                ForEach(Palette.all) { palette in
                    ThemeCard(palette: palette, selected: palette.id == model.settings.theme,
                              busy: model.isBusy("theme") && palette.id == model.settings.theme) {
                        model.applyTheme(palette.id)
                    }
                }
            }

            SectionTitle(text: "What the theme changes")
            GlassPanel {
                VStack(alignment: .leading, spacing: 12) {
                    SettingRow(title: "Window glow and menu bar", detail: "Always follow the theme") {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    SettingRow(title: "Terminal colours", detail: "Code, git diffs, btop, lazygit and the hi splash") {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    SettingRow(title: "Wallpaper", detail: "A fresh wallpaper drawn in the theme's colours. Off keeps yours.") {
                        Toggle("Wallpaper", isOn: Binding(get: { model.settings.wallpaperFollowsTheme },
                                                          set: { model.setWallpaperFollowsTheme($0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                    SettingRow(title: "tmux", detail: "Adds two lines to your ~/.tmux.conf (removed again if you switch this off)") {
                        Toggle("tmux", isOn: Binding(get: { model.settings.themeTmux }, set: { model.setTmuxTheme($0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        }
    }

    func renderPreview(_ id: ThemeID) async {
        let image = await Task.detached { WallpaperRenderer.render(Palette.named(id), width: 1280, height: 720) }.value
        guard let image else { return }
        withAnimation(.easeInOut(duration: 0.5)) {
            preview = NSImage(cgImage: image, size: NSSize(width: 1280, height: 720))
            previewTheme = id
        }
    }
}

struct ThemeCard: View {
    let palette: Palette
    let selected: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    LinearGradient(colors: [Color(palette.bg), Color(palette.bgDark)], startPoint: .top, endPoint: .bottom)
                    RadialGradient(colors: [Color(palette.accent, opacity: 0.7), .clear], center: .topLeading, startRadius: 0, endRadius: 140)
                    RadialGradient(colors: [Color(palette.accent2, opacity: 0.55), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 130)
                    HStack(spacing: 4) {
                        Circle().fill(Color(palette.accent)).frame(width: 6, height: 6)
                        Capsule().fill(Color(palette.fg).opacity(0.5)).frame(width: 30, height: 4)
                        Spacer()
                        Capsule().fill(Color(palette.green)).frame(width: 14, height: 4)
                    }
                    .padding(6)
                    .background(Color(palette.bgDark).opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
                    .padding(8)
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(palette.accent), lineWidth: 2)
                        .shadow(color: Color(palette.accent), radius: 5)
                        .frame(width: 92, height: 50)
                        .offset(x: 90, y: 42)
                }
                .frame(height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 5) {
                    ForEach([palette.accent, palette.accent2, palette.green, palette.yellow, palette.red, palette.cyan], id: \.self) {
                        Circle().fill(Color($0)).frame(width: 12, height: 12)
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    else if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(palette.accent)) }
                }
                Text(palette.name).font(.headline)
                Text(palette.tagline).font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(Color(palette.accent, opacity: 0.3)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 18))
        .shadow(color: selected ? Color(palette.accent).opacity(0.5) : .clear, radius: 14)
        .accessibilityLabel("\(palette.name) theme\(selected ? ", selected" : "")")
    }
}

struct FilesPage: View {
    @Environment(AppModel.self) private var model
    @State private var tidyPlan: [TidyMove]?
    @State private var showTidy = false
    @State private var lookingAtDesktop = false
    @State private var editingRules = false

    var log: SorterLog { model.status.downloads.log }

    var body: some View {
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(page: .files)
            FeatureCard(title: "Auto-sort Downloads",
                        blurb: model.settings.downloads.instant
                            ? "As soon as a download finishes, it goes into a folder by type: Documents, Images, Archives and more. An hourly pass catches anything Orbit misses."
                            : "Every hour, files you downloaded more than an hour ago go into folders by type: Documents, Images, Archives and more.",
                        symbol: FeatureID.downloads.symbol, hue: .teal, state: model.state(.downloads),
                        isBusy: model.isBusy("downloads"), illustration: AnyView(SortIllustration()),
                        onToggle: { model.setDownloads($0) }, onFix: { model.fix(.downloads) }) {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    HStack {
                        Label("\(log.sorted(since: weekAgo).count) files sorted this week", systemImage: "chart.bar.fill")
                        Spacer()
                        Button { model.sortDownloadsNow() } label: { Label("Sort now", systemImage: "wand.and.rays") }
                            .buttonStyle(.glass)
                            .disabled(model.isBusy("sortNow"))
                    }
                    SettingRow(title: "Sort as soon as they finish", detail: model.settings.downloads.instant
                               ? "Each download moves \(model.settings.downloads.settleSeconds) seconds after it stops changing, while Orbit runs."
                               : "Only the hourly pass, for files older than an hour.") {
                        HStack(spacing: 10) {
                            Button("Rules…") { editingRules = true }.buttonStyle(.glass)
                            Toggle("Instant", isOn: Binding(get: { model.settings.downloads.instant }, set: { on in
                                var downloads = model.settings.downloads
                                downloads.instant = on
                                model.applyDownloads(downloads)
                            }))
                            .toggleStyle(.switch).labelsHidden()
                        }
                    }
                    ForEach(Array(log.entries.suffix(5).reversed().enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 8) {
                            Image(systemName: icon(entry.folder)).foregroundStyle(Hue.teal.top).frame(width: 18)
                            Text(entry.file).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("→ \(entry.folder)").foregroundStyle(.secondary)
                            Text(entry.date, style: .relative).font(.caption).foregroundStyle(.tertiary)
                            Button("Put back") { model.putBack(entry) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .help("Move it back into Downloads, where neither sorter will move it again")
                        }
                        .font(.callout)
                    }
                }
            }

            GlassPanel {
                HStack(spacing: 14) {
                    IconTile(symbol: "desktopcomputer", hue: .blue, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tidy the Desktop").font(.title3.weight(.semibold))
                        Text("Loose files go into folders in Documents: notes, pictures and videos, web links, and everything else. Folders and apps stay put, and you see the list before anything moves.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button("Tidy now…") {
                        // Off the main thread: the first look makes macOS ask about the Desktop folder, and
                        // Orbit's window shouldn't freeze while it does.
                        lookingAtDesktop = true
                        Task {
                            tidyPlan = await Task.detached { [actions = model.actions] in actions.desktopTidyPlan() }.value
                            lookingAtDesktop = false
                            showTidy = true
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isBusy("tidyDesktop") || lookingAtDesktop)
                }
            }
            .sheet(isPresented: $editingRules) {
                DownloadRulesSheet().environment(model)
            }
            .sheet(isPresented: $showTidy) {
                TidyPlanSheet(plan: tidyPlan).environment(model)
            }

            SectionTitle(text: "Where your things live")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                PlaceCard(title: "Projects", detail: "Products, Systems, Career, Content, Learning", symbol: "hammer.fill", hue: .blue,
                          url: model.ctx.paths.developer)
                PlaceCard(title: "Documents", detail: "Notes, Media, Links and your files", symbol: "doc.fill", hue: .cyan,
                          url: model.ctx.paths.documents)
                PlaceCard(title: "Downloads", detail: "Sorted into folders by type", symbol: "arrow.down.circle.fill", hue: .teal,
                          url: model.ctx.paths.downloads)
                PlaceCard(title: "Backups", detail: "Everything Orbit saved before changing it", symbol: "clock.arrow.circlepath", hue: .purple,
                          url: model.ctx.store.root.appending(path: "Backups"))
            }
        }
    }

    func icon(_ folder: String) -> String {
        switch folder {
        case "Documents": "doc.fill"
        case "Images": "photo.fill"
        case "Archives": "archivebox.fill"
        case "Media": "film.fill"
        case "Installers": "shippingbox.fill"
        case "Code": "chevron.left.forwardslash.chevron.right"
        default: "doc"
        }
    }
}

struct PlaceCard: View {
    let title: String
    let detail: String
    let symbol: String
    let hue: Hue
    let url: URL

    var body: some View {
        GlassPanel(padding: 14, radius: 18) {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, hue: hue, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.glass)
            }
        }
    }
}

struct ModesPage: View {
    @Environment(AppModel.self) private var model
    @State private var editing: EditTarget?

    struct EditTarget: Identifiable {
        let mode: ModeDefinition
        let isNew: Bool

        var id: String { mode.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(page: .modes)
            if let active = model.modes.active, let mode = model.settings.modes.first(where: { $0.id == active.modeID }) {
                GlassPanel(glow: Hue.purple.top) {
                    HStack(spacing: 14) {
                        IconTile(symbol: mode.symbol, hue: .purple, size: 40)
                        VStack(alignment: .leading) {
                            Text("\(mode.name) mode is on").font(.headline)
                            Text("Since \(active.started.formatted(date: .omitted, time: .shortened)). Switching it off reopens anything it closed.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Switch off") { Task { await model.modes.stop() } }.buttonStyle(.glassProminent)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                ForEach(model.settings.modes) { mode in
                    ModeCard(mode: mode, active: model.modes.active?.modeID == mode.id, working: model.modes.working == mode.id,
                             onEdit: { editing = EditTarget(mode: mode, isNew: false) }) {
                        Task { await model.modes.toggle(mode) }
                    }
                }
                Button { editing = EditTarget(mode: .newCustom(), isNew: true) } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 40)).foregroundStyle(Hue.purple.gradient)
                        Text("New mode").font(.title3.weight(.semibold))
                        Text("Study, gaming, calls… set up your own.").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 230)
                    .contentShape(.rect(cornerRadius: 22))
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                .accessibilityLabel("Create a new mode")
            }
            Label("Modes never force an app to quit: apps get the usual chance to save. Keeping the Mac awake stops when Orbit quits.",
                  systemImage: "hand.raised.fill")
                .font(.callout).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { target in
            ModeEditor(mode: target.mode, isNew: target.isNew).environment(model)
        }
    }
}

struct ModeCard: View {
    let mode: ModeDefinition
    let active: Bool
    let working: Bool
    var onEdit: (() -> Void)?
    let action: () -> Void

    var hue: Hue { Self.hue(for: mode.id) }

    /// The built-in modes have fixed colours; new ones get a steady colour from their id.
    static func hue(for id: String) -> Hue {
        switch id {
        case "work": return .blue
        case "focus": return .purple
        case "chill": return .green
        case "present": return .orange
        default:
            let choices: [Hue] = [.pink, .teal, .cyan, .indigo, .yellow, .red]
            return choices[id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % choices.count]
        }
    }

    var body: some View {
        GlassPanel(glow: active ? hue.top : nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(symbol: mode.symbol, hue: hue, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.name).font(.title2.weight(.bold))
                        Text(mode.blurb).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let onEdit {
                        Button(action: onEdit) { Image(systemName: "pencil") }
                            .buttonStyle(.glass)
                            .help("Change what \(mode.name) does")
                            .accessibilityLabel("Edit \(mode.name) mode")
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    if !mode.openApps.isEmpty { bullet("arrow.up.forward.app", "Opens " + mode.openApps.joined(separator: ", ")) }
                    if !mode.quitApps.isEmpty { bullet("xmark.app", "Closes " + mode.quitApps.joined(separator: ", ")) }
                    if mode.hideOthers { bullet("eye.slash", "Hides other windows") }
                    bullet(mode.keepAwake == .off ? "moon.zzz" : "sun.max", mode.keepAwake.title)
                    if mode.tilingOn { bullet("rectangle.split.3x1", "Turns on window tiling") }
                }
                .font(.callout)
                Button(action: action) {
                    HStack {
                        if working { ProgressView().controlSize(.small) }
                        Text(active ? "Switch off" : "Start \(mode.name)").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(hue.top)
                .disabled(working)
            }
        }
    }

    func bullet(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).foregroundStyle(.secondary)
    }
}

struct CleanupPage: View {
    @Environment(AppModel.self) private var model
    @State private var includeDownloads = false

    var body: some View {
        let cleanup = model.cleanup
        let visible = cleanup.items.filter { !cleanup.trashed.contains($0.id) }
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(page: .cleanup)
            GlassPanel(glow: Hue.yellow.top) {
                HStack(spacing: 22) {
                    if visible.isEmpty {
                        Image(systemName: cleanup.scannedAt == nil ? "magnifyingglass.circle.fill" : "checkmark.seal.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Hue.yellow.gradient)
                            .frame(width: 140, height: 140)
                    } else {
                        Chart(visible) { item in
                            SectorMark(angle: .value("Size", Double(item.size)), innerRadius: .ratio(0.6), angularInset: 2)
                                .foregroundStyle(by: .value("Kind", item.kind.rawValue))
                                .cornerRadius(4)
                        }
                        .chartLegend(.hidden)
                        .frame(width: 140, height: 140)
                        .overlay {
                            VStack(spacing: 0) {
                                Text(bytes(cleanup.total)).font(.headline)
                                Text("can go").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(cleanup.scannedAt == nil ? "See what's taking up space" : "\(bytes(cleanup.total)) you can safely clear")
                            .font(.title2.weight(.bold))
                        Text("Only things that rebuild themselves are listed. They go to the Trash, so you can put them back.")
                            .foregroundStyle(.secondary)
                        Toggle("Also look for downloads older than a month", isOn: $includeDownloads)
                        Button {
                            Task { await model.cleanup.scan(includeDownloads: includeDownloads) }
                        } label: {
                            Label(cleanup.scanning ? "Looking…" : (cleanup.scannedAt == nil ? "Scan my Mac" : "Scan again"),
                                  systemImage: "sparkle.magnifyingglass")
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(cleanup.scanning)
                    }
                    Spacer(minLength: 0)
                }
            }
            if cleanup.scanning { ProgressView("Measuring folders…").frame(maxWidth: .infinity) }
            ForEach(CleanupItem.Kind.allCases, id: \.self) { kind in
                let items = visible.filter { $0.kind == kind }
                if !items.isEmpty {
                    SectionTitle(text: kind.rawValue)
                    VStack(spacing: 10) {
                        ForEach(items) { item in
                            GlassPanel(padding: 14, radius: 18) {
                                HStack(spacing: 12) {
                                    IconTile(symbol: item.symbol, hue: kind == .developer ? .blue : kind == .downloads ? .teal : .orange, size: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.headline)
                                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(bytes(item.size)).font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                                    Button("Move to Trash") { model.trash(item) }
                                        .buttonStyle(.glass)
                                        .disabled(model.isBusy("cleanup-\(item.id)"))
                                }
                            }
                        }
                    }
                }
            }
            if cleanup.trashSize > 0 {
                Label("The Trash holds \(bytes(cleanup.trashSize)). Empty it in Finder when you're sure, to get the space back.",
                      systemImage: "trash")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Which kinds of file go to which folder in Downloads (the instant and the hourly sorter share these).
struct DownloadRulesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var downloads = DownloadSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sorting rules").font(.title2.weight(.semibold))
            Text("Each folder in Downloads, and the file endings that go in it. Separate endings with spaces.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($downloads.rules) { $rule in
                        HStack(spacing: 10) {
                            TextField("Folder", text: $rule.folder).textFieldStyle(.roundedBorder).frame(width: 140)
                            TextField("pdf doc txt", text: Binding(get: { rule.extensions.joined(separator: " ") }, set: { text in
                                rule.extensions = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "," })
                                    .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }
                            }))
                            .textFieldStyle(.roundedBorder)
                            Button { downloads.rules.removeAll { $0.id == rule.id } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(rule.folder)")
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            HStack {
                Button { downloads.rules.append(DownloadRule(folder: "New folder \(downloads.rules.count + 1)", extensions: [])) } label: {
                    Label("Add a folder", systemImage: "plus")
                }
                .buttonStyle(.glass)
                Spacer()
                Text("Everything else goes to").foregroundStyle(.secondary)
                TextField("Other", text: $downloads.otherFolder).textFieldStyle(.roundedBorder).frame(width: 120)
            }
            SettingRow(title: "Wait before moving", detail: "\(downloads.settleSeconds) seconds after a download stops changing") {
                Slider(value: Binding(get: { Double(downloads.settleSeconds) }, set: { downloads.settleSeconds = Int($0) }), in: 5...120, step: 5)
                    .frame(width: 220)
            }
            HStack {
                Button("Use the original rules") { downloads.rules = DownloadRule.defaults; downloads.otherFolder = "Other" }
                    .buttonStyle(.glass)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Save") {
                    downloads.rules = downloads.rules.filter { !$0.folder.trimmingCharacters(in: .whitespaces).isEmpty }
                    if downloads.otherFolder.trimmingCharacters(in: .whitespaces).isEmpty { downloads.otherFolder = "Other" }
                    model.applyDownloads(downloads)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(downloads == model.settings.downloads)
            }
        }
        .padding(24)
        .frame(width: 640, height: 560)
        .onAppear { downloads = model.settings.downloads }
    }
}
