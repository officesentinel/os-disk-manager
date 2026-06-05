import SwiftUI
import Charts

struct DashboardView: View {
    @StateObject private var health = DiskHealth()
    @EnvironmentObject var loc: Loc

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                diskSelector
                if let msg = health.exportMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let r = health.report {
                    identityCard(r)
                    gaugeRow(r)
                    statRow(r)
                    enduranceCard(r)
                    if !health.partitions.isEmpty { partitionCard }
                    smartCard(r)
                } else if health.loading {
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text(loc.t("dash.reading"))
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 380, alignment: .center)
                } else {
                    ContentUnavailableView {
                        Label(loc.t("dash.nodata"), systemImage: "internaldrive")
                    } description: {
                        Text(health.lastError ?? loc.t("dash.selectDisk"))
                    } actions: {
                        if health.lastError != nil {
                            Button(loc.t("dash.openFDA")) {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                            }
                            Button(loc.t("common.retry")) { health.load() }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 380)
                }
            }
            .padding(18)
        }
        .onAppear { health.refreshDisks(); health.startPolling() }
        .onDisappear { health.stopPolling() }
    }

    private var diskSelector: some View {
        HStack {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.title2).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Picker("", selection: $health.selected) {
                ForEach(health.disks) { d in Text(d.label).tag(Optional(d)) }
            }.labelsHidden()
                .accessibilityLabel(loc.t("dash.selectDisk"))
            if health.loading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(loc.t("status.loading"))
            }
            Spacer()
            if health.exporting {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(loc.t("status.exporting"))
            }
            Button { health.exportReport() } label: { Label(loc.t("dash.save"), systemImage: "square.and.arrow.down") }
                .disabled(health.report == nil || health.exporting)
                .accessibilityHint(loc.t("dash.save.hint"))
            Button { health.refreshDisks() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(loc.t("common.refresh"))
            .accessibilityHint(loc.t("dash.refresh.hint"))
        }
    }

    private func identityCard(_ r: SmartReport) -> some View {
        Card {
            HStack(spacing: 16) {
                Image(systemName: r.isSSD ? "memorychip" : "internaldrive")
                    .font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(r.model).font(.title3).bold()
                        if let family = r.family, !family.isEmpty {
                            Text("· \(family)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        sourceBadge(r.dataSource)
                    }
                    Text("\(loc.t("id.sn")) \(r.serial.isEmpty ? "—" : r.serial)  ·  \(loc.t("id.fw")) \(r.firmware)  ·  \(r.proto)")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(String(format: "%.1f GB  ·  %@", Double(r.sizeBytes)/1e9, r.isSSD ? "SSD" : "HDD"))
                            .font(.caption).foregroundStyle(.secondary)
                        tierChip(r.tier, reason: r.tierReason)
                        dramChip(r.dramCache, reason: r.dramCacheReason)
                        nandChip(r.nandType)
                        plpChip(r.plp)
                        discardChip(mechanism: r.discardMechanism ?? "TRIM",
                                     supported: r.trimSupported,
                                     level: r.trimLevel,
                                     detail: r.trimDetail)
                        sanitizeChip(methods: r.sanitizeMethods)
                    }
                }
                Spacer()
                healthBadge(r.healthPassed)
            }
        }
    }

    /// Three-state disk-tier chip: 🏢 enterprise / 🖥 consumer / ❓ unknown.
    /// Tooltip explains the signal that triggered the classification.
    @ViewBuilder
    private func tierChip(_ tier: String?, reason: String?) -> some View {
        let (icon, color, label, helpKey): (String, Color, String, String) = {
            switch tier {
            case "enterprise": return ("building.2.fill", .purple, loc.t("tier.enterprise"), "tier.help.enterprise")
            case "consumer":   return ("desktopcomputer", .blue, loc.t("tier.consumer"), "tier.help.consumer")
            default:           return ("questionmark.circle", .secondary, loc.t("tier.unknown"), "tier.help.unknown")
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundStyle(color)
            Text(label).font(.caption2.bold()).foregroundStyle(color)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
        .help(loc.t(helpKey) + (reason.map { " · \($0)" } ?? ""))
    }

    /// Tiny badge showing where the static metadata came from.
    @ViewBuilder
    private func sourceBadge(_ source: String?) -> some View {
        let (icon, color, label, helpKey): (String, Color, String, String) = {
            switch source {
            case "OurDB":    return ("checkmark.seal.fill", .green, "DB", "source.OurDB")
            case "smartctl": return ("info.circle", .blue, "smartctl", "source.smartctl")
            default:         return ("questionmark.circle", .secondary, "—", "source.none")
            }
        }()
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(color)
            Text(label).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(color)
        }
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.12)))
        .help(loc.t(helpKey))
    }

    /// NAND-type chip with colour by tier: SLC>MLC>TLC>QLC.
    @ViewBuilder
    private func nandChip(_ nand: String?) -> some View {
        let value = nand ?? loc.t("nand.unknown")
        let upper = nand?.uppercased() ?? ""
        let color: Color = upper.contains("SLC") ? .green :
                            (upper.contains("MLC") ? .green :
                             (upper.contains("TLC") ? .blue :
                              (upper.contains("QLC") ? .orange : .secondary)))
        let helpKey: String? = upper.contains("SLC") ? "nand.help.slc"
                             : upper.contains("MLC") ? "nand.help.mlc"
                             : upper.contains("TLC") ? "nand.help.tlc"
                             : upper.contains("QLC") ? "nand.help.qlc" : nil
        HStack(spacing: 4) {
            Image(systemName: "rectangle.grid.2x2.fill").font(.caption2).foregroundStyle(color)
            Text("\(loc.t("nand.label")): \(value)").font(.caption2.bold()).foregroundStyle(color)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
        .help(helpKey.map(loc.t) ?? "")
    }

    /// PLP (power-loss protection) chip — three states.
    @ViewBuilder
    private func plpChip(_ supported: Bool?) -> some View {
        let (icon, color, label): (String, Color, String) = {
            switch supported {
            case .some(true):  return ("bolt.shield.fill", .green, loc.t("plp.yes"))
            case .some(false): return ("bolt.slash", .red, loc.t("plp.no"))
            case .none:        return ("questionmark.circle", .secondary, loc.t("plp.unknown"))
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundStyle(color)
            Text("\(loc.t("plp.label")): \(label)").font(.caption2.bold()).foregroundStyle(color)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
        .help(loc.t("plp.help"))
    }

    /// DRAM-cache chip — three states. Reason text appears on hover.
    @ViewBuilder
    private func dramChip(_ has: Bool?, reason: String?) -> some View {
        let (icon, color, label): (String, Color, String) = {
            switch has {
            case .some(true):  return ("memorychip.fill", .green, loc.t("cache.yes"))
            case .some(false): return ("memorychip", .red, loc.t("cache.no"))
            case .none:        return ("questionmark.circle", .secondary, loc.t("cache.unknown"))
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundStyle(color)
            Text("\(loc.t("cache.label")): \(label)").font(.caption2.bold()).foregroundStyle(color)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
        .help(loc.t("cache.help") + (reason.map { " · \($0)" } ?? ""))
    }

    /// Discard chip — protocol-aware name (TRIM/Deallocate/UNMAP) + TRIM-level variant
    /// for SATA. 🟢 yes / 🔴 no / ⚪ no data. Hover shows the full explanation.
    @ViewBuilder
    private func discardChip(mechanism: String, supported: Bool?, level: String?, detail: String?) -> some View {
        let (color, label): (Color, String) = {
            switch supported {
            case .some(true): return (.green, loc.t("trim.yes"))
            case .some(false): return (.red, loc.t("trim.no"))
            case .none: return (.secondary, loc.t("trim.nodata"))
            }
        }()
        let suffix = level.map { " (\($0))" } ?? ""
        let helpText: String = {
            var parts: [String] = [loc.t("discard.help")]
            if let level { parts.append(loc.t("trim.level.\(level)")) }
            if let detail { parts.append(detail) }
            return parts.joined(separator: " · ")
        }()
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(mechanism): \(label)\(suffix)").font(.caption2.bold()).foregroundStyle(color)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
        .help(helpText)
    }

    /// Sanitize / secure-erase chip — shows which secure-erase mechanisms smartctl detected.
    @ViewBuilder
    private func sanitizeChip(methods: [String]) -> some View {
        if methods.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "lock.open").font(.caption2).foregroundStyle(.secondary)
                Text("\(loc.t("sanitize.label")): \(loc.t("sanitize.none"))")
                    .font(.caption2.bold()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
            .help(loc.t("sanitize.help"))
        } else {
            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill").font(.caption2).foregroundStyle(.orange)
                Text("\(loc.t("sanitize.label")): \(methods.count)")
                    .font(.caption2.bold()).foregroundStyle(.orange)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.15)))
            .help(loc.t("sanitize.help") + "\n· " + methods.joined(separator: "\n· "))
        }
    }

    /// Three-state TRIM chip: 🟢 yes / 🔴 no / ⚪ no data. Includes the variant
    /// (DZAT / DRAT / basic) when supported. Hover shows the full explanation.
    @ViewBuilder
    private func trimChip(_ supported: Bool?, level: String?, detail: String?) -> some View {
        let (color, label): (Color, String) = {
            switch supported {
            case .some(true): return (.green, loc.t("trim.yes"))
            case .some(false): return (.red, loc.t("trim.no"))
            case .none: return (.secondary, loc.t("trim.nodata"))
            }
        }()
        let suffix = level.map { " (\($0))" } ?? ""
        let helpText: String = {
            if let level { return loc.t("trim.level.\(level)") }
            return detail ?? ""
        }()
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(loc.t("trim.label")): \(label)\(suffix)")
                .font(.caption2.bold())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
        .help(helpText)
    }

    private func healthBadge(_ passed: Bool?) -> some View {
        let ok = passed == true
        return VStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.seal.fill" : (passed == nil ? "questionmark.circle" : "xmark.seal.fill"))
                .font(.system(size: 30)).foregroundStyle(ok ? .green : (passed == nil ? .gray : .red))
            Text(ok ? loc.t("health.passed") : (passed == nil ? "—" : loc.t("health.failed"))).font(.caption).bold()
        }
    }

    private func gaugeRow(_ r: SmartReport) -> some View {
        HStack(spacing: 14) {
            RingGauge(fraction: r.lifeLeftPercent.map { Double($0)/100 } ?? 1,
                      color: lifeColor(r.lifeLeftPercent),
                      big: "\(r.lifeLeftPercent ?? 100)%", title: loc.t("gauge.life"), sub: loc.t("gauge.life.sub"))
            RingGauge(fraction: min(1, Double(r.temperatureC)/70),
                      color: tempColor(r.temperatureC),
                      big: "\(r.temperatureC)°", title: loc.t("gauge.temp"),
                      sub: r.temperatureMaxC.map { loc.t("gauge.temp.max", $0) } ?? loc.t("gauge.temp.now"))
            RingGauge(fraction: min(1, Double(r.powerOnHours)/87600),
                      color: .blue,
                      big: hoursShort(r.powerOnHours), title: loc.t("gauge.poweron"), sub: loc.t("gauge.poweron.sub"))
            capacityDonut
        }
    }

    private var capacityDonut: some View {
        Card {
            VStack(spacing: 6) {
                if health.partitions.isEmpty {
                    RingShape(fraction: 0, color: .gray).frame(width: 84, height: 84)
                        .overlay(Text(loc.t("common.empty")).font(.caption2).foregroundStyle(.secondary))
                } else {
                    Chart(donutData) { seg in
                        SectorMark(angle: .value("size", seg.bytes),
                                   innerRadius: .ratio(0.62), angularInset: 1.5)
                            .cornerRadius(3)
                            .foregroundStyle(seg.color)
                    }
                    .frame(width: 84, height: 84)
                }
                Text(loc.t("card.partitions")).font(.caption).bold()
                Text(loc.t("card.partitions.count", health.partitions.count)).font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
        }
    }

    private struct DonutSeg: Identifiable { let id = UUID(); let name: String; let bytes: Double; let color: Color }
    private var donutData: [DonutSeg] {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]
        var segs = health.partitions.enumerated().map { i, p in
            DonutSeg(name: p.name.isEmpty ? p.id : p.name, bytes: Double(p.sizeBytes), color: palette[i % palette.count])
        }
        let used = health.partitions.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let free = Double(max(0, health.totalBytes - used))
        if free > Double(health.totalBytes) * 0.01 { segs.append(DonutSeg(name: loc.t("common.free"), bytes: free, color: .gray.opacity(0.3))) }
        return segs
    }

    private func statRow(_ r: SmartReport) -> some View {
        HStack(spacing: 12) {
            StatCard(icon: "bolt.fill", title: loc.t("stat.cycles"), value: "\(r.powerCycles)", tint: .yellow)
            StatCard(icon: "clock.fill", title: loc.t("stat.poweron"), value: "\(r.powerOnHours) \(loc.t("unit.h"))", tint: .blue)
            StatCard(icon: "wrench.and.screwdriver.fill", title: loc.t("stat.wear"),
                     value: r.wearPercentUsed.map { "\($0)%" } ?? "—", tint: .orange)
            StatCard(icon: "exclamationmark.triangle.fill", title: loc.t("stat.defects"),
                     value: "\(defectCount(r))", tint: defectCount(r) == 0 ? .green : .red)
        }
    }

    private func defectCount(_ r: SmartReport) -> Int {
        r.attributes.filter { [5,197,198,187].contains($0.id) }.reduce(0) { $0 + $1.raw }
    }

    /// Endurance card — visualises rated TBW × disk size and how much is used.
    @ViewBuilder
    private func enduranceCard(_ r: SmartReport) -> some View {
        // Compute totals if data is available.
        let sizeTB = Double(r.sizeBytes) / 1_000_000_000_000.0
        let totalTBW: Double? = r.tbwPerTb.map { Double($0) * sizeTB }
        let usedPct: Double? = r.wearPercentUsed.map { Double($0) }
        // Used TB only when both wear% and rated TBW are known.
        let usedTB: Double? = (totalTBW != nil && usedPct != nil) ? totalTBW! * usedPct! / 100.0 : nil
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "speedometer").foregroundStyle(.tint)
                    Text(loc.t("tbw.title")).font(.headline)
                    Spacer()
                    if let total = totalTBW {
                        Text(String(format: "%.0f %@", total, loc.t("tbw.rated")))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let total = totalTBW, let used = usedTB, let pct = usedPct {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(format: "%.1f TB", used))
                            .font(.system(.title2, design: .rounded)).bold()
                            .foregroundStyle(pct > 80 ? .red : (pct > 50 ? .orange : .green))
                        Text("\(loc.t("tbw.of"))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.0f TBW", total))
                            .font(.system(.title3, design: .rounded)).bold().foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f%% %@", pct, loc.t("tbw.used")))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15))
                            RoundedRectangle(cornerRadius: 5)
                                .fill(LinearGradient(colors: [
                                    .green, .green, .yellow, .orange, .red
                                ], startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * CGFloat(min(100, max(0, pct))) / 100)
                        }
                    }.frame(height: 12)
                } else if let pct = usedPct {
                    // Wear% but no rated TBW — show just the wear bar.
                    HStack {
                        Text(String(format: "%.0f%% %@", pct, loc.t("tbw.used"))).bold()
                            .foregroundStyle(pct > 80 ? .red : (pct > 50 ? .orange : .green))
                        Spacer()
                        Text(loc.t("tbw.unknown")).font(.caption).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15))
                            RoundedRectangle(cornerRadius: 5).fill(Color.orange)
                                .frame(width: geo.size.width * CGFloat(min(100, max(0, pct))) / 100)
                        }
                    }.frame(height: 12)
                } else {
                    Text(loc.t("tbw.unknown"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .help(loc.t("tbw.help"))
    }

    private var partitionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(loc.t("dash.partmap"))  ·  \(health.scheme)").font(.headline)
                PartitionBar(parts: health.partitions, total: health.totalBytes)
                ForEach(Array(health.partitions.enumerated()), id: \.element.id) { i, p in
                    HStack(spacing: 8) {
                        Circle().fill(barColor(i)).frame(width: 9, height: 9)
                        Text(p.name.isEmpty ? p.id : p.name).bold()
                        Text("· \(p.fs)").foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f GB", p.sizeGB)).font(.system(.caption, design: .monospaced))
                    }.font(.caption)
                }
            }
        }
    }
    private func barColor(_ i: Int) -> Color { [.blue, .green, .orange, .purple, .pink, .teal, .indigo][i % 7] }

    private func smartCard(_ r: SmartReport) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(loc.t("dash.smart")).font(.headline)
                    Spacer()
                    Text("\(r.attributes.count)").foregroundStyle(.secondary)
                }
                HStack {
                    Text("№").frame(width: 30, alignment: .leading)
                    Text(loc.t("smart.col.attr")).frame(width: 180, alignment: .leading)
                    Text(loc.t("smart.col.value")).frame(width: 72, alignment: .trailing)
                    Text(loc.t("smart.col.worst")).frame(width: 64, alignment: .trailing)
                    Text(loc.t("smart.col.thresh")).frame(width: 60, alignment: .trailing)
                    Text(loc.t("smart.col.raw")).frame(maxWidth: .infinity, alignment: .trailing)
                }.font(.caption2).foregroundStyle(.secondary)
                Divider()
                ForEach(r.attributes) { a in
                    HStack {
                        Circle().fill(statusColor(a.status)).frame(width: 7, height: 7)
                        Text("\(a.id)").frame(width: 23, alignment: .leading)
                        Text(a.name).frame(width: 180, alignment: .leading).lineLimit(1)
                        Text("\(a.value)").frame(width: 72, alignment: .trailing)
                        Text("\(a.worst)").frame(width: 64, alignment: .trailing).foregroundStyle(.secondary)
                        Text("\(a.thresh)").frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
                        Text(a.rawString).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func lifeColor(_ p: Int?) -> Color {
        guard let p else { return .green }
        return p > 50 ? .green : (p > 20 ? .yellow : .red)
    }
    private func tempColor(_ t: Int) -> Color { t < 45 ? .green : (t < 60 ? .orange : .red) }
    private func statusColor(_ s: String) -> Color { s == "ok" ? .green : (s == "warn" ? .orange : .red) }
    private func hoursShort(_ h: Int) -> String { h >= 1000 ? String(format: "%.1fk", Double(h)/1000) : "\(h)" }
}

// MARK: - Reusable components

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12)))
    }
}

