import AppKit
import OrbitCore
import OrbitPlatform
import SwiftUI

extension AppModel {
    func gitInit(_ project: ProjectInfo) {
        perform("git-\(project.id)", "Started using git in \(project.name)") { [actions] _ in await actions.gitInit(project) }
    }

    func changeService(_ service: ServiceInfo, _ change: Actions.ServiceChange) {
        perform("service-\(service.formula)", serviceTitle(service, change)) { [actions] _ in await actions.changeService(service, change) }
    }

    func serviceTitle(_ service: ServiceInfo, _ change: Actions.ServiceChange) -> String {
        switch change {
        case .startNow: "Started \(service.name)"
        case .stop: "Stopped \(service.name)"
        case .startAtLogin: "\(service.name) starts at login"
        case .stopAtLogin: "\(service.name) stops starting at login"
        }
    }

    func stopProcess(_ info: PortInfo) {
        perform("port-\(info.id)", "Asked \(info.port.command) to quit", lane: false) { [actions] _ in actions.stopProcess(info) }
    }
}

/// Your projects, the services they lean on, and what's listening.
struct DeveloperPage: View {
    @Environment(AppModel.self) private var model
    @State private var projects: [ProjectInfo] = []
    @State private var services: [ServiceInfo] = []
    @State private var ports: [PortInfo] = []
    @State private var loading = false
    @State private var stopping: PortInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(page: .developer)
            HStack {
                SectionTitle(text: "Projects")
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Look again") { Task { await load() } }.buttonStyle(.glass).disabled(loading)
            }
            GlassPanel {
                VStack(spacing: 8) {
                    if projects.isEmpty && !loading { Text("No projects found in ~/Developer.").foregroundStyle(.secondary) }
                    ForEach(projects) { project in projectRow(project) }
                }
            }
            if !services.isEmpty {
                SectionTitle(text: "Services")
                GlassPanel {
                    VStack(spacing: 8) {
                        ForEach(services) { service in serviceRow(service) }
                    }
                }
            }
            SectionTitle(text: "Listening")
            GlassPanel {
                VStack(spacing: 8) {
                    if ports.isEmpty && !loading { Text("Nothing is listening for connections.").foregroundStyle(.secondary) }
                    ForEach(ports) { info in portRow(info) }
                }
            }
        }
        .task { await load() }
        .onChange(of: model.journal.count) { Task { await load() } }
        .confirmationDialog(Text("Ask \(stopping?.port.command ?? "it") to quit?"), isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                            presenting: stopping) { info in
            Button("Ask it to quit", role: .destructive) { model.stopProcess(info) }
            Button("Cancel", role: .cancel) {}
        } message: { info in
            Text("It's listening on port \(info.port.port). It gets the chance to save and close; Orbit can't start it again for you.")
        }
    }

    func load() async {
        loading = true
        let probe = DeveloperProbe(model.ctx)
        async let foundProjects = probe.projects()
        async let foundServices = probe.services()
        async let foundPorts = probe.ports()
        let (p, s, l) = await (foundProjects, foundServices, foundPorts)
        projects = p
        services = s
        ports = l
        loading = false
    }

    /// The project a process works in, by its folder.
    func project(of info: PortInfo) -> String? {
        guard let folder = info.folder else { return nil }
        return projects.first { folder == $0.id || folder.hasPrefix($0.id + "/") }?.name
    }

    func projectRow(_ project: ProjectInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: project.kind.symbol).frame(width: 22).foregroundStyle(Hue.orange.top)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.body.weight(.medium))
                HStack(spacing: 8) {
                    Text(project.kind.title).font(.caption).foregroundStyle(.secondary)
                    if let git = project.git {
                        Label(git.branch, systemImage: "arrow.triangle.branch").font(.caption)
                        if git.ahead > 0 { Text("↑\(git.ahead) to push").font(.caption).foregroundStyle(.blue) }
                        if git.behind > 0 { Text("↓\(git.behind) to pull").font(.caption).foregroundStyle(.orange) }
                        if git.changes > 0 { Text("\(git.changes) changed").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text("not in git").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if project.git == nil {
                Button("Start using git") { model.gitInit(project) }
                    .buttonStyle(.glass)
                    .disabled(model.isBusy("git-\(project.id)"))
                    .help("git init and a .gitignore for a \(project.kind.title) project. Nothing is committed or pushed.")
            }
            ForEach(openers(for: project), id: \.name) { opener in
                Button { open(project, with: opener) } label: { Image(systemName: opener.symbol) }
                    .buttonStyle(.borderless)
                    .help("Open in \(opener.name)")
                    .accessibilityLabel("Open \(project.name) in \(opener.name)")
            }
        }
    }

    struct Opener {
        let name: String
        let bundleID: String?
        let symbol: String
    }

    func openers(for project: ProjectInfo) -> [Opener] {
        var list = [Opener(name: "Antigravity IDE", bundleID: "com.google.antigravity-ide", symbol: "chevron.left.forwardslash.chevron.right"),
                    Opener(name: "Warp", bundleID: "dev.warp.Warp-Stable", symbol: "terminal")]
        if project.kind == .xcode || project.kind == .swift { list.append(Opener(name: "Xcode", bundleID: "com.apple.dt.Xcode", symbol: "hammer")) }
        list.append(Opener(name: "Finder", bundleID: nil, symbol: "folder"))
        return list.filter { $0.bundleID.map { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } ?? true }
    }

    func open(_ project: ProjectInfo, with opener: Opener) {
        guard let id = opener.bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            NSWorkspace.shared.activateFileViewerSelecting([project.url])
            return
        }
        var target = project.url
        if id == "com.apple.dt.Xcode",
           let workspace = ((try? FileManager.default.contentsOfDirectory(at: project.url, includingPropertiesForKeys: nil)) ?? [])
               .first(where: { $0.pathExtension == "xcworkspace" || $0.pathExtension == "xcodeproj" }) {
            target = workspace
        }
        NSWorkspace.shared.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func serviceRow(_ service: ServiceInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack").frame(width: 22).foregroundStyle(Hue.indigo.top)
            Text(service.name).font(.body.weight(.medium))
            Text(service.running ? "Running" : "Stopped").font(.caption).foregroundStyle(service.running ? .green : .secondary)
            Spacer()
            Toggle("At login", isOn: Binding(get: { service.atLogin }, set: { on in
                model.changeService(service, on ? .startAtLogin : .stopAtLogin(keepRunning: service.running))
            }))
            .toggleStyle(.switch)
            .help("Start it every time you log in")
            Button(service.running ? "Stop" : "Start") { model.changeService(service, service.running ? .stop : .startNow) }
                .buttonStyle(.glass)
                .disabled(model.isBusy("service-\(service.formula)"))
        }
    }

    func portRow(_ info: PortInfo) -> some View {
        let port = info.port
        return HStack(spacing: 10) {
            Text(verbatim: ":\(port.port)").font(.body.monospacedDigit().weight(.semibold)).frame(width: 70, alignment: .leading)
            Text(port.command).lineLimit(1)
            if let detail = project(of: info) ?? port.knownUse ?? info.owner.label {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if info.owner == .yours, port.port >= 1024 {
                Link(destination: URL(string: "http://localhost:\(port.port)")!) { Image(systemName: "safari") }
                    .help("Open http://localhost:\(port.port)")
                    .accessibilityLabel("Open localhost port \(port.port)")
            }
            if info.owner == .yours {
                Button("Stop") { stopping = info }.buttonStyle(.glass).disabled(model.isBusy("port-\(info.id)"))
            }
        }
    }
}
