import AppKit
import OrbitCore
import OrbitPlatform
import SwiftUI

extension AppModel {
    func readInstant() async {
        let on = await Task.detached(priority: .userInitiated) { [actions] in actions.instantGroupsOn() }.value
        if on != instantOn { instantOn = on }
        // The Speed check's tip about animations goes as soon as they're all out.
        if on.count == SpeedTweak.Group.allCases.count { speedFindings.removeAll { $0.id == "speed-instant" } }
    }

    func setInstant(_ groups: Set<SpeedTweak.Group>, on: Bool) {
        let every = groups.count == SpeedTweak.Group.allCases.count
        let title = every ? (on ? "Made the Mac feel instant" : "Put the Mac's animations back")
                          : "Turned \(on ? "on" : "off") " + groups.map { $0.title.lowercased() }.sorted().joined(separator: " and ")
        let key = every ? "instant-all" : "instant-" + groups.map(\.rawValue).sorted().joined(separator: "-")
        perform(key, title) { [actions] _ in await actions.setInstant(groups, on: on) }
    }

    var instantBusy: Bool { busy.contains { $0.hasPrefix("instant-") } }

    /// Looks at what slows the Mac now (off the main thread) and shows what it finds.
    func runSpeedCheck() {
        guard !isSnapshot, !speedRunning else { return }
        speedRunning = true
        let tracker = speedTracker
        let probe = SpeedProbe(ctx)
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path(percentEncoded: false)
        Task {
            let (facts, agents) = await Task.detached(priority: .utility) {
                (probe.facts(apps: tracker.sample(frontmost: front)), probe.loginAgents())
            }.value
            speedFacts = facts
            appUsage = facts.apps
            loginAgents = agents
            // Paused, the animations are back on purpose: no tip to take them out again.
            speedFindings = SpeedCheck.findings(facts, ignored: Set(settings.doctorIgnored).union(paused == nil ? [] : ["speed-instant"]))
            speedChecked = Date()
            speedRunning = false
        }
    }

    /// The apps and what they use, fresh (the Speed page's live list).
    func refreshAppUsage() async {
        let tracker = speedTracker
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path(percentEncoded: false)
        let apps = await Task.detached(priority: .utility) { tracker.sample(frontmost: front) }.value
        if apps != appUsage { appUsage = apps }
    }

    func quitApp(_ app: AppUsage) {
        Task {
            await performNow("quit-\(app.path)", "Asked \(app.name) to quit") { [actions] _ in
                await actions.quitApp(path: app.path, name: app.name)
            }
            await refreshAppUsage()
        }
    }

    func stopColima() {
        perform("colima", "Stopped Colima's virtual machine") { [actions] _ in await actions.stopColima() }
    }

    func stopCommand(_ command: BusyCommand) {
        Task {
            await performNow("stop-\(command.pid)", "Asked \(command.name) to stop") { [actions] _ in
                actions.stopCommand(pid: command.pid, name: command.name, path: command.path)
            }
            await refreshAppUsage()
        }
    }

    func setStartsAtLogin(_ agent: UserLoginAgent, _ on: Bool) {
        Task {
            await performNow("agent-\(agent.label)", "\(agent.name) \(on ? "starts" : "stopped starting") at login") { [actions] _ in
                await actions.setStartsAtLogin(agent, on)
            }
            runSpeedCheck()
        }
    }

