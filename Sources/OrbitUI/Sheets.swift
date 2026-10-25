import AppKit
import OrbitCore
import OrbitPlatform
import SwiftUI

/// Shows how Orbit's version of a hand-edited config file differs from the one on disk.
struct ConflictSheet: View {
    let conflict: Conflict
    @Environment(AppModel.self) private var model

    var body: some View {
        let url = conflict.file.url(model.ctx.paths)
        ConflictPreview(conflict: conflict, onDisk: model.ctx.files.read(url).map { String(decoding: $0, as: UTF8.self) } ?? "")
    }
}

/// The differences view itself, given the file's current text (snapshots pass in a sample).
struct ConflictPreview: View {
    let conflict: Conflict
    let onDisk: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var url: URL { conflict.file.url(model.ctx.paths) }

    var body: some View {
        let current = onDisk
        let lines = LineDiff.diff(current, conflict.proposed ?? current)
        let rows = LineDiff.condensed(lines)
        let removed = lines.filter { $0.kind == .removed }.count
        let added = lines.filter { $0.kind == .added }.count
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbol: "doc.badge.ellipsis", hue: .orange, size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(conflict.file.title) were changed outside Orbit").font(.title2.weight(.bold))
                    Text(model.ctx.paths.tilde(url)).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Text("Someone edited this file by hand. Here's what would change if Orbit wrote its version. Whatever you choose, your copy is backed up first.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Label("\(removed) line\(removed == 1 ? "" : "s") only in your version", systemImage: "minus.square.fill")
                    .foregroundStyle(.red)
                Label("\(added) line\(added == 1 ? "" : "s") from Orbit", systemImage: "plus.square.fill")
                    .foregroundStyle(.green)
                Spacer()
            }
            .font(.callout)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in DiffRow(row: row) }
                }
                .padding(.vertical, 6)
            }
            .frame(minHeight: 240, maxHeight: 380)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
            HStack {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(.glass)
                Spacer()
                Button("Keep my edits") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Use Orbit's version") {
                    let retry = conflict.retry
                    dismiss()
                    Task { await retry() }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 780)
    }
}

struct DiffRow: View {
    let row: LineDiff.Row

    var body: some View {
        switch row {
        case .skipped(let count):
            Text("⋯  \(count) unchanged line\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        case .line(let line):
            let color: Color = line.kind == .removed ? .red : line.kind == .added ? .green : .clear
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line.kind == .removed ? "−" : line.kind == .added ? "+" : " ")
                    .foregroundStyle(color)
                    .frame(width: 14)
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(line.kind == .same ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(.callout, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 1.5)
            .background(color.opacity(line.kind == .same ? 0 : 0.14))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(line.kind == .removed ? "Only in your version" : line.kind == .added ? "From Orbit" : "Unchanged"): \(line.text)")
        }
    }
}

/// Shows exactly which files "Tidy the Desktop" would move, and where, before anything moves.
struct TidyPlanSheet: View {
    let plan: [TidyMove]?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var title: String {
        guard let plan else { return "Orbit can't look at your Desktop" }
        return plan.isEmpty ? "Your Desktop is already tidy" : "Tidy \(plan.count) file\(plan.count == 1 ? "" : "s") off the Desktop?"
    }

