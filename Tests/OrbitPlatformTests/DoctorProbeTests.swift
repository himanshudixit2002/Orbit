import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct DoctorProbeTests {
    func plist(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    func write(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @Test func theProbeFindsWhatsReallyThere() throws {
        let ctx = try sandboxContext()
        let home = ctx.paths.home
        let agents = home.appending(path: "Library/LaunchAgents")
        try write(try plist([:]), agents.appending(path: "com.google.keystone.agent.plist"))
        try write(try plist(["Label": "homebrew.mxcl.mongodb-community", "ProgramArguments": ["/bin/sh"], "RunAtLoad": true]),
                  agents.appending(path: "homebrew.mxcl.mongodb-community.plist"))
        try write(try plist(["Label": "com.example.gone", "ProgramArguments": ["/nowhere/tool"], "RunAtLoad": true]),
                  agents.appending(path: "com.example.gone.plist"))
        try write(Data("set -g @plugin 'tmux-plugins/tpm'\nset -g @plugin 'tmux-plugins/tmux-yank'\n".utf8), home.appending(path: ".tmux.conf"))
        try write(Data(), home.appending(path: ".tmux/plugins/tpm/bin/install_plugins"))
        try write(Data(), home.appending(path: "Developer/Products/Vitals/Package.swift"))
        try write(Data(), home.appending(path: "Developer/Sip/package.json"))
        try FileManager.default.createDirectory(at: home.appending(path: "Developer/Sip/.git"), withIntermediateDirectories: true)
        let apps = home.appending(path: "Apps")
        for (name, version) in [("Antigravity", "2.26.0"), ("Antigravity 2", "2.3.1")] {
            try write(try plist(["CFBundleIdentifier": "com.google.antigravity", "CFBundleShortVersionString": version]),
                      apps.appending(path: "\(name).app/Contents/Info.plist"))
        }

        let facts = DoctorProbe(ctx, applicationFolders: [apps]).facts()
        #expect(facts.launchAgents.filter { $0.program == nil }.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["com.google.keystone.agent.plist"])
        #expect(facts.launchAgents.contains { $0.program == "/nowhere/tool" && !$0.programExists })
        #expect(facts.servicesAtLogin.map(\.formula) == ["mongodb-community"])
        #expect(facts.tmuxManagerInstalled && facts.tmuxPluginsMissing == ["tmux-yank"])
        #expect(facts.projectsNotInGit == ["Products/Vitals"])
        let found = Doctor.findings(facts)
        #expect(found.contains { $0.title == "Antigravity 2 is an older copy of Antigravity" })
        #expect(found.contains { $0.title == "A login item starts a program that's gone" })
    }

    @Test func fixesGoToTheTrashAndUndoBringsThemBack() async throws {
        let system = FakeSystem()
        let ctx = try sandboxContext(system)
        let agent = ctx.paths.at("Library/LaunchAgents/com.example.gone.plist")
        try write(try plist(["Label": "com.example.gone", "ProgramArguments": ["/nowhere/tool"]]), agent)
        let actions = Actions(ctx)
        let outcome = try await actions.fix(.trash([agent.path(percentEncoded: false)]))
        #expect(outcome.ok)
        #expect(!FileManager.default.fileExists(atPath: agent.path(percentEncoded: false)))
        #expect(system.ran("launchctl", "bootout", "gui/501/com.example.gone"))
        #expect(await actions.undo(outcome.undo).ok)
        #expect(FileManager.default.fileExists(atPath: agent.path(percentEncoded: false)))
    }

    @Test func aServiceStopsAndUndoStartsItAgain() async throws {
        let system = FakeSystem()
        let actions = Actions(try sandboxContext(system))
        let outcome = try await actions.fix(.stopService(formula: "mongodb-community"))
        #expect(outcome.ok && outcome.undo == [.brewService(formula: "mongodb-community", wasRunning: true)])
        #expect(system.ran("brew", "services", "stop", "mongodb-community"))
        _ = await actions.undo(outcome.undo)
        #expect(system.ran("brew", "services", "start", "mongodb-community"))
    }

    @Test func theCheatSheetIsBroughtUpToDateAndUndoPutsItBack() async throws {
        let ctx = try sandboxContext()
        let old = "TILING\n\nCAPS LOCK      tap                    Escape\nHYPER          hold Caps Lock + …     P Postman\n\nMOUSE\n"
        try write(Data(old.utf8), ctx.paths.cheatSheet)
        #expect(DoctorProbe(ctx, applicationFolders: []).facts().cheatSheetStale)
        let actions = Actions(ctx)
        let outcome = try await actions.fix(.refreshCheatSheet)
        let new = try String(contentsOf: ctx.paths.cheatSheet, encoding: .utf8)
        #expect(outcome.ok && new.hasPrefix("TILING\n\nCAPS LOCK") && new.hasSuffix("\n\nMOUSE\n") && new.contains("T Warp"))
        #expect(!DoctorProbe(ctx, applicationFolders: []).facts().cheatSheetStale)
        _ = await actions.undo(outcome.undo)
        #expect(try String(contentsOf: ctx.paths.cheatSheet, encoding: .utf8) == old)
    }
}
