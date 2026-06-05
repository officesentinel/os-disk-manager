import SwiftUI

struct ScanView: View {
    @StateObject private var scan = ScanRunner()
    @EnvironmentObject var loc: Loc

    static let bandColors: [Color] = [
        .green, .mint, .yellow, .orange,
        Color(red: 0.95, green: 0.45, blue: 0.1), .red, Color(red: 0.4, green: 0, blue: 0)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                controls
                if !scan.buckets.isEmpty || scan.running { blockMap }
                legend
                if !scan.summary.isEmpty { summaryBanner }
            }.padding(18)
        }
        .onAppear { scan.refreshDisks(); scan.startPolling() }
        .onDisappear { if !scan.running { scan.stopPolling() } }
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform.path.ecg.rectangle").font(.title2).foregroundStyle(.tint)
            Text(loc.t("scan.title")).font(.title3).bold()
            Spacer()
            Button { scan.refreshDisks() } label: { Image(systemName: "arrow.clockwise") }.disabled(scan.running)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(loc.t("common.disk")).frame(width: 70, alignment: .leading)
                Picker("", selection: $scan.selected) {
                    ForEach(scan.disks) { d in Text(d.label).tag(Optional(d)) }
                }.labelsHidden().disabled(scan.running)
            }
            HStack {
                Text(loc.t("scan.mode")).frame(width: 70, alignment: .leading)
                Picker("", selection: $scan.mode) {
                    Text(loc.t("mode.read")).tag("read")
                    Text(loc.t("mode.verify")).tag("verify")
                }.pickerStyle(.segmented).labelsHidden().disabled(scan.running).frame(width: 280)
                Spacer()
            }
            HStack {
                Text(loc.t("scan.threshold")).frame(width: 70, alignment: .leading)
                Stepper(value: $scan.thresholdMs, in: 20...2000, step: 10) {
                    Text("\(scan.thresholdMs) ms").font(.system(.body, design: .monospaced))
                }.disabled(scan.running).frame(width: 200)
                Text(loc.t("scan.thresholdHint")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if scan.running {
                    Button(role: .destructive) { scan.cancel() } label: {
                        Label(loc.t("scan.stop"), systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                } else {
                    Button { scan.start() } label: {
                        Label(loc.t("scan.start"), systemImage: "play.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(scan.selected == nil)
                }
            }
            if scan.running || scan.percent > 0 {
                ProgressView(value: scan.percent, total: 100)
                HStack(spacing: 18) {
                    stat(loc.t("scan.progress"), String(format: "%.1f%%", scan.percent))
                    stat(loc.t("scan.inst"), String(format: "%.0f MB/s", scan.instMBps))
                    stat(loc.t("scan.avg"), String(format: "%.0f MB/s", scan.avgMBps))
                    stat(loc.t("scan.maxlat"), "\(scan.maxMs) ms")
                }
            }
        }
    }

    private func stat(_ l: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(l + ":").font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.system(.caption, design: .monospaced).bold())
        }
    }

    private var blockMap: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc.t("scan.surfacemap")).font(.headline)
            let cols = Array(repeating: GridItem(.fixed(14), spacing: 2), count: 20)
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(Array(scan.buckets.enumerated()), id: \.offset) { _, band in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(band < 0 ? Color.gray.opacity(0.15) : Self.bandColors[min(6, band)])
                        .frame(width: 14, height: 14)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.04)))
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc.t("scan.bands")).font(.headline)
            let cols = Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2)
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(0..<7, id: \.self) { i in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Self.bandColors[i]).frame(width: 14, height: 14)
                        Text(loc.t("band.\(i)")).font(.caption)
                        Spacer()
                        Text("\(scan.bands[i])").font(.system(.caption, design: .monospaced).bold())
                            .foregroundStyle(scan.bands[i] > 0 && i >= 5 ? .red : .primary)
                    }
                }
            }
        }
    }

    private var summaryBanner: some View {
        Text(scan.summary)
            .font(.system(.caption, design: .monospaced))
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill((scan.bands[5] == 0 && scan.bands[6] == 0 ? Color.green : Color.orange).opacity(0.12)))
    }
}
