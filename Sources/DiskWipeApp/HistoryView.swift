import SwiftUI
import Charts
import AppKit

struct HistoryView: View {
    @StateObject private var hm = HistoryManager()
    @EnvironmentObject var loc: Loc
    @State private var showCompare = false

    var body: some View {
        HStack(spacing: 0) {
            disksSidebar
                .frame(width: 280)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            Divider()
            detailPane
        }
        .onAppear { hm.refresh() }
        .sheet(isPresented: $showCompare) {
            CompareSheet(hm: hm) { showCompare = false }.environmentObject(loc)
        }
    }

    // MARK: - Left sidebar: list of disks ever seen

    private var disksSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(loc.t("history.disksList")).font(.headline)
                Spacer()
                Button { hm.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            if hm.disks.isEmpty {
                Text(loc.t("history.noDisks"))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(14)
                Spacer()
            } else {
                List(hm.disks, selection: Binding(
                    get: { hm.selectedDisk?.serial },
                    set: { sel in hm.selectedDisk = hm.disks.first { $0.serial == sel } }
                )) { d in
                    diskRow(d).tag(d.serial)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func diskRow(_ d: DiskHistoryItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: d.isSSD ? "memorychip" : "internaldrive")
                .foregroundStyle(d.latestHealth ? .green : .red)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.model).bold().lineLimit(1)
                Text("\(d.serial) · \(String(format: "%.0f GB", d.sizeGB))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text("\(loc.t("history.lastSeen")): \(prettyDate(d.lastSeen))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func prettyDate(_ s: String) -> String {
        // input: "yyyy-MM-dd_HH-mm-ss" → "yyyy-MM-dd HH:mm"
        let cleaned = s.replacingOccurrences(of: "_", with: " ")
        return String(cleaned.prefix(16)).replacingOccurrences(of: "-", with: ":", options: [], range: cleaned.range(of: ":")) ?? String(cleaned.prefix(16))
    }

    // MARK: - Right detail pane

    private var detailPane: some View {
        Group {
            if let disk = hm.selectedDisk {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // 1. Identity hero — model + family + source + headline health/verdict
                        diskHeader(disk)
                        // 2. Static specs chip row (DRAM / NAND / PLP / Discard / Sanitize / Class)
                        //    Stays the same across snapshots — show once.
                        if let smart = hm.fullSnapshot?["smart"] as? [String: Any] {
                            staticSpecsCard(smart: smart)
                            currentStateCard(smart: smart, sizeBytes: Int64(disk.sizeGB * 1e9))
                        }
                        if hm.snapshots.count >= 2 { trendCharts }
                        timelineCard
                        if let s = hm.selectedSnapshot { snapshotDetailCard(s) }
                    }
                    .padding(18)
                }
            } else {
                ContentUnavailableView(loc.t("history.noDisks"), systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Card with the static specs chips that don't change between snapshots.
    @ViewBuilder
    private func staticSpecsCard(smart: [String: Any]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent").foregroundStyle(.tint)
                    Text(loc.t("history.staticSpecs")).font(.headline)
                    Spacer()
                    sourceMicroBadge(smart["dataSource"] as? String)
                }
                // Use the same chip styles as Dashboard via inline mini-chips here.
                HFlow {
                    // Class
                    chipInline(label: loc.t("tier.label"),
                               value: tierDisplay(smart["tier"] as? String),
                               color: tierColor(smart["tier"] as? String))
                    // DRAM
                    chipInline(label: loc.t("cache.label"),
                               value: tristate(smart["dramCache"] as? Bool, yes: loc.t("cache.yes"), no: loc.t("cache.no"), nodata: loc.t("cache.unknown")),
                               color: tristateColor(smart["dramCache"] as? Bool))
                    // NAND
                    chipInline(label: loc.t("nand.label"),
                               value: (smart["nandType"] as? String) ?? loc.t("nand.unknown"),
                               color: nandColor(smart["nandType"] as? String))
                    // PLP
                    chipInline(label: loc.t("plp.label"),
                               value: tristate(smart["plp"] as? Bool, yes: loc.t("plp.yes"), no: loc.t("plp.no"), nodata: loc.t("plp.unknown")),
                               color: tristateColor(smart["plp"] as? Bool))
                    // Discard
                    chipInline(label: (smart["discardMechanism"] as? String) ?? "TRIM",
                               value: tristate(smart["trimSupported"] as? Bool, yes: loc.t("trim.yes"), no: loc.t("trim.no"), nodata: loc.t("trim.nodata")) + ((smart["trimLevel"] as? String).map { " (\($0))" } ?? ""),
                               color: tristateColor(smart["trimSupported"] as? Bool))
                    // Sanitize
                    let san = smart["sanitizeMethods"] as? [String] ?? []
                    chipInline(label: loc.t("sanitize.label"),
                               value: san.isEmpty ? loc.t("sanitize.none") : "\(san.count)",
                               color: san.isEmpty ? .secondary : .orange)
                }
            }
        }
    }

    /// Big-numbers card showing the latest dynamic state + endurance bar if known.
    @ViewBuilder
    private func currentStateCard(smart: [String: Any], sizeBytes: Int64) -> some View {
        let life = smart["lifeLeftPercent"] as? Int
        let wear = smart["wearPercentUsed"] as? Int
        let temp = smart["temperatureC"] as? Int ?? 0
        let poh = smart["powerOnHours"] as? Int ?? 0
        let cycles = smart["powerCycles"] as? Int ?? 0
        let attrs = smart["attributes"] as? [[String: Any]] ?? []
        let defects = attrs.filter { [5,187,197,198].contains($0["id"] as? Int ?? 0) }
                           .reduce(0) { $0 + ($1["raw"] as? Int ?? 0) }
        let tbwPerTb = smart["tbwPerTb"] as? Int
        let sizeTB = Double(sizeBytes) / 1_000_000_000_000.0
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "waveform.path.ecg").foregroundStyle(.tint)
                    Text(loc.t("history.currentState")).font(.headline)
                    Spacer()
                }
                HStack(spacing: 16) {
                    bigStat(value: life.map { "\($0)%" } ?? "—", label: loc.t("history.health"),
                            color: life.map { $0 > 50 ? .green : ($0 > 20 ? .orange : .red) } ?? .secondary,
                            icon: "heart.fill")
                    bigStat(value: "\(temp)°", label: loc.t("gauge.temp"),
                            color: temp < 45 ? .green : (temp < 60 ? .orange : .red),
                            icon: "thermometer.medium")
                    bigStat(value: "\(poh)", label: loc.t("stat.poweron"),
                            color: poh > 30000 ? .orange : .blue,
                            icon: "clock.fill")
                    bigStat(value: "\(cycles)", label: loc.t("stat.cycles"),
                            color: .blue,
                            icon: "bolt.fill")
                    bigStat(value: "\(defects)", label: loc.t("stat.defects"),
                            color: defects == 0 ? .green : .red,
                            icon: "exclamationmark.triangle.fill")
                    Spacer()
                }
                // Endurance progress bar — only when both rated TBW and wear are known.
                if let tbw = tbwPerTb, let pct = wear {
                    let totalTbw = Double(tbw) * sizeTB
                    let usedTb = totalTbw * Double(pct) / 100.0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "speedometer").foregroundStyle(.tint)
                            Text(loc.t("tbw.title")).font(.subheadline).bold()
                            Spacer()
                            Text(String(format: "%.1f TB %@ %.0f TBW · %d%%",
                                        usedTb, loc.t("tbw.of"), totalTbw, pct))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15))
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(LinearGradient(colors: [.green, .green, .yellow, .orange, .red],
                                                          startPoint: .leading, endPoint: .trailing))
                                    .frame(width: geo.size.width * CGFloat(min(100, max(0, pct))) / 100)
                            }
                        }.frame(height: 10)
                    }.padding(.top, 6)
                }
            }
        }
    }

    /// One big-number stat for the current-state row.
    private func bigStat(value: String, label: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption).foregroundStyle(color)
                Text(value).font(.system(.title2, design: .rounded)).bold().foregroundStyle(color)
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Simple wrap-layout that flows children onto multiple rows when width is exceeded.
    private struct HFlow: Layout {
        var spacing: CGFloat = 6
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let containerWidth = proposal.width ?? .infinity
            var rowWidth: CGFloat = 0
            var totalHeight: CGFloat = 0
            var rowHeight: CGFloat = 0
            for sub in subviews {
                let s = sub.sizeThatFits(.unspecified)
                if rowWidth + s.width > containerWidth && rowWidth > 0 {
                    totalHeight += rowHeight + spacing
                    rowWidth = 0
                    rowHeight = 0
                }
                rowWidth += s.width + spacing
                rowHeight = max(rowHeight, s.height)
            }
            totalHeight += rowHeight
            return CGSize(width: containerWidth, height: totalHeight)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            var x: CGFloat = bounds.minX
            var y: CGFloat = bounds.minY
            var rowHeight: CGFloat = 0
            for sub in subviews {
                let s = sub.sizeThatFits(.unspecified)
                if x + s.width > bounds.maxX && x > bounds.minX {
                    x = bounds.minX
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                sub.place(at: CGPoint(x: x, y: y),
                          proposal: ProposedViewSize(width: s.width, height: s.height))
                x += s.width + spacing
                rowHeight = max(rowHeight, s.height)
            }
        }
    }

    /// Tiny "Source: DB/smartctl" badge for the static-specs card header.
    @ViewBuilder
    private func sourceMicroBadge(_ source: String?) -> some View {
        let (color, label): (Color, String) = {
            switch source {
            case "OurDB":    return (.green, "DB")
            case "smartctl": return (.blue, "smartctl")
            default:         return (.secondary, "—")
            }
        }()
        Text("\(loc.t("source.label")): \(label)")
            .font(.caption2.bold()).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
    }

    // MARK: - helpers used by static-specs chips
    private func tristate(_ v: Bool?, yes: String, no: String, nodata: String) -> String {
        switch v {
        case .some(true): return yes
        case .some(false): return no
        case .none: return nodata
        }
    }
    private func tristateColor(_ v: Bool?) -> Color {
        switch v {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .secondary
        }
    }
    private func tierDisplay(_ t: String?) -> String {
        switch t { case "enterprise": return loc.t("tier.enterprise")
                  case "consumer": return loc.t("tier.consumer")
                  default: return loc.t("tier.unknown") }
    }
    private func tierColor(_ t: String?) -> Color {
        switch t { case "enterprise": return .purple
                  case "consumer": return .blue
                  default: return .secondary }
    }
    private func nandColor(_ n: String?) -> Color {
        let u = (n ?? "").uppercased()
        if u.contains("SLC") || u.contains("MLC") { return .green }
        if u.contains("TLC") { return .blue }
        if u.contains("QLC") { return .orange }
        return .secondary
    }
    private func chipInline(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.bold()).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.12)))
    }

    private func diskHeader(_ d: DiskHistoryItem) -> some View {
        Card {
            HStack(spacing: 16) {
                Image(systemName: d.isSSD ? "memorychip" : "internaldrive")
                    .font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.model).font(.title3).bold()
                    Text("\(loc.t("id.sn")) \(d.serial) · \(String(format: "%.1f GB", d.sizeGB)) · \(d.interface)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(loc.t("history.snapshots", d.snapshotCount))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if let p = d.latestLife {
                    let c: Color = p > 50 ? .green : (p > 20 ? .orange : .red)
                    VStack(alignment: .center, spacing: 0) {
                        Text("\(p)%").font(.system(.largeTitle, design: .rounded).bold()).foregroundStyle(c)
                        Text(loc.t("history.health")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .trailing, spacing: 4) {
                    Image(systemName: d.latestHealth ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .font(.title2).foregroundStyle(d.latestHealth ? .green : .red)
                    Text(d.latestVerdict).font(.caption).multilineTextAlignment(.trailing)
                }
            }
        }
    }

    // 2x2 grid of trend charts.
    private var trendCharts: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 14) {
            trendChart(title: loc.t("history.chartWear"), color: .orange,
                       values: hm.snapshots.compactMap { s in s.wearPercentUsed.map { (s.date, Double($0)) } })
            trendChart(title: loc.t("history.chartTemp"), color: .red,
                       values: hm.snapshots.map { ($0.date, Double($0.temperatureC)) })
            trendChart(title: loc.t("history.chartDefects"), color: .pink,
                       values: hm.snapshots.map { ($0.date, Double($0.defects)) })
            trendChart(title: loc.t("history.chartPOH"), color: .blue,
                       values: hm.snapshots.map { ($0.date, Double($0.powerOnHours)) })
        }
    }

    private func trendChart(title: String, color: Color, values: [(Date, Double)]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).bold().foregroundStyle(.secondary)
                if values.isEmpty {
                    Text("—").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Chart {
                        ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                            LineMark(x: .value("t", v.0), y: .value("v", v.1))
                                .foregroundStyle(color)
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("t", v.0), y: .value("v", v.1))
                                .foregroundStyle(color)
                                .symbolSize(40)
                        }
                    }
                    .frame(height: 110)
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                }
            }
        }
    }

    // Timeline of snapshots: selectable rows with multi-checkbox for compare.
    private var timelineCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(loc.t("history.timeline")).font(.headline)
                    Spacer()
                    if hm.compareSelection.count == 2 {
                        Button {
                            showCompare = true
                        } label: { Label(loc.t("history.compare"), systemImage: "rectangle.on.rectangle") }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Text(loc.t("history.compareHint")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(hm.snapshots.reversed()) { s in snapshotRow(s) }
            }
        }
    }

    private func snapshotRow(_ s: SnapshotSummary) -> some View {
        let isSelected = hm.selectedSnapshot?.path == s.path
        let inCompare = hm.compareSelection.contains(s.path)
        return HStack(spacing: 10) {
            Button { hm.toggleCompare(s.path) } label: {
                Image(systemName: inCompare ? "checkmark.square.fill" : "square")
                    .foregroundStyle(inCompare ? .blue : .secondary)
            }.buttonStyle(.plain)
            Circle().fill(s.healthPassed ? Color.green : Color.red).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(prettyTimestamp(s.timestamp))
                        .font(.system(.body, design: .monospaced))
                    HStack(spacing: 3) {
                        Image(systemName: kindIcon(s.kind)).font(.caption2)
                        Text(kindLabel(s.kind))
                    }
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(kindColor(s.kind).opacity(0.18)))
                    .foregroundStyle(kindColor(s.kind))
                }
                Text(s.verdict).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 10) {
                healthPill(s.lifeLeftPercent)
                stat("\(s.temperatureC)°", "T")
                stat("\(s.defects)", "D")
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            hm.selectedSnapshot = s
            hm.loadFullSnapshot(path: s.path)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.system(.caption, design: .monospaced).bold())
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }.frame(width: 36)
    }

    private func prettyTimestamp(_ s: String) -> String {
        // "yyyy-MM-dd_HH-mm-ss" -> "yyyy-MM-dd HH:mm:ss"
        guard s.count >= 19 else { return s }
        var chars = Array(s); chars[10] = " "; chars[13] = ":"; chars[16] = ":"
        return String(chars)
    }

    // Selected snapshot detail: full SMART attribute table.
    private func snapshotDetailCard(_ s: SnapshotSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: kindIcon(s.kind))
                        .font(.title3).foregroundStyle(kindColor(s.kind))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kindLabel(s.kind))
                            .font(.headline).foregroundStyle(kindColor(s.kind))
                        Text(prettyTimestamp(s.timestamp))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(loc.t("history.detail")).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.bottom, 4)
                // Show wipe details (min/avg/max speeds) when this snapshot is from a wipe.
                if let full = hm.fullSnapshot,
                   let wipe = full["wipe"] as? [String: Any] {
                    wipeDetails(wipe)
                    Divider()
                }
                // Show surface-scan details when this snapshot is from a scan.
                if let full = hm.fullSnapshot,
                   let scan = full["scan"] as? [String: Any] {
                    scanDetails(scan)
                    Divider()
                }
                if let full = hm.fullSnapshot,
                   let smart = full["smart"] as? [String: Any],
                   let attrs = smart["attributes"] as? [[String: Any]] {
                    healthHeadline(current: s, smart: smart)
                    // This snapshot's dynamic metrics only — static specs live in the card above.
                    HStack(spacing: 16) {
                        snapStat("\(smart["powerOnHours"] as? Int ?? 0) \(loc.t("unit.h"))", loc.t("stat.poweron"))
                        snapStat("\(smart["powerCycles"] as? Int ?? 0)", loc.t("stat.cycles"))
                        snapStat("\(smart["temperatureC"] as? Int ?? 0)°", loc.t("gauge.temp"))
                        snapStat((smart["lifeLeftPercent"] as? Int).map { "\($0)%" } ?? "—", loc.t("gauge.life"))
                        Spacer()
                    }
                    Divider()
                    HStack {
                        Text("№").frame(width: 30, alignment: .leading)
                        Text(loc.t("smart.col.attr")).frame(width: 180, alignment: .leading)
                        Text(loc.t("smart.col.value")).frame(width: 72, alignment: .trailing)
                        Text(loc.t("smart.col.thresh")).frame(width: 60, alignment: .trailing)
                        Text(loc.t("smart.col.raw")).frame(maxWidth: .infinity, alignment: .trailing)
                    }.font(.caption2).foregroundStyle(.secondary)
                    ForEach(Array(attrs.enumerated()), id: \.offset) { _, a in
                        HStack {
                            Circle().fill(statusColor(a["status"] as? String ?? "ok"))
                                .frame(width: 7, height: 7)
                            Text("\(a["id"] as? Int ?? 0)").frame(width: 23, alignment: .leading)
                            Text(a["name"] as? String ?? "").frame(width: 180, alignment: .leading).lineLimit(1)
                            Text("\(a["value"] as? Int ?? 0)").frame(width: 72, alignment: .trailing)
                            Text("\(a["thresh"] as? Int ?? 0)").frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
                            Text("\(a["rawString"] as? String ?? "")").frame(maxWidth: .infinity, alignment: .trailing)
                        }.font(.system(.caption, design: .monospaced)).padding(.vertical, 1)
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text(loc.t("dash.wait")).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    // Render the wipe block (mode + erase/verify speeds + long-test summary).
    @ViewBuilder
    private func wipeDetails(_ wipe: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "eraser.fill").foregroundStyle(.tint)
                Text(loc.t("wipe.detail.title")).font(.headline)
                Spacer()
                if let mode = wipe["mode"] as? String {
                    Text("\(loc.t("wipe.detail.mode")): \(mode)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let e = wipe["eraseSpeed"] as? [String: Any] {
                speedRow(label: loc.t("wipe.detail.erase"), icon: "arrow.down.to.line", stats: e)
            }
            if let v = wipe["verifySpeed"] as? [String: Any] {
                speedRow(label: loc.t("wipe.detail.verify"), icon: "arrow.up.to.line", stats: v)
            }
            if let lt = wipe["longTestSummary"] as? String, !lt.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.shield").foregroundStyle(.secondary)
                    Text(loc.t("wipe.detail.longTest") + ":").font(.caption).foregroundStyle(.secondary)
                    Text(lt).font(.system(.caption, design: .monospaced)).lineLimit(2)
                }
            }
        }
    }

    /// One row: "Erase: min ... / avg ... / max ... MB/s · elapsed mm:ss"
    private func speedRow(label: String, icon: String, stats: [String: Any]) -> some View {
        let mn = stats["minMBps"] as? Double ?? 0
        let av = stats["avgMBps"] as? Double ?? 0
        let mx = stats["maxMBps"] as? Double ?? 0
        let secs = Int(stats["elapsedSec"] as? Double ?? 0)
        let elapsed = String(format: "%d:%02d", secs / 60, secs % 60)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.tint)
                Text(label).bold()
                Spacer()
                Label(elapsed, systemImage: "clock")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                speedPill(loc.t("wipe.detail.min"), mn, .orange)
                speedPill(loc.t("wipe.detail.avg"), av, .blue)
                speedPill(loc.t("wipe.detail.max"), mx, .green)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    // Render the scan block (threshold + band counts + block map preview).
    @ViewBuilder
    private func scanDetails(_ scan: [String: Any]) -> some View {
        let bands = scan["bands"] as? [Int] ?? [Int](repeating: 0, count: 7)
        let buckets = scan["buckets"] as? [Int] ?? []
        let thresh = scan["thresholdMs"] as? Int ?? 0
        let avgMs = scan["avgMs"] as? Double ?? 0
        let maxMs = scan["maxMs"] as? Int ?? 0
        let blocks = scan["blocksScanned"] as? Int ?? 0
        let elapsed = scan["elapsed"] as? String ?? ""
        let bad = (bands.count > 5 ? bands[5] : 0) + (bands.count > 6 ? bands[6] : 0)
        let ok = scan["ok"] as? Bool ?? (bad == 0)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform.path.ecg.rectangle").foregroundStyle(.purple)
                Text(loc.t("scan.detail.title")).font(.headline)
                Spacer()
                Text(ok ? "🟢 OK" : "🟠 \(loc.t("scan.detail.bad"))")
                    .font(.caption).bold()
                    .foregroundStyle(ok ? .green : .orange)
            }
            // Headline numbers
            HStack(spacing: 18) {
                snapStat("\(thresh) ms", loc.t("scan.detail.threshold"))
                snapStat(String(format: "%.1f ms", avgMs), loc.t("scan.detail.avgMs"))
                snapStat("\(maxMs) ms", loc.t("scan.detail.maxMs"))
                snapStat("\(blocks)", loc.t("scan.detail.blocks"))
                snapStat("\(bad)", loc.t("scan.detail.bad"))
                if !elapsed.isEmpty {
                    snapStat(elapsed, loc.t("wipe.detail.elapsed"))
                }
            }
            // Band breakdown (same colours as Scan tab)
            Text(loc.t("scan.detail.bandsTitle")).font(.caption).bold().padding(.top, 2)
            let bandColors: [Color] = [.green, .mint, .yellow, .orange,
                                       Color(red: 0.95, green: 0.45, blue: 0.1), .red,
                                       Color(red: 0.4, green: 0, blue: 0)]
            let cols = Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2)
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(0..<7, id: \.self) { i in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(bandColors[i])
                            .frame(width: 14, height: 14)
                        Text(loc.t("band.\(i)")).font(.caption)
                        Spacer()
                        Text("\(bands.indices.contains(i) ? bands[i] : 0)")
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundStyle((i >= 5 && (bands.indices.contains(i) ? bands[i] : 0) > 0) ? .red : .primary)
                    }
                }
            }
            // Compact block map preview
            if !buckets.isEmpty {
                Text(loc.t("scan.surfacemap")).font(.caption).bold().padding(.top, 4)
                let gridCols = Array(repeating: GridItem(.fixed(10), spacing: 1), count: 30)
                LazyVGrid(columns: gridCols, spacing: 1) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { _, band in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(band < 0 ? Color.gray.opacity(0.15) : bandColors[min(6, band)])
                            .frame(width: 10, height: 10)
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.04)))
            }
        }
    }

    private func speedPill(_ label: String, _ mbps: Double, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(String(format: "%.1f MB/s", mbps))
                .font(.system(.caption, design: .monospaced).bold())
        }
    }

    /// Small coloured pill showing "❤️ NN%" in the snapshot list row.
    @ViewBuilder
    private func healthPill(_ life: Int?) -> some View {
        if let p = life {
            let c: Color = p > 50 ? .green : (p > 20 ? .orange : .red)
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").foregroundStyle(c).font(.caption2)
                Text("\(p)%").font(.system(.caption, design: .monospaced).bold()).foregroundStyle(c)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(c.opacity(0.15)))
        } else {
            stat("—", "L")
        }
    }

    /// Big "Здоровье: NN%" headline with delta vs previous snapshot + progress bar.
    @ViewBuilder
    private func healthHeadline(current s: SnapshotSummary, smart: [String: Any]) -> some View {
        let life = smart["lifeLeftPercent"] as? Int ?? s.lifeLeftPercent ?? 0
        let prev = previousSnapshot(of: s)
        let first = hm.snapshots.first
        let referenceForDelta = prev ?? first   // delta vs previous if any, else vs first
        let referenceLife = referenceForDelta?.lifeLeftPercent
        let delta: Int? = referenceLife.map { life - $0 }
        let c: Color = life > 50 ? .green : (life > 20 ? .orange : .red)
        let refLabel: String = {
            if let p = prev { return prettyTimestamp(p.timestamp) }
            return loc.t("history.first")
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "heart.text.square.fill").font(.title2).foregroundStyle(c)
                Text(loc.t("history.health") + ":").font(.headline).foregroundStyle(.secondary)
                Text("\(life)%").font(.system(.title, design: .rounded).bold()).foregroundStyle(c)
                if let d = delta, referenceForDelta != nil, referenceForDelta?.path != s.path {
                    deltaBadge(d)
                    Text(String(format: loc.t("history.deltaSince"), refLabel))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(loc.t("history.now")).font(.caption).foregroundStyle(.secondary)
            }
            // Coloured progress bar visualising the value.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4).fill(c)
                        .frame(width: geo.size.width * CGFloat(life) / 100)
                }
            }.frame(height: 10)
        }
    }

    /// "▼ −1%" / "▲ +2%" badge with colour.
    private func deltaBadge(_ d: Int) -> some View {
        let symbol: String = d > 0 ? "arrow.up" : (d < 0 ? "arrow.down" : "minus")
        let colour: Color = d > 0 ? .green : (d < 0 ? .red : .secondary)
        let txt = d == 0 ? "0%" : (d > 0 ? "+\(d)%" : "\(d)%")
        return HStack(spacing: 2) {
            Image(systemName: symbol).font(.caption2)
            Text(txt).font(.system(.caption, design: .monospaced).bold())
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(colour.opacity(0.18)))
        .foregroundStyle(colour)
    }

    /// Snapshot immediately preceding `s` in time, or nil if none.
    private func previousSnapshot(of s: SnapshotSummary) -> SnapshotSummary? {
        guard let idx = hm.snapshots.firstIndex(of: s), idx > 0 else { return nil }
        return hm.snapshots[idx - 1]
    }

    /// Coloured stat showing disk-tier classification.
    @ViewBuilder
    private func tierStat(_ tier: String?, reason: String?) -> some View {
        let (color, label, helpKey): (Color, String, String) = {
            switch tier {
            case "enterprise": return (.purple, loc.t("tier.enterprise"), "tier.help.enterprise")
            case "consumer":   return (.blue, loc.t("tier.consumer"), "tier.help.consumer")
            default:           return (.secondary, loc.t("tier.unknown"), "tier.help.unknown")
            }
        }()
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(.title3, design: .rounded)).bold().foregroundStyle(color)
            Text(loc.t("tier.label")).font(.caption2).foregroundStyle(.secondary)
        }
        .help(loc.t(helpKey) + (reason.map { " · \($0)" } ?? ""))
    }

    /// Discard mechanism stat — adapts label to TRIM / Deallocate / UNMAP.
    @ViewBuilder
    private func discardStat(mechanism: String, supported: Bool?, level: String?, detail: String?) -> some View {
        let (color, value): (Color, String) = {
            switch supported {
            case .some(true): return (.green, loc.t("trim.yes"))
            case .some(false): return (.red, loc.t("trim.no"))
            case .none: return (.secondary, loc.t("trim.nodata"))
            }
        }()
        let levelText = level ?? ""
        let helpText: String = {
            var parts: [String] = [loc.t("discard.help")]
            if let level { parts.append(loc.t("trim.level.\(level)")) }
            if let detail { parts.append(detail) }
            return parts.joined(separator: " · ")
        }()
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(value).font(.system(.title3, design: .rounded)).bold().foregroundStyle(color)
                if !levelText.isEmpty {
                    Text(levelText)
                        .font(.caption2.bold())
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.18)))
                        .foregroundStyle(color)
                }
            }
            Text(mechanism).font(.caption2).foregroundStyle(.secondary)
        }
        .help(helpText)
    }

    /// Sanitize / secure-erase stat. Shows count of detected methods or "no data".
    @ViewBuilder
    private func sanitizeStat(methods: [String]) -> some View {
        let color: Color = methods.isEmpty ? .secondary : .orange
        let value: String = methods.isEmpty ? loc.t("sanitize.none") : String(methods.count)
        let helpText = methods.isEmpty ? loc.t("sanitize.help")
                                       : loc.t("sanitize.help") + "\n· " + methods.joined(separator: "\n· ")
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.title3, design: .rounded)).bold().foregroundStyle(color)
            Text(loc.t("sanitize.label")).font(.caption2).foregroundStyle(.secondary)
        }
        .help(helpText)
    }

    /// NAND-type stat (TLC/MLC/QLC/SLC).
    @ViewBuilder
    private func nandStat(_ nand: String?) -> some View {
        let value = nand ?? loc.t("nand.unknown")
        let upper = nand?.uppercased() ?? ""
        let color: Color = upper.contains("SLC") ? .green :
                            upper.contains("MLC") ? .green :
                            upper.contains("TLC") ? .blue :
                            upper.contains("QLC") ? .orange : .secondary
        let helpKey: String? = upper.contains("SLC") ? "nand.help.slc"
                             : upper.contains("MLC") ? "nand.help.mlc"
                             : upper.contains("TLC") ? "nand.help.tlc"
                             : upper.contains("QLC") ? "nand.help.qlc" : nil
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.title3, design: .rounded)).bold().foregroundStyle(color)
            Text(loc.t("nand.label")).font(.caption2).foregroundStyle(.secondary)
        }
        .help(helpKey.map(loc.t) ?? "")
    }

    /// PLP stat — three states.
    @ViewBuilder
    private func plpStat(_ supported: Bool?) -> some View {
        let (color, value): (Color, String) = {
            switch supported {
            case .some(true):  return (.green, loc.t("plp.yes"))
            case .some(false): return (.red, loc.t("plp.no"))
            case .none:        return (.secondary, loc.t("plp.unknown"))
            }
        }()
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.title3, design: .rounded)).bold().foregroundStyle(color)
            Text(loc.t("plp.label")).font(.caption2).foregroundStyle(.secondary)
        }
        .help(loc.t("plp.help"))
    }

    /// DRAM-cache stat — three states: yes / no / no data.
    @ViewBuilder
    private func dramStat(_ has: Bool?, reason: String?) -> some View {
        let (color, value): (Color, String) = {
            switch has {
            case .some(true):  return (.green, loc.t("cache.yes"))
            case .some(false): return (.red, loc.t("cache.no"))
            case .none:        return (.secondary, loc.t("cache.unknown"))
            }
        }()
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.title3, design: .rounded)).bold().foregroundStyle(color)
            Text(loc.t("cache.label")).font(.caption2).foregroundStyle(.secondary)
        }
        .help(loc.t("cache.help") + (reason.map { " · \($0)" } ?? ""))
    }

    private func snapStat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(.title3, design: .rounded)).bold()
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func statusColor(_ s: String) -> Color { s == "ok" ? .green : (s == "warn" ? .orange : .red) }

    private func kindLabel(_ k: String) -> String {
        switch k {
        case "wipe": return loc.t("history.kind.wipe")
        case "scan": return loc.t("history.kind.scan")
        default: return loc.t("history.kind.snapshot")
        }
    }
    private func kindColor(_ k: String) -> Color {
        switch k {
        case "wipe": return .red
        case "scan": return .purple
        default: return .blue
        }
    }
    private func kindIcon(_ k: String) -> String {
        switch k {
        case "wipe": return "eraser.fill"
        case "scan": return "waveform.path.ecg.rectangle"
        default: return "gauge.with.dots.needle.67percent"   // dashboard
        }
    }
}

