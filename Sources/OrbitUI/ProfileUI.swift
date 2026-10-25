import AppKit
import OrbitCore
import OrbitPlatform
import SwiftUI

/// A profile read from disk, and what importing it would change here.
struct ProfileImport: Identifiable {
    let id = UUID()
    let profile: OrbitProfile
    /// The parts of the setup (top-level settings) that differ.
    let settings: [String]
    /// Files edited by hand on this Mac that importing writes over (their copies are kept).
    let replaced: [ManagedFile]
}

/// Health › Your setup: save a copy, save into a folder (a dotfiles repository), import.
struct ProfilePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Keep a copy of Orbit's settings and config files, or bring them to another Mac. Your link token stays here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { model.exportProfile() } label: { Label("Save a copy…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.glass)
                    Button { model.exportProfileToFolder() } label: { Label("Save into a folder…", systemImage: "folder.badge.plus") }
                        .buttonStyle(.glass)
                        .help("As plain files, for a dotfiles repository. If it's in git, Orbit offers to commit them (never to push).")
                    Spacer()
                    Button { model.pickProfileToImport() } label: { Label("Import…", systemImage: "square.and.arrow.up.on.square") }
                        .buttonStyle(.glass)
                }
                .disabled(model.isBusy("exportProfile") || model.isBusy("importProfile"))
            }
        }
        .sheet(item: Binding(get: { model.pendingImport }, set: { model.pendingImport = $0 })) { pending in
            ProfileImportSheet(pending: pending)
        }
        .confirmationDialog("Commit the setup in git?", isPresented: Binding(get: { model.profileCommitFolder != nil },
                                                                             set: { if !$0 { model.profileCommitFolder = nil } }),
                            presenting: model.profileCommitFolder) { folder in
            Button("Commit") { model.commitProfile(in: folder) }
            Button("Not now", role: .cancel) {}
        } message: { folder in
            Text("\(folder.lastPathComponent) is in git. Orbit commits just its own files there, on this Mac only: nothing is pushed.")
        }
    }
}

/// What importing a profile would do, for the user to look over first.
struct ProfileImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: ProfileImport

    var carried: [ManagedFile] {
        pending.profile.edited.compactMap(ManagedFile.init(rawValue:)).filter { !$0.ownerRewrites }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "square.and.arrow.up.on.square", hue: .indigo, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import this setup?").font(.title2.weight(.semibold))
                    Text("Saved \(pending.profile.exported.formatted(date: .long, time: .shortened))").foregroundStyle(.secondary)
                }
            }
            if pending.settings.isEmpty && carried.isEmpty {
                Label("This Mac matches it already: there's nothing to change.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                if !pending.settings.isEmpty {
                    section("What changes here", pending.settings.map(OrbitProfile.title(ofSetting:)), symbol: "arrow.triangle.2.circlepath")
                }
                if !carried.isEmpty {
                    section("Edited by hand where it was saved, brought over as it is", carried.map(\.title), symbol: "hand.raised")
                }
                if !pending.replaced.isEmpty {
                    section("Edited by hand on this Mac, and replaced (a copy is kept)", pending.replaced.map(\.title),
                            symbol: "exclamationmark.triangle.fill", tint: .orange)
                }
            }
            Text("Nothing is switched on or off, and this Mac keeps its own login, Doctor and theme-sync choices. Undo puts it all back.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { model.importProfile(pending) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pending.settings.isEmpty && carried.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    func section(_ title: String, _ items: [String], symbol: String, tint: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(tint == .secondary ? .primary : tint)
            ForEach(items, id: \.self) { item in
                Text("• \(item)").foregroundStyle(.secondary)
            }
        }
    }
}
