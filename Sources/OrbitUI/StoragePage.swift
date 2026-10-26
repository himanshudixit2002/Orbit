import AppKit
import OrbitCore
import OrbitPlatform
import SwiftUI

/// Where the disk goes, the apps by size and the big files: read when the Storage page first shows.
@Observable
final class StorageModel {
    let ctx: SystemContext
    var areas: [StorageArea] = []
    var apps: [InstalledAppSize] = []
    var largeFiles: [LargeFile] = []
    var measuring = false
    var measuredAt: Date?
    var fullAccess = false
    /// Moved to the Trash since the last look.
    var removed: Set<String> = []

    init(ctx: SystemContext) { self.ctx = ctx }

    var used: Int64 { areas.filter { $0.kind != .free }.reduce(0) { $0 + $1.size } }
    var free: Int64 { areas.first { $0.kind == .free }?.size ?? 0 }

    func measure() async {
        guard !measuring else { return }
        measuring = true
        let probe = StorageProbe(ctx)
        fullAccess = ctx.readings.fullDiskAccess()
        async let measured = probe.measure(fullAccess: fullAccess)
        async let apps = probe.apps()
        let (found, listed) = await (measured, apps)
        areas = found.areas
        largeFiles = found.largeFiles
        self.apps = listed
        removed = []
        measuredAt = Date()
        measuring = false
    }
}

extension AppModel {
    /// Moves an app to the Trash (it must be closed); Undo puts it back.
    func trashApp(_ app: InstalledAppSize) {
        let scanner = CleanupScanner(ctx)
        Task {
            let result = await performNow("trash-\(app.path)", "Moved \(app.name) to the Trash") { _ in scanner.trash(.app(app)) }
            if result.ok { storage.removed.insert(app.path) }
        }
    }

    /// Moves a big file of yours to the Trash; Undo puts it back.
    func trashFile(_ file: LargeFile) {
        let scanner = CleanupScanner(ctx)
        Task {
            let result = await performNow("trash-\(file.path)", "Moved \(file.name) to the Trash") { _ in scanner.trash(.file(file)) }
            if result.ok { storage.removed.insert(file.path) }
        }
    }