    /// Looks for apps left in the background that keep the Mac busy (see `SpeedCheck.toNotify`) and
    /// sends a notice with Quit for each, once every 6 hours at most. It only reads; Quit asks politely.
    func checkHeavyApps() async {
        guard !isPractice, !isSnapshot, settings.speed.heavyAppNotices, paused == nil else {
            heavyBefore = []
            return
        }
        let tracker = heavyTracker
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path(percentEncoded: false)
        let (apps, tight) = await Task.detached(priority: .utility) {
            (tracker.sample(frontmost: front), SpeedProbe.memoryTight())
        }.value
        let (notify, heavyNow) = SpeedCheck.toNotify(apps, memoryTight: tight, heavyBefore: heavyBefore,
                                                     ignored: Set(settings.doctorIgnored))
        heavyBefore = heavyNow
        for app in notify {
            let finding = SpeedCheck.heavyFinding(app)
            if let command = app.busiestCommand, AppGrouping.isTerminal(app.path) {
                notifier?.send(.busyCommand, key: "heavy \(app.path)", title: finding.title, body: finding.detail,
                               page: .speed, every: 6 * 3600) { [weak self] in self?.stopCommand(command) }
            } else {
                notifier?.send(.heavyApp, key: "heavy \(app.path)", title: finding.title, body: finding.detail,
                               page: .speed, every: 6 * 3600) { [weak self] in self?.quitApp(app) }
            }
        }
    }

    /// Times this restart (Orbit opens at login): from macOS starting until the Mac goes calm after
    /// login, and what kept it busy until then. A look at the processor every 10 seconds (a tenth of a
    /// millisecond each) for at most 15 minutes after login, then it's saved for the Speed page.
    func timeStartup() async {
        guard let booted = StartupProbe.bootTime(),
              !ctx.store.startups.contains(where: { abs($0.bootedAt.timeIntervalSince(booted)) < 1 }) else { return }
        // A login from before this startup is an old record: Orbit opening is the nearest thing then.
        let login = StartupProbe.loginTime().flatMap { $0 >= booted ? $0 : nil } ?? Date()
        let sampler = StatsSampler()
        _ = sampler.cpuAndMemory()
        var looks: [(at: Date, cpu: Double)] = []
        var calm: Date?
        while calm == nil, Date().timeIntervalSince(login) < StartupTimer.watchFor {
            try? await Task.sleep(for: .seconds(StartupTimer.every), tolerance: .seconds(1))
            guard !Task.isCancelled else { return }
            if let cpu = sampler.cpuAndMemory().cpu { looks.append((Date(), cpu)) }
            calm = StartupTimer.calm(looks)
        }
        let readings = ctx.readings
        let stats = await Task.detached(priority: .utility) { readings.processStats() }.value
        ctx.store.addStartup(StartupRecord(bootedAt: booted, loginAt: login, calmAt: calm, busiest: StartupTimer.busiest(stats)))
        startups = ctx.store.startups
    }

    func setHeavyAppNotices(_ on: Bool) {
        ctx.store.updateSettings { $0.speed.heavyAppNotices = on }
        settings = ctx.store.settings
    }

    func openSettings(_ pane: SettingsPane) {
        if let url = URL(string: pane.url) { NSWorkspace.shared.open(url) }
    }
}

/// Take the waiting out of the Mac, and keep it quick.
struct SpeedPage: View {
    @Environment(AppModel.self) private var model

    var allOn: Bool { model.instantOn.count == SpeedTweak.Group.allCases.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(page: .speed)
            SectionTitle(text: "Instant Mac")
            GlassPanel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(allOn ? "Everything is instant." : "Take out the animations you wait for.",
                              systemImage: allOn ? "bolt.fill" : "bolt")
                            .foregroundStyle(allOn ? Color.orange : Color.secondary)
                        Spacer()
                        Button(allOn ? "Put the animations back" : "Make everything instant") {
                            model.setInstant(Set(SpeedTweak.Group.allCases), on: !allOn)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(model.instantBusy)
                    }
                    ForEach(SpeedTweak.Group.allCases) { group in
                        SettingRow(title: group.title, detail: group.blurb) {
                            Toggle(group.title, isOn: Binding(get: { model.instantOn.contains(group) },
                                                              set: { model.setInstant([group], on: $0) }))
                                .toggleStyle(.switch).labelsHidden()
                                .disabled(model.instantBusy)
                        }
                    }
                    Text("The Dock and Finder show it at once; apps pick up instant windows and sheets as they open, so reopen any you have open now.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SectionTitle(text: "What slows it down")
            SpeedFindingsPanel()
            SectionTitle(text: "Memory")
            MemoryPanel()
            SectionTitle(text: "Using the most now")
            AppUsageList()
            SectionTitle(text: "Starts with your Mac")
            LoginAgentsPanel()
            SectionTitle(text: "Restarts")
            RestartPanel()
            SectionTitle(text: "macOS's own background work")
            AppleWorkPanel()
        }
        .task(id: model.journal) { await model.readInstant() }
        .onAppear {
            if model.speedChecked.map({ Date().timeIntervalSince($0) > 60 }) ?? true { model.runSpeedCheck() }
        }
    }
}

