import AppKit
import OrbitCore
import OrbitPlatform

extension AppModel {
    /// A plain-text report of Orbit's state for when something needs explaining. The home folder and
    /// user name are taken out, so it can be pasted anywhere.
    func diagnostics() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        var orbit = ["Version \(version)", ProcessInfo.processInfo.operatingSystemVersionString,
                     "Mode: \(isPractice ? "practice (changes nothing)" : "live")", "Homebrew: \(Tool.homebrew)",
                     "Change in progress: \(ctx.lane.currentTitle ?? "none")"]
        if let problem = ctx.store.saveProblem { orbit.append(problem) }
        var sections = [
            DiagnosticsReport.Section("Orbit", orbit),
            DiagnosticsReport.Section("Features", FeatureID.allCases.map { id in
                let state = state(id)
                return "\(id.title): \(state.label)" + (state.detail.map { " — \($0)" } ?? "")
            }),
            DiagnosticsReport.Section("Helpers", Helper.allCases.map { helper in
                var line = "\(helper.label): \(Self.describe(status.run(of: helper)))"
                if let job = status.jobs[helper] {
                    line += ", started \(job.runs)×, last exit \(job.lastExit.map(String.init) ?? "none")"
                    if let signal = job.lastSignal { line += " (\(signal))" }
                }
                return line
            }),
            DiagnosticsReport.Section("Recent changes", journal.suffix(15).reversed().map { entry in
                "\(Self.stamp(entry.date))  \(entry.title)" + (entry.failed ? " — didn't work: \(entry.message ?? "")" : "")
                    + (entry.undone ? " (undone)" : "")
            }),
            DiagnosticsReport.Section("Activity", ctx.activity.recent(40).map { record in
                "\(Self.stamp(record.date))  [\(record.kind.rawValue)] \(record.ok ? "" : "FAILED ")\(record.title)"
                    + (record.detail.map { " — \($0)" } ?? "")
            })
        ]
        for helper in Watchdog.watched {
            let lines = probes.recentErrors(helper)
            if !lines.isEmpty { sections.append(DiagnosticsReport.Section("\(helper.rawValue) error log (last lines)", lines)) }
        }
        return DiagnosticsReport.render(sections, home: ctx.paths.home.path(percentEncoded: false), user: NSUserName())
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics(), forType: .string)
        show(Toast(ok: true, message: "Copied a report of Orbit's state (your name and home folder left out).", journalID: nil))
    }

    static func describe(_ run: HelperRun) -> String {
        switch run {
        case .notLoaded: "not loaded"
        case .loaded(true, let pid, _): "running" + (pid.map { " (pid \($0))" } ?? "")
        case .loaded(false, _, let exit): "loaded, not running" + (exit.map { ", last exit \($0)" } ?? "")
        }
    }

    static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }
}
