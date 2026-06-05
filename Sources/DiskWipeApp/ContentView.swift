import SwiftUI

struct ContentView: View {
    @StateObject private var engine = EngineRunner()
    @EnvironmentObject var loc: Loc

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                settingsCard
                actionButton
                progressCard
                if !engine.verdict.isEmpty { verdictBanner }
                logCard
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { engine.refreshDisks(); engine.startPolling() }
        .onDisappear { if !engine.running { engine.stopPolling() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.minus")
                .font(.system(size: 28)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(loc.t("tab.wipe")).font(.title2).bold()
                Text(loc.t("wipe.subtitle")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { engine.refreshDisks() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(engine.running)
        }
    }

    private var settingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(loc.t("common.disk"), systemImage: "internaldrive")
                        .frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
                    Picker("", selection: $engine.selected) {
                        ForEach(engine.disks) { d in Text(d.label).tag(Optional(d)) }
                    }.labelsHidden().disabled(engine.running)
                }
                HStack {
                    Label(loc.t("wipe.mode"), systemImage: "slider.horizontal.3")
                        .frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
                    Picker("", selection: $engine.mode) {
                        Text(loc.t("mode.full")).tag("full")
                        Text(loc.t("mode.quick")).tag("quick")
                    }.pickerStyle(.segmented).labelsHidden().disabled(engine.running)
                }
                Divider()
                HStack(spacing: 20) {
                    Toggle(loc.t("toggle.verify"), isOn: $engine.doVerify)
                        .disabled(engine.running || engine.mode != "full")
                    Toggle(loc.t("toggle.smartlong"), isOn: $engine.doSmartLong).disabled(engine.running)
                    Toggle(loc.t("toggle.eject"), isOn: $engine.doEject).disabled(engine.running)
                    Spacer()
                }
                if engine.selected != nil && !engine.running {
                    Label(loc.t("wipe.warning"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var actionButton: some View {
        Group {
            if engine.running {
                Button(role: .destructive) { engine.cancel() } label: {
                    Label(loc.t("wipe.cancel"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
            } else {
                Button { engine.start() } label: {
                    Label(loc.t("wipe.start"), systemImage: "play.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.selected == nil)
            }
        }
        .controlSize(.large)
    }

    private var progressCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                if engine.phases.isEmpty {
                    HStack {
                        Image(systemName: "list.bullet.clipboard").foregroundStyle(.secondary)
                        Text(loc.t("wipe.phasesAppear")).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(engine.phases) { ph in PhaseRow(phase: ph) }
                }
            }
        }
    }

    private var verdictBanner: some View {
        HStack {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            Text(engine.verdict).bold()
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.12)))
    }

    private var logCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label(loc.t("log"), systemImage: "text.alignleft").font(.caption).foregroundStyle(.secondary)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(engine.log.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading).id(i)
                            }
                        }
                    }
                    .frame(height: 150)
                    .onChange(of: engine.log.count) { _, n in
                        if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

struct PhaseRow: View {
    let phase: PhaseState
    @EnvironmentObject var loc: Loc

    private var icon: String {
        switch phase.status {
        case "done": return "checkmark.circle.fill"
        case "running": return "circle.dotted"
        case "failed": return "xmark.octagon.fill"
        default: return "circle"
        }
    }
    private var color: Color {
        switch phase.status {
        case "done": return .green
        case "running": return .blue
        case "failed": return .red
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(loc.t("phase.\(phase.id)")).bold()
                Spacer()
                if phase.status == "running" || phase.percent > 0 {
                    Text(String(format: "%.0f%%", phase.percent))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if phase.status == "running" && (phase.id == "erase_full" || phase.id == "verify" || phase.id == "smart_long") {
                ProgressView(value: phase.percent, total: 100)
                HStack(spacing: 16) {
                    speedTag(loc.t("speed.inst"), phase.instMBps)
                    speedTag(loc.t("speed.avg"), phase.avgMBps)
                    Label(EngineRunner.eta(phase.etaSec), systemImage: "clock")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if !phase.detail.isEmpty && (phase.status == "done" || phase.status == "failed") {
                Text(phase.detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func speedTag(_ label: String, _ mbps: Double) -> some View {
        HStack(spacing: 4) {
            Text(label + ":").font(.caption2).foregroundStyle(.secondary)
            Text(String(format: "%.0f MB/s", mbps))
                .font(.system(.caption, design: .monospaced).bold())
        }
    }
}

extension EngineRunner {
    static func eta(_ sec: Double) -> String {
        guard sec.isFinite, sec >= 0 else { return "--:--" }
        let s = Int(sec); let h = s / 3600, m = (s % 3600) / 60, x = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, x) : String(format: "%02d:%02d", m, x)
    }
}
