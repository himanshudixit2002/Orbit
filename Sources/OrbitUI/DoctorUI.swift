import AppKit
import OrbitCore
import OrbitPlatform
import SwiftUI

extension AppModel {
    /// Looks for problems (off the main thread) and shows what it finds.
    func runDoctor() {
        guard !isSnapshot, !doctorRunning else { return }
        doctorRunning = true
        let probe = DoctorProbe(ctx)
        Task {
            let facts = await Task.detached(priority: .utility) { probe.facts() }.value
            doctor = Doctor.findings(facts, ignored: Set(settings.doctorIgnored))
            doctorChecked = Date()
            doctorRunning = false
        }
    }

    func fix(_ finding: DoctorFinding) {
        guard let fix = finding.fix else { return }
        // Showing something isn't a change: no history entry.
        switch fix {
        case .open(let page):
            self.page = page
            return
        case .showInFinder(let paths):
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
            return
        case .openSettings(let pane):
            if let url = URL(string: pane.url) { NSWorkspace.shared.open(url) }
            return
        default:
            break
        }
        Task {
            await performNow("doctor-\(finding.id)", fix.historyTitle) { [actions] policy in try await actions.fix(fix, policy: policy) }
            if finding.id.hasPrefix("speed-") { runSpeedCheck() } else { runDoctor() }
        }
    }

    func ignore(_ finding: DoctorFinding) {
        ctx.store.updateSettings { $0.doctorIgnored.append(finding.id) }
        settings = ctx.store.settings
        doctor.removeAll { $0.id == finding.id }
        speedFindings.removeAll { $0.id == finding.id }
    }

    func showIgnoredFindings() {
        ctx.store.updateSettings { $0.doctorIgnored = [] }
        settings = ctx.store.settings
        runDoctor()
        runSpeedCheck()
    }
}

/// The Doctor's findings, each with its fix and an Ignore.
struct DoctorPanel: View {
    @Environment(AppModel.self) private var model
    @State private var confirming: DoctorFinding?

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Doctor").font(.title3.weight(.semibold))
                    Spacer()
                    if model.doctorRunning { ProgressView().controlSize(.small) }
                    Button("Look again") { model.runDoctor() }.buttonStyle(.glass).disabled(model.doctorRunning)
                }
                if model.doctor.isEmpty {
                    Label(model.doctorChecked == nil ? "Having a look…" : "Nothing needs fixing.",
                          systemImage: model.doctorChecked == nil ? "stethoscope" : "checkmark.seal.fill")
                        .foregroundStyle(model.doctorChecked == nil ? Color.secondary : Color.green)
                }
                ForEach(model.doctor) { finding in
                    FindingRow(finding: finding) { confirming = finding }
                }
                if !model.settings.doctorIgnored.isEmpty {
                    Button("Show \(model.settings.doctorIgnored.count) ignored") { model.showIgnoredFindings() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
        .onAppear {
            if model.doctorChecked.map({ Date().timeIntervalSince($0) > 300 }) ?? true { model.runDoctor() }
        }
        .confirmationDialog(Text(confirming?.title ?? ""), isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { finding in
            Button(finding.fix?.label ?? "Fix") { model.fix(finding) }
            Button("Cancel", role: .cancel) {}
        } message: { finding in
            Text("\(finding.detail) You can undo this on the Health page.")
        }
    }
}

/// One finding (the Doctor's or the Speed check's): what it is, its fix and Ignore. Fixes that move or
/// stop things call `confirm` first; the rest run at once.
struct FindingRow: View {
    @Environment(AppModel.self) private var model
    let finding: DoctorFinding
    let confirm: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: finding.symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(finding.severity == .problem ? Color.orange : finding.severity == .tidy ? Hue.blue.top : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(.body.weight(.medium))
                Text(finding.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let fix = finding.fix {
                Button(fix.label) {
                    if fix.asksFirst { confirm() } else { model.fix(finding) }
                }
                .buttonStyle(.glassProminent)
                .disabled(model.isBusy("doctor-\(finding.id)"))
            }
            Button("Ignore") { model.ignore(finding) }.buttonStyle(.glass)
        }
        .padding(.vertical, 3)
    }
}

