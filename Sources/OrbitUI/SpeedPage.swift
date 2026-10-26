import AppKit
import OrbitCore
import OrbitPlatform
import SwiftUI

extension AppModel {
    func readInstant() async {
        let on = await Task.detached(priority: .userInitiated) { [actions] in actions.instantGroupsOn() }.value
        if on != instantOn { instantOn = on }
    }

    func setInstant(_ groups: Set<SpeedTweak.Group>, on: Bool) {
        let every = groups.count == SpeedTweak.Group.allCases.count
        let title = every ? (on ? "Made the Mac feel instant" : "Put the Mac's animations back")
                          : "Turned \(on ? "on" : "off") " + groups.map { $0.title.lowercased() }.sorted().joined(separator: " and ")
        let key = every ? "instant-all" : "instant-" + groups.map(\.rawValue).sorted().joined(separator: "-")
        perform(key, title) { [actions] _ in await actions.setInstant(groups, on: on) }
    }

    var instantBusy: Bool { busy.contains { $0.hasPrefix("instant-") } }
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
        }
        .task(id: model.journal) { await model.readInstant() }
    }
}