    var subtitle: String {
        guard let plan else { return "Allow Orbit under Privacy & Security → Files & Folders → Desktop Folder, then try again." }
        return plan.isEmpty ? "No loose files to move. Folders and apps always stay where they are."
                            : "They go into folders in Documents. You can undo this on the Health page."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                IconTile(symbol: "desktopcomputer", hue: .blue, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.weight(.bold))
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let plan, !plan.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(DesktopTidy.Destination.allCases, id: \.self) { destination in
                            let moves = plan.filter { $0.destination == destination }
                            if !moves.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label {
                                        Text("\(Text(destination.title).bold())\(Text("  →  ~/\(destination.rawValue)").foregroundStyle(.secondary))")
                                    } icon: {
                                        Image(systemName: destination.symbol).foregroundStyle(Hue.blue.top)
                                    }
                                    ForEach(moves) { move in
                                        HStack(spacing: 8) {
                                            Image(nsImage: Icons.of(move.source.path(percentEncoded: false)))
                                                .resizable()
                                                .frame(width: 20, height: 20)
                                            Text(move.source.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                        }
                                        .padding(.leading, 24)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            }
            HStack {
                if plan == nil {
                    Button("Open Settings") { model.openSettings(.filesAndFolders) }.buttonStyle(.glass)
                }
                Spacer()
                Button(plan?.isEmpty == false ? "Cancel" : "Done") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                if let plan, !plan.isEmpty {
                    Button("Move \(plan.count) file\(plan.count == 1 ? "" : "s")") {
                        model.tidyDesktop(plan)
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 580)
    }
}

/// Lays its children out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A row of app chips with an "Add app" menu, for the mode editor.
struct AppChips: View {
    let title: String
    let subtitle: String
    @Binding var apps: [String]
    let installed: [InstalledApp]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(installed.filter { !apps.contains($0.name) }, id: \.path) { app in
                        Button(app.name) { apps.append(app.name) }
                    }
                } label: {
                    Label("Add app", systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
            }
            if apps.isEmpty {
                Text("No apps yet.").foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(apps, id: \.self) { name in chip(name) }
                }
            }
        }
    }

    func chip(_ name: String) -> some View {
        HStack(spacing: 6) {
            if let path = installed.first(where: { $0.name == name })?.path {
                Image(nsImage: Icons.of(path)).resizable().frame(width: 18, height: 18)
            }
            Text(name)
            Button { apps.removeAll { $0 == name } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Edit what a mode does: its name and icon, the apps it opens and closes, and what it keeps awake.
struct ModeEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var mode: ModeDefinition
    let isNew: Bool
    @State private var confirmDelete = false

    static let symbols = ["laptopcomputer", "scope", "music.note", "play.rectangle", "moon.stars.fill", "book.fill",
                          "gamecontroller.fill", "paintbrush.fill", "headphones", "cup.and.saucer.fill", "briefcase.fill", "sparkles"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                IconTile(symbol: mode.symbol, hue: ModeCard.hue(for: mode.id), size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "New mode" : "Edit \(mode.name) mode").font(.title2.weight(.bold))
                    Text("Choose what happens when you start it. Switching it off puts things back.").foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GlassPanel {
                        VStack(spacing: 12) {
                            SettingRow(title: "Name") {
                                TextField("For example, Study", text: $mode.name).textFieldStyle(.roundedBorder).frame(width: 300)
                            }
                            SettingRow(title: "What it's for") {
                                TextField("A short description", text: $mode.blurb).textFieldStyle(.roundedBorder).frame(width: 300)
                            }
                            SettingRow(title: "Icon") {
                                HStack(spacing: 4) {
                                    ForEach(Self.symbols, id: \.self) { symbol in
                                        Button { mode.symbol = symbol } label: {
                                            Image(systemName: symbol)
                                                .foregroundStyle(mode.symbol == symbol ? Color.accentColor : Color.primary)
                                                .frame(width: 26, height: 26)
                                                .background(mode.symbol == symbol ? Color.accentColor.opacity(0.28) : .clear,
                                                            in: RoundedRectangle(cornerRadius: 7))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(symbol)
                                    }
                                }
                            }
                        }
                    }
                    GlassPanel {
                        AppChips(title: "Opens these apps", subtitle: "Started if they aren't open already.",
                                 apps: $mode.openApps, installed: model.appCatalog.apps)
                    }
                    GlassPanel {
                        AppChips(title: "Closes these apps",
                                 subtitle: "Asked politely, so they can save. They reopen when you switch the mode off.",
                                 apps: $mode.quitApps, installed: model.appCatalog.apps)
                    }
                    GlassPanel {
                        VStack(spacing: 12) {
                            SettingRow(title: "Hide other windows", detail: "Everything except the app you're using.") {
                                Toggle("Hide other windows", isOn: $mode.hideOthers).toggleStyle(.switch).labelsHidden()
                            }
                            SettingRow(title: "Turn on window tiling") {
                                Toggle("Turn on window tiling", isOn: $mode.tilingOn).toggleStyle(.switch).labelsHidden()
                            }
                            SettingRow(title: "While it's on") {
                                Picker("While it's on", selection: $mode.keepAwake) {
                                    ForEach(KeepAwake.allCases, id: \.self) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 430)
                            }
                        }
                    }
                }
            }
            HStack {
                if !isNew && mode.isBuiltIn {
                    Button("Reset to Orbit's") {
                        model.resetMode(mode.id)
                        dismiss()
                    }
                    .buttonStyle(.glass)
                }
                if !isNew && !mode.isBuiltIn {
                    Button("Delete mode", role: .destructive) { confirmDelete = true }.buttonStyle(.glass)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = mode
                    saved.name = mode.name.trimmingCharacters(in: .whitespaces)
                    if saved.blurb.trimmingCharacters(in: .whitespaces).isEmpty { saved.blurb = "Your own mode." }
                    model.saveMode(saved)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(mode.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 740, height: 700)
        .onAppear { model.appCatalog.refresh() }
        .confirmationDialog("Delete \(mode.name) mode?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.deleteMode(mode.id)
                dismiss()
            }
        }
    }
}