    func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// The whole disk at a glance: each part's size, with what's hidden from Orbit and how to show it.
struct StorageOverview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let storage = model.storage
        GlassPanel(glow: Hue.blue.top) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(storage.areas.isEmpty ? "Where your space goes" : "\(diskBytes(storage.free)) free of \(diskBytes(storage.used + storage.free))")
                            .font(.title2.weight(.bold))
                        Text(storage.measuring ? "Measuring every folder Orbit can see…" : "Measured \(storage.measuredAt?.formatted(date: .omitted, time: .shortened) ?? "")")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if storage.measuring { ProgressView().controlSize(.small) }
                    Button("Look again") { Task { await storage.measure() } }.buttonStyle(.glass).disabled(storage.measuring)
                }
                if !storage.areas.isEmpty {
                    bar(storage)
                    VStack(spacing: 8) {
                        ForEach(storage.areas.filter { $0.kind != .free }) { area in row(area, total: storage.used + storage.free) }
                    }
                }
                if !storage.fullAccess, storage.measuredAt != nil {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.fill").foregroundStyle(.orange)
                        Text("macOS keeps your own folders and apps' data from Orbit, so they're counted in \"macOS and the rest\". Switch Orbit on in Full Disk Access to see everything. It only reads sizes, and anything it clears still goes to the Trash.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Open Full Disk Access") { model.openSettings(.fullDiskAccess) }.buttonStyle(.glassProminent)
                    }
                }
            }
        }
        .task { if storage.measuredAt == nil { await storage.measure() } }
    }

    func bar(_ storage: StorageModel) -> some View {
        GeometryReader { geo in
            let total = Double(max(1, storage.used + storage.free))
            HStack(spacing: 2) {
                ForEach(storage.areas.filter { !$0.hidden && $0.size > 0 }) { area in
                    Rectangle().fill(color(area.kind)).frame(width: max(2, geo.size.width * Double(area.size) / total))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(diskBytes(storage.used)) used, \(diskBytes(storage.free)) free")
    }

    func row(_ area: StorageArea, total: Int64) -> some View {
        HStack(spacing: 10) {
            Circle().fill(area.hidden ? Color.secondary.opacity(0.4) : color(area.kind)).frame(width: 9, height: 9)
            Image(systemName: area.kind.symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(area.kind.title).font(.body.weight(.medium))
                Text(area.hidden ? "Hidden from Orbit by macOS: counted in \"macOS and the rest\"." : area.kind.blurb)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if area.kind == .trash {
                Button("Open Trash") { NSWorkspace.shared.open(model.ctx.paths.trash) }.buttonStyle(.glass).controlSize(.small)
            }
            Text(area.hidden ? "–" : diskBytes(area.size)).font(.callout.monospacedDigit().weight(.semibold)).frame(width: 80, alignment: .trailing)
            Text(area.hidden || total == 0 ? "" : "\(Int((Double(area.size) / Double(total) * 100).rounded()))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
        }
    }

    func color(_ kind: StorageArea.Kind) -> Color {
        switch kind {
        case .apps: Hue.blue.top
        case .developer: Hue.indigo.top
        case .projects: Hue.purple.top
        case .files: Hue.teal.top
        case .media: Hue.pink.top
        case .iCloud: Hue.cyan.top
        case .appData: Hue.orange.top
        case .home: Hue.yellow.top
        case .trash: Hue.red.top
        case .system: Hue.gray.top
        case .free: Color.clear
        }
    }
}

/// The biggest apps, when each was last opened, and the way to remove the ones you don't use.
struct AppsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var removing: InstalledAppSize?

    var body: some View {
        let storage = model.storage
        let apps = storage.apps.filter { !storage.removed.contains($0.path) && $0.size >= 100_000_000 && $0.bundleID != Bundle.main.bundleIdentifier }
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                if apps.isEmpty { Text(storage.measuring ? "Reading…" : "No big apps.").foregroundStyle(.secondary) }
                ForEach(apps.prefix(14)) { app in row(app) }
                Text("Apps the App Store installed belong to macOS, which asks for your password to remove them: Orbit shows them in Finder for you to drag to the Trash.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(Text("Move \(removing?.name ?? "") to the Trash?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { app in
            Button("Move to Trash") { model.trashApp(app) }
            Button("Cancel", role: .cancel) {}
        } message: { app in
            Text("\(diskBytes(app.size)) back once you empty the Trash. Until then, Undo puts it back. Its settings stay, in case you install it again.")
        }
    }

    func row(_ app: InstalledAppSize) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                Text(app.lastUsedText()).font(.caption).foregroundStyle(app.unused() ? Color.orange : Color.secondary)
            }
            Spacer()
            Text(diskBytes(app.size)).font(.callout.monospacedDigit()).frame(width: 80, alignment: .trailing)
            Group {
                if app.running {
                    Text("Open now").font(.caption).foregroundStyle(.secondary)
                } else if app.removable {
                    Button("Move to Trash") { removing = app }.buttonStyle(.glass).disabled(model.isBusy("trash-\(app.path)"))
                } else {
                    Button("Show in Finder") { model.showInFinder(app.path) }.buttonStyle(.glass)
                }
            }
            .frame(width: 130, alignment: .trailing)
        }
    }
}

/// The biggest files in your home folder, with Show in Finder, and Move to Trash for the ones that are yours.
struct LargeFilesPanel: View {
    @Environment(AppModel.self) private var model
    @State private var removing: LargeFile?

    var body: some View {
        let storage = model.storage
        let home = model.ctx.paths.home.path(percentEncoded: false).trimmingSuffix("/")
        let files = storage.largeFiles.filter { !storage.removed.contains($0.path) }
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                if files.isEmpty {
                    Text(storage.measuring ? "Looking…" : "No file of yours is over \(diskBytes(LargeFiles.atLeast)).").foregroundStyle(.secondary)
                }
                ForEach(files.prefix(15)) { file in row(file, home: home) }
                if !storage.fullAccess, storage.measuredAt != nil {
                    Text("Only in folders Orbit can see: with Full Disk Access it looks everywhere in your home folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog(Text("Move \(removing?.name ?? "") to the Trash?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { file in
            Button("Move to Trash") { model.trashFile(file) }
            Button("Cancel", role: .cancel) {}
        } message: { file in
            Text("\(diskBytes(file.size)) back once you empty the Trash. Until then, Undo puts it back.")
        }
    }

    func row(_ file: LargeFile, home: String) -> some View {
        let folder = URL(fileURLWithPath: file.package ?? file.path).deletingLastPathComponent().path(percentEncoded: false)
        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.package ?? file.path)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(file.package.map { "Part of \(URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent)" }
                     ?? folder.replacingOccurrences(of: home, with: "~").trimmingSuffix("/"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(diskBytes(file.size)).font(.callout.monospacedDigit()).frame(width: 80, alignment: .trailing)
            Button("Show") { model.showInFinder(file.path) }.buttonStyle(.glass)
            if file.movable(home: home) {
                Button("Move to Trash") { removing = file }.buttonStyle(.glass).disabled(model.isBusy("trash-\(file.path)"))
            } else {
                Color.clear.frame(width: 110, height: 1)
            }
        }
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}
