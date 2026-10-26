import Charts
import OrbitCore
import OrbitPlatform
import SwiftUI

struct MonitorPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.monitor.latest
        let history = model.monitor.history
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(page: .monitor)

            GlassPanel(glow: Hue.green.top) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Processor", systemImage: "cpu").font(.title3.weight(.semibold))
                        Spacer()
                        Text(percent(s.cpu)).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Chart(Array(history.enumerated()), id: \.offset) { i, sample in
                        AreaMark(x: .value("Time", i), y: .value("Busy", sample.cpu * 100))
                            .foregroundStyle(LinearGradient(colors: [Hue.green.top.opacity(0.5), Hue.green.top.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Time", i), y: .value("Busy", sample.cpu * 100))
                            .foregroundStyle(Hue.green.top)
                            .interpolationMethod(.catmullRom)
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis(.hidden)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Processor use, recent")
                    .accessibilityValue(ChartSummary.levels(history.map(\.cpu), as: percent))
                    .chartYAxis {
                        AxisMarks(values: [0, 50, 100]) { value in
                            AxisGridLine()
                            AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                        }
                    }
                    .frame(height: 140)
                    Text("Each core").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(s.perCore.enumerated()), id: \.offset) { _, load in
                            VStack(spacing: 3) {
                                GeometryReader { geo in
                                    VStack {
                                        Spacer(minLength: 0)
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Hue.green.gradient)
                                            .frame(height: max(3, geo.size.height * load))
                                    }
                                }
                                .frame(height: 50)
                                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Each core")
                    .accessibilityValue(ChartSummary.cores(s.perCore))
                }
            }

            HStack(alignment: .top, spacing: 16) {
                GlassPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Memory", systemImage: "memorychip").font(.title3.weight(.semibold))
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(bytes(Int64(s.memoryUsed))).font(.system(size: 26, weight: .bold, design: .rounded))
                            Text("of \(bytes(Int64(s.memoryTotal)))").foregroundStyle(.secondary)
                        }
                        ProgressView(value: s.memoryFraction).tint(s.memoryPressure >= 2 ? .orange : Hue.purple.top)
                        Label(pressureText(s.memoryPressure), systemImage: s.memoryPressure >= 2 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .foregroundStyle(s.memoryPressure >= 2 ? .orange : .green)
                            .font(.callout)
                    }
                }
                GlassPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Storage", systemImage: "internaldrive").font(.title3.weight(.semibold))
                        Chart {
                            SectorMark(angle: .value("Used", Double(s.diskTotal - s.diskFree)), innerRadius: .ratio(0.62), angularInset: 2)
                                .foregroundStyle(Hue.blue.gradient)
                            SectorMark(angle: .value("Free", Double(s.diskFree)), innerRadius: .ratio(0.62), angularInset: 2)
                                .foregroundStyle(.quaternary)
                        }
                        .frame(height: 110)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Storage")
                        .accessibilityValue("\(diskBytes(s.diskFree)) free of \(diskBytes(s.diskTotal))")
                        .overlay {
                            VStack(spacing: 0) {
                                Text(diskBytes(s.diskFree)).font(.headline)
                                Text("free").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            GlassPanel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Network", systemImage: "network").font(.title3.weight(.semibold))
                        Spacer()
                        Label(speed(s.download), systemImage: "arrow.down").foregroundStyle(Hue.cyan.top)
                        Label(speed(s.upload), systemImage: "arrow.up").foregroundStyle(Hue.pink.top)
                    }
                    .monospacedDigit()
                    Chart(Array(history.enumerated()), id: \.offset) { i, sample in
                        LineMark(x: .value("Time", i), y: .value("Speed", sample.download), series: .value("Way", "Down"))
                            .foregroundStyle(Hue.cyan.top)
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Time", i), y: .value("Speed", sample.upload), series: .value("Way", "Up"))
                            .foregroundStyle(Hue.pink.top)
                            .interpolationMethod(.catmullRom)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel { Text(speed(value.as(Double.self) ?? 0)) }
                        }
                    }
                    .frame(height: 120)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Network speed, recent")
                    .accessibilityValue("Download: " + ChartSummary.levels(history.map(\.download), as: speed)
                                        + ". Upload: " + ChartSummary.levels(history.map(\.upload), as: speed))
                }
            }
        }
        .liveStats(model.monitor)
    }

    func pressureText(_ level: Int) -> String {
        switch level {
        case 4...: "Memory is very tight: close a few apps."
        case 2...3: "Memory is getting tight."
        default: "Plenty of memory to go round."
        }
    }
}

/// What a chart shows, in words, for VoiceOver.
enum ChartSummary {
    /// "now 23%, average 18%, highest 54%"
    static func levels(_ values: [Double], as format: (Double) -> String) -> String {
        guard let now = values.last else { return "No readings yet" }
        let average = values.reduce(0, +) / Double(values.count)
        return "now \(format(now)), average \(format(average)), highest \(format(values.max() ?? now))"
    }

    /// "busiest 55%, quietest 5%"
    static func cores(_ loads: [Double]) -> String {
        guard let busiest = loads.max(), let quietest = loads.min() else { return "No readings yet" }
        return "\(loads.count) cores: busiest \(percent(busiest)), quietest \(percent(quietest))"
    }
}