/// The Speed check's findings, each with its fix and Ignore.
struct SpeedFindingsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var confirming: DoctorFinding?

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.speedFindings.isEmpty ? "" : "\(model.speedFindings.count) thing\(model.speedFindings.count == 1 ? "" : "s") to look at")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if model.speedRunning { ProgressView().controlSize(.small) }
                    Button("Look again") { model.runSpeedCheck() }.buttonStyle(.glass).disabled(model.speedRunning)
                }
                if model.speedFindings.isEmpty {
                    Label(model.speedChecked == nil ? "Having a look…" : "Nothing is slowing your Mac down.",
                          systemImage: model.speedChecked == nil ? "bolt" : "checkmark.seal.fill")
                        .foregroundStyle(model.speedChecked == nil ? Color.secondary : Color.green)
                }
                ForEach(model.speedFindings) { finding in
                    FindingRow(finding: finding) { confirming = finding }
                }
            }
        }
        .confirmationDialog(Text(confirming?.fix?.label ?? ""), isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { finding in
            Button(finding.fix?.label ?? "Fix") { model.fix(finding) }
            Button("Cancel", role: .cancel) {}
        } message: { finding in
            Text(Self.confirmation(finding.fix))
        }
    }

    static func confirmation(_ fix: DoctorFix?) -> String {
        if case .stopCommand(_, let name, _) = fix {
            return "\(name) is asked to stop: it can tidy up first, and its terminal stays open. There's no Undo: run it again when you need it."
        }
        return "It's asked to quit as if you chose Quit: it can save first, and it's never forced. Undo opens it again."
    }
}

/// Where memory goes, in plain words, and one click to quit the apps you've left alone that hold the most.
struct MemoryPanel: View {
    @Environment(AppModel.self) private var model
    @State private var memory = MemoryBreakdown()
    @State private var machines: [VirtualMachineUsage] = []
    @State private var confirming = false
    @State private var stoppingColima = false