// MARK: - Compare sheet

struct CompareSheet: View {
    @ObservedObject var hm: HistoryManager
    @EnvironmentObject var loc: Loc
    var done: () -> Void
    @State private var snapA: [String: Any]?
    @State private var snapB: [String: Any]?
    @State private var changedOnly = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(loc.t("compare.title")).font(.title3).bold()
                Spacer()
                Toggle(loc.t("compare.changedOnly"), isOn: $changedOnly)
                Button(loc.t("compare.close")) { done() }
            }
            if let a = snapA, let b = snapB { compareBody(a: a, b: b) }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 200) }
        }
        .padding(20).frame(width: 760, height: 580)
        .onAppear {
            guard hm.compareSelection.count == 2 else { return }
            // Order chronologically (earlier first).
            let paths = hm.compareSelection
            let ordered = paths.sorted { lhs, rhs in
                (hm.snapshots.first { $0.path == lhs }?.timestampEpoch ?? 0)
                < (hm.snapshots.first { $0.path == rhs }?.timestampEpoch ?? 0)
            }
            snapA = hm.loadSnapshotByPath(ordered[0])
            snapB = hm.loadSnapshotByPath(ordered[1])
        }
    }

    private func compareBody(a: [String: Any], b: [String: Any]) -> some View {
        let smartA = a["smart"] as? [String: Any] ?? [:]
        let smartB = b["smart"] as? [String: Any] ?? [:]
        let tsA = (a["timestamp"] as? String).map(prettyTS) ?? "—"
        let tsB = (b["timestamp"] as? String).map(prettyTS) ?? "—"
        let attrsA = (smartA["attributes"] as? [[String: Any]]) ?? []
        let attrsB = (smartB["attributes"] as? [[String: Any]]) ?? []
        let byIdA = Dictionary(uniqueKeysWithValues: attrsA.map { (($0["id"] as? Int ?? 0), $0) })
        let byIdB = Dictionary(uniqueKeysWithValues: attrsB.map { (($0["id"] as? Int ?? 0), $0) })
        let allIds = Array(Set(byIdA.keys).union(byIdB.keys)).sorted()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                stat("\(loc.t("compare.before"))  \(tsA)", smartA)
                Spacer()
                stat("\(loc.t("compare.after"))  \(tsB)", smartB)
            }
            HStack {
                Text(loc.t("compare.attribute")).frame(width: 240, alignment: .leading).font(.caption).foregroundStyle(.secondary)
                Text(loc.t("compare.before")).frame(width: 140, alignment: .trailing).font(.caption).foregroundStyle(.secondary)
                Text(loc.t("compare.after")).frame(width: 140, alignment: .trailing).font(.caption).foregroundStyle(.secondary)
                Text(loc.t("compare.delta")).frame(maxWidth: .infinity, alignment: .trailing).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(allIds, id: \.self) { id in
                        let aA = byIdA[id]; let aB = byIdB[id]
                        let rawA = aA?["raw"] as? Int ?? 0
                        let rawB = aB?["raw"] as? Int ?? 0
                        let delta = rawB - rawA
                        if changedOnly && delta == 0 && rawA == 0 && rawB == 0 { EmptyView() } else
                        if changedOnly && delta == 0 { EmptyView() } else {
                            HStack {
                                Text("#\(id)  \(aB?["name"] as? String ?? aA?["name"] as? String ?? "")")
                                    .frame(width: 240, alignment: .leading).lineLimit(1)
                                Text("\(aA?["rawString"] as? String ?? "—")").frame(width: 140, alignment: .trailing)
                                Text("\(aB?["rawString"] as? String ?? "—")").frame(width: 140, alignment: .trailing)
                                Text(deltaText(delta))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .foregroundStyle(deltaColor(id: id, delta: delta))
                                    .bold()
                            }
                            .font(.system(.caption, design: .monospaced))
                            .padding(.vertical, 2)
                            .background(delta != 0 ? Color.yellow.opacity(0.05) : Color.clear)
                        }
                    }
                }
            }
        }
    }

    private func stat(_ title: String, _ smart: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                value("\(smart["powerOnHours"] as? Int ?? 0) \(loc.t("unit.h"))")
                value((smart["lifeLeftPercent"] as? Int).map { "\($0)%" } ?? "—")
                value("\(smart["temperatureC"] as? Int ?? 0)°")
            }
        }
    }
    private func value(_ s: String) -> some View {
        Text(s).font(.system(.title3, design: .rounded).bold())
    }
    private func deltaText(_ d: Int) -> String { d == 0 ? "0" : (d > 0 ? "+\(d)" : "\(d)") }
    private func deltaColor(id: Int, delta: Int) -> Color {
        if delta == 0 { return .secondary }
        let badIDs = [5, 187, 197, 198, 199, 188]
        if badIDs.contains(id) && delta > 0 { return .red }
        if id == 194 { return delta > 0 ? .orange : .secondary }
        return .primary
    }
    private func prettyTS(_ s: String) -> String {
        guard s.count >= 19 else { return s }
        var chars = Array(s); chars[10] = " "; chars[13] = ":"; chars[16] = ":"
        return String(chars)
    }
}
