import SwiftUI

struct PartitionView: View {
    @StateObject private var pm = PartitionManager()
    @EnvironmentObject var loc: Loc
    @State private var sheet: PartSheet?
    @State private var confirmDelete = false

    enum PartSheet: Identifiable {
        case repartition, format, resize, add
        var id: Int { hashValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(loc.t("part.title")).font(.title3).bold()
                Spacer()
                Button { pm.refreshDisks() } label: { Image(systemName: "arrow.clockwise") }
            }
            HStack {
                Text(loc.t("common.disk")).frame(width: 50, alignment: .leading)
                Picker("", selection: $pm.selectedDisk) {
                    ForEach(pm.disks) { d in Text(d.label).tag(Optional(d)) }
                }.labelsHidden()
                // `selectedDisk.didSet` already triggers layout reload + state reset; no .onChange needed.
            }
            Text("\(loc.t("common.scheme")): \(pm.scheme)").font(.caption).foregroundStyle(.secondary)

            partTable
            actionBar
            if !pm.lastResult.isEmpty { resultBanner }
            Spacer()
        }
        .padding(18)
        .onAppear { pm.refreshDisks(); pm.startPolling() }
        .onDisappear { if !pm.busy { pm.stopPolling() } }
        .sheet(item: $sheet) { which in
            Group {
                switch which {
                case .repartition: RepartitionSheet(pm: pm) { sheet = nil }
                case .format: FormatSheet(pm: pm, volume: pm.selectedPart) { sheet = nil }
                case .resize: ResizeSheet(pm: pm, volume: pm.selectedPart) { sheet = nil }
                case .add: AddSheet(pm: pm, volume: pm.selectedPart) { sheet = nil }
                }
            }.environmentObject(loc)
        }
        .confirmationDialog(loc.t("part.deleteConfirm", pm.selectedPart?.id ?? ""),
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(loc.t("part.delete"), role: .destructive) {
                if let v = pm.selectedPart?.id { pm.delete(volume: v) }
            }
            Button(loc.t("common.cancel"), role: .cancel) {}
        }
    }

    private var partTable: some View {
        VStack(spacing: 0) {
            List(pm.partitions, selection: Binding(
                get: { pm.selectedPart?.id },
                set: { id in pm.selectedPart = pm.partitions.first { $0.id == id } }
            )) { p in
                HStack {
                    Image(systemName: p.apfsVolume ? "square.stack.3d.up" : "rectangle.split.3x1")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name.isEmpty ? loc.t("common.noname") : p.name).bold()
                        Text("\(p.id) · \(p.fs)\(p.mount.isEmpty ? "" : " · \(p.mount)")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.1f GB", p.sizeGB)).font(.system(.caption, design: .monospaced))
                }.tag(p.id)
            }
            .frame(height: 200)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }

    private var actionBar: some View {
        let p = pm.selectedPart
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { sheet = .repartition } label: {
                    Label(loc.t("part.repartition"), systemImage: "square.grid.3x1.below.line.grid.1x2")
                }
                Divider().frame(height: 18)
                Button { sheet = .format } label: { Label(loc.t("part.format"), systemImage: "eraser") }
                    .disabled(p == nil || !(p?.caps.canFormat ?? false))
                    .help(reasonOrEmpty(p?.caps.formatReason))
                Button { sheet = .resize } label: { Label(loc.t("part.resize"), systemImage: "arrow.left.and.right") }
                    .disabled(p == nil || !(p?.caps.canResize ?? false))
                    .help(reasonOrEmpty(p?.caps.resizeReason))
                Button { sheet = .add } label: { Label(loc.t("part.add"), systemImage: "plus.rectangle") }
                    .disabled(p == nil || !(p?.caps.canAddNext ?? false))
                    .help(reasonOrEmpty(p?.caps.addReason))
                Button(role: .destructive) { confirmDelete = true } label: { Label(loc.t("part.delete"), systemImage: "trash") }
                    .disabled(p == nil || !(p?.caps.canDelete ?? false))
                    .help(reasonOrEmpty(p?.caps.deleteReason))
                if pm.busy { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.bordered)
            // Inline status of why disabled (for the most important blocked action).
            if let p, let msg = primaryReason(for: p) {
                Label(msg, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if p != nil {
                Text(loc.t("cap.statusHint")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// Resolves a reason key → localized message, or "" if no reason.
    private func reasonOrEmpty(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return "" }
        return loc.t(key)
    }
    /// Pick the most informative reason to show in the inline status line.
    private func primaryReason(for p: PartItem) -> String? {
        if !p.caps.canResize, let k = p.caps.resizeReason { return loc.t(k) }
        if !p.caps.canFormat, let k = p.caps.formatReason { return loc.t(k) }
        if !p.caps.canDelete, let k = p.caps.deleteReason { return loc.t(k) }
        return nil
    }

    private var resultBanner: some View {
        Text(pm.lastResult)
            .font(.system(.caption, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill((pm.lastOK ? Color.green : Color.red).opacity(0.12)))
    }
}

// MARK: - Sheets

private struct PartRow: Identifiable { let id = UUID(); var fs = "APFS"; var name = "Untitled"; var size = "" }

struct RepartitionSheet: View {
    @ObservedObject var pm: PartitionManager
    @EnvironmentObject var loc: Loc
    var done: () -> Void
    @State private var scheme = "GPT"
    @State private var rows: [PartRow] = [PartRow()]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.t("part.repartTitle")).font(.headline)
            Label(loc.t("part.repartWarn"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            Picker(loc.t("common.scheme"), selection: $scheme) {
                ForEach(PartitionManager.schemes, id: \.self) { Text($0) }
            }.pickerStyle(.segmented)
            ForEach($rows) { $r in
                HStack {
                    Picker("", selection: $r.fs) { ForEach(PartitionManager.filesystems, id: \.self) { Text($0) } }
                        .labelsHidden().frame(width: 100)
                    TextField(loc.t("part.name"), text: $r.name).frame(width: 120)
                    TextField(loc.t("part.size"), text: $r.size)
                    if rows.count > 1 { Button { rows.removeAll { $0.id == r.id } } label: { Image(systemName: "minus.circle") } }
                }
            }
            Button { rows.append(PartRow(size: "")) } label: { Label(loc.t("part.addPartition"), systemImage: "plus") }
            HStack {
                Spacer()
                Button(loc.t("common.cancel")) { done() }
                Button(loc.t("part.repartition"), role: .destructive) {
                    let specs = rows.map { "\($0.fs):\($0.name):\($0.size)" }
                    pm.repartition(scheme: scheme, specs: specs); done()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 480)
    }
}

struct FormatSheet: View {
    @ObservedObject var pm: PartitionManager
    @EnvironmentObject var loc: Loc
    let volume: PartItem?
    var done: () -> Void
    @State private var fs = "APFS"
    @State private var name = "Untitled"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.t("part.formatTitle", volume?.id ?? "")).font(.headline)
            if let v = volume { Text(loc.t("part.current", "\(v.fs), \(String(format: "%.1f GB", v.sizeGB))")).font(.caption).foregroundStyle(.secondary) }
            Label(loc.t("part.eraseWarn"), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            Picker(loc.t("part.fs"), selection: $fs) { ForEach(PartitionManager.filesystems, id: \.self) { Text($0) } }
            TextField(loc.t("part.volName"), text: $name)
            HStack { Spacer()
                Button(loc.t("common.cancel")) { done() }
                Button(loc.t("part.format"), role: .destructive) {
                    if let v = volume?.id { pm.format(volume: v, fs: fs, name: name) }; done()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 420)
    }
}

struct ResizeSheet: View {
    @ObservedObject var pm: PartitionManager
    @EnvironmentObject var loc: Loc
    let volume: PartItem?
    var done: () -> Void
    @State private var size = ""
    @State private var addNew = false
    @State private var fs = "ExFAT"
    @State private var name = "New"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.t("part.resizeTitle", volume?.id ?? "")).font(.headline)
            if let v = volume { Text(loc.t("part.now", String(format: "%.1f GB", v.sizeGB))).font(.caption).foregroundStyle(.secondary) }
            TextField(loc.t("part.newSize"), text: $size)
            Toggle(loc.t("part.makeNew"), isOn: $addNew)
            if addNew {
                HStack {
                    Picker("", selection: $fs) { ForEach(PartitionManager.filesystems, id: \.self) { Text($0) } }.labelsHidden()
                    TextField(loc.t("part.name"), text: $name)
                }
            }
            Text(loc.t("part.resizeNote")).font(.caption2).foregroundStyle(.secondary)
            HStack { Spacer()
                Button(loc.t("common.cancel")) { done() }
                Button(loc.t("part.apply")) {
                    if let v = volume?.id {
                        pm.resize(volume: v, size: size,
                                  add: addNew ? ["\(fs):\(name):0b"] : [])
                    }; done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(size.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(18).frame(width: 460)
    }
}

struct AddSheet: View {
    @ObservedObject var pm: PartitionManager
    @EnvironmentObject var loc: Loc
    let volume: PartItem?
    var done: () -> Void
    @State private var shrinkTo = ""
    @State private var fs = "ExFAT"
    @State private var name = "New"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.t("part.addTitle", volume?.id ?? "")).font(.headline)
            if let v = volume { Text(loc.t("part.shrinkNote", String(format: "%.1f GB", v.sizeGB))).font(.caption).foregroundStyle(.secondary) }
            TextField(loc.t("part.shrinkTo"), text: $shrinkTo)
            HStack {
                Picker(loc.t("part.newFs"), selection: $fs) { ForEach(PartitionManager.filesystems, id: \.self) { Text($0) } }
                TextField(loc.t("part.name"), text: $name)
            }
            HStack { Spacer()
                Button(loc.t("common.cancel")) { done() }
                Button(loc.t("part.add")) {
                    if let v = volume?.id, !shrinkTo.isEmpty {
                        pm.addVolume(volume: v, shrinkTo: shrinkTo, fs: fs, name: name)
                    }; done()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 460)
    }
}