    var body: some View {
        let idle = IdleApps.toQuit(model.appUsage)
        let idleMemory = idle.reduce(UInt64(0)) { $0 + $1.memory }
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label(memory.summary, systemImage: memory.pressure >= 2 ? "exclamationmark.triangle.fill" : "memorychip")
                    .foregroundStyle(memory.pressure >= 4 ? Color.red : memory.pressure >= 2 ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if memory.total > 0 {
                    bar
                    VStack(spacing: 6) {
                        ForEach(parts, id: \.title) { part in
                            HStack(spacing: 10) {
                                Circle().fill(part.color).frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(part.title).font(.body.weight(.medium))
                                    Text(part.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(bytes(Int64(part.size))).font(.callout.monospacedDigit().weight(.semibold))
                            }
                        }
                    }
                }
                ForEach(machines) { machine in
                    HStack(spacing: 12) {
                        Image(systemName: "shippingbox.fill").foregroundStyle(Hue.blue.top)
                        Text("\(machine.name) holds \(bytes(Int64(machine.memory)))\(machine.isColima ? ": stop it when you're not using containers." : ".")")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if machine.isColima {
                            Button("Stop Colima") { stoppingColima = true }.buttonStyle(.glass).disabled(model.isBusy("colima"))
                        }
                    }
                }
                Divider()
                HStack(spacing: 12) {
                    Text(idle.isEmpty ? "No app you've left alone for an hour holds much memory."
                                      : "\(idle.count) app\(idle.count == 1 ? "" : "s") you haven't used for an hour hold \(bytes(Int64(idleMemory))): \(idle.map(\.name).joined(separator: ", ")).")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(idle.count == 1 ? "Quit it" : "Quit them") { confirming = true }
                        .buttonStyle(.glassProminent).disabled(idle.isEmpty)
                }
            }
        }
        .task {
            // Fresh every few seconds while the page shows (macOS's counters and the process list: a few milliseconds).
            let readings = model.ctx.readings
            let colima = FileManager.default.isExecutableFile(atPath: Tool.colima)
            while !Task.isCancelled {
                (memory, machines) = await Task.detached(priority: .utility) {
                    (StatsSampler.memoryBreakdown(), VirtualMachines.find(readings.processStats(), colimaInstalled: colima))
                }.value
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog(Text("Stop Colima?"), isPresented: $stoppingColima) {
            Button("Stop Colima") { model.stopColima() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its containers stop too (databases, servers). Undo starts it again, and containers set to restart come back with it.")
        }
        .confirmationDialog(Text("Quit \(idle.map(\.name).joined(separator: ", "))?"), isPresented: $confirming) {
            Button(idle.count == 1 ? "Quit" : "Quit \(idle.count) apps") { for app in idle { model.quitApp(app) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each is asked to quit as if you chose Quit: it can save first, and it's never forced. Undo opens it again.")
        }
    }

    var parts: [(title: String, detail: String, size: UInt64, color: Color)] {
        [("Apps", "What open apps hold for themselves.", memory.apps, Hue.purple.top),
         ("macOS", "What macOS keeps for itself; it can't be moved.", memory.wired, Hue.gray.top),
         ("Compressed", "Squeezed to make room for the rest.", memory.compressed, Hue.orange.top),
         ("Cached files", "Kept to make things quick, and handed back the moment an app needs it.", memory.cached, Hue.cyan.top),
         ("Free", "Not in use at all.", memory.free, Hue.green.top)]
        + (memory.swap > 0 ? [("Moved to disk", "What didn't fit in memory earlier (swap): slower to get back.", memory.swap, Hue.red.top)] : [])
    }

    var bar: some View {
        GeometryReader { geo in
            let total = Double(max(1, memory.total))
            HStack(spacing: 2) {
                ForEach(parts.filter { $0.title != "Moved to disk" }, id: \.title) { part in
                    Rectangle().fill(part.color).frame(width: max(2, geo.size.width * Double(part.size) / total))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(memory.summary)
    }
}

/// How long the last restart took to be calm, timed by Orbit, against the one before, and what kept
/// the Mac busy until then.
struct RestartPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                if let last = model.startups.last {
                    HStack(alignment: .firstTextBaseline) {
                        Label(StartupTimer.total(last).map { "Calm \(SpeedCheck.duration($0)) after it started" } ?? "Still busy long after it started",
                              systemImage: "power")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text(last.bootedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    }
                    Text(StartupTimer.summary(last))
                    if let compared = StartupTimer.comparison(last, before: model.startups.dropLast().last) {
                        Text(compared).foregroundStyle(.secondary)
                    }
                    if !last.busiest.isEmpty {
                        Text("Used the processor most until then: " + last.busiest.map { "\($0.name) \(SpeedCheck.duration($0.seconds))" }.joined(separator: ", ")
                             + ". Only what runs as you is counted: Orbit can't see into macOS's system-wide work.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Label("Orbit times your next restart", systemImage: "power").font(.title3.weight(.semibold))
                    Text("How long macOS takes to start and log you in, how soon after that the Mac is calm, and what kept it busy. It's one look every 10 seconds, only in the first minutes after a restart.")
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The apps using the most memory and processor now, refreshed while it shows.
struct AppUsageList: View {
    @Environment(AppModel.self) private var model
    @State private var quitting: AppUsage?

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                if model.appUsage.isEmpty { Text("Reading…").foregroundStyle(.secondary) }
                ForEach(model.appUsage.prefix(8)) { app in row(app) }
                Divider()
                SettingRow(title: "Tell me about busy apps",
                           detail: "A quiet notice with Quit when an app you haven't used for half an hour keeps the processor busy, or holds a lot of memory while memory is tight. Never for an app playing, in a call or working.") {
                    Toggle("Tell me about busy apps", isOn: Binding(get: { model.settings.speed.heavyAppNotices },
                                                                  set: { model.setHeavyAppNotices($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                Text("Memory as Activity Monitor counts it; an app's helpers count toward it. Processor is the share of one core over the last few seconds.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refreshAppUsage()
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .confirmationDialog(Text("Quit \(quitting?.name ?? "it")?"), isPresented: Binding(get: { quitting != nil }, set: { if !$0 { quitting = nil } }),
                            presenting: quitting) { app in
            Button("Quit \(app.name)") { model.quitApp(app) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It can save first, and it's never forced. Undo opens it again.")
        }
    }

    func row(_ app: AppUsage) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                Text(status(app)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(app.memory), countStyle: .memory))
                .font(.callout.monospacedDigit()).frame(width: 80, alignment: .trailing)
            Text(app.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "–")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
            if SpeedCheck.quittable(app) {
                Button("Quit") { quitting = app }.buttonStyle(.glass).disabled(model.isBusy("quit-\(app.path)"))
            } else {
                Color.clear.frame(width: 52, height: 1)
            }
        }
    }

    func status(_ app: AppUsage) -> String {
        if app.isFrontmost { return "In front" }
        if app.inUse { return "In use" }
        if let command = app.busiestCommand, command.cpuPercent >= SpeedCheck.heavyCPU { return "Busy running \(command.name)" }
        if app.isApple { return "Part of macOS" }
        let idle = Int(app.idleMinutes ?? 0)
        return idle < 2 ? "Just used" : idle < 120 ? "Not used for \(idle) min" : "Not used for \(idle / 60) h"
    }
}

/// Your own background jobs that start at login, each with a switch, and the way to the rest.
struct LoginAgentsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.loginAgents) { agent in
                    SettingRow(title: agent.name, detail: agent.label) {
                        Toggle("At login", isOn: Binding(get: { agent.startsAtLogin }, set: { model.setStartsAtLogin(agent, $0) }))
                            .toggleStyle(.switch)
                            .disabled(model.isBusy("agent-\(agent.label)"))
                    }
                }
                HStack {
                    Text("Apps that open at login, and helpers installed for the whole Mac, are in System Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items") { model.openSettings(.loginItems) }.buttonStyle(.glass)
                }
            }
        }
    }
}

/// What macOS itself does in the background, with the settings only you can change.
struct AppleWorkPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: "Siri and Apple Intelligence", detail: siriDetail) {
                    Button("Open Siri settings") { model.openSettings(.siri) }.buttonStyle(.glass)
                }
                SettingRow(title: "Spotlight", detail: "Indexes your files in the background. Leaving out folders or results you don't search lightens it.") {
                    Button("Open Spotlight settings") { model.openSettings(.spotlight) }.buttonStyle(.glass)
                }
                SettingRow(title: "Reduce transparency", detail: "Solid backgrounds instead of glass: less for the screen to redraw.") {
                    Button("Open Display settings") { model.openSettings(.display) }.buttonStyle(.glass)
                }
            }
        }
    }

    var siriDetail: String {
        guard let facts = model.speedFacts else { return "Listening for “Hey Siri” and Apple Intelligence run all day." }
        guard facts.siriOn else { return "Off: nothing runs for it." }
        return "On. Its processes have used \(SpeedCheck.duration(facts.siriSeconds)) of processor time. If you don't use it, switch Siri, Apple Intelligence and “Listen for” off."
    }
}