struct RingShape: View {
    var fraction: Double
    var color: Color
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: 9)
            Circle().trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct RingGauge: View {
    var fraction: Double
    var color: Color
    var big: String
    var title: String
    var sub: String
    var body: some View {
        Card {
            VStack(spacing: 6) {
                ZStack {
                    RingShape(fraction: fraction, color: color)
                    Text(big).font(.system(.title3, design: .rounded)).bold()
                }.frame(width: 84, height: 84)
                Text(title).font(.caption).bold()
                Text(sub).font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
        }
    }
}

struct StatCard: View {
    var icon: String; var title: String; var value: String; var tint: Color
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(value).font(.system(.title3, design: .rounded)).bold()
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PartitionBar: View {
    var parts: [PartItem]
    var total: Int64
    private let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.element.id) { i, p in
                    let w = total > 0 ? geo.size.width * CGFloat(p.sizeBytes) / CGFloat(total) : 0
                    Rectangle().fill(palette[i % palette.count])
                        .frame(width: max(2, w))
                        .overlay(alignment: .leading) {
                            if w > 50 {
                                Text(p.name.isEmpty ? p.fs : p.name)
                                    .font(.caption2).foregroundStyle(.white).padding(.leading, 4).lineLimit(1)
                            }
                        }
                }
                let used = parts.reduce(Int64(0)) { $0 + $1.sizeBytes }
                if total > used {
                    Rectangle().fill(Color.gray.opacity(0.25))
                        .frame(width: geo.size.width * CGFloat(total - used) / CGFloat(max(1,total)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(height: 30)
    }
}
