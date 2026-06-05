import SwiftUI
import AppKit

@main
struct DiskWipeApp: App {
    @StateObject private var loc = Loc()
    init() {
        // OS compatibility check — show a localised modal and quit on macOS < 14.
        // `LSMinimumSystemVersion` in Info.plist already blocks lower versions at
        // launch time, but if for any reason we still get here, fail visibly with
        // a clear message rather than crashing later when 14+ APIs are touched.
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion < 14 {
            let current = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            let l = Loc.shared
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = l.t("os.unsupported.title")
                alert.informativeText = String(format: l.t("os.unsupported.body"), current)
                alert.addButton(withTitle: l.t("os.unsupported.button"))
                alert.alertStyle = .critical
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
        // Refresh the model database in the background if it's stale (>7 days).
        DatabaseUpdater.shared.fetch { _ in }
    }
    var body: some Scene {
        WindowGroup(Brand.long) {
            RootView()
                .environmentObject(loc)
        }
        .windowResizability(.contentSize)
    }
}

struct RootView: View {
    @EnvironmentObject var loc: Loc
    @Environment(\.scenePhase) private var scenePhase
    @State private var activityToken: NSObjectProtocol?

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label(loc.t("tab.overview"), systemImage: "gauge.with.dots.needle.67percent") }
            ContentView()
                .tabItem { Label(loc.t("tab.wipe"), systemImage: "eraser") }
            ScanView()
                .tabItem { Label(loc.t("tab.scan"), systemImage: "waveform.path.ecg.rectangle") }
            PartitionView()
                .tabItem { Label(loc.t("tab.partitions"), systemImage: "rectangle.split.3x1") }
            HistoryView()
                .tabItem { Label(loc.t("tab.history"), systemImage: "clock.arrow.circlepath") }
        }
        .frame(minWidth: 720, minHeight: 760)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    let dir = AppLog.shared.logsDir
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
                } label: {
                    Label(loc.t("common.openLogs"), systemImage: "doc.text.magnifyingglass")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    DatabaseUpdater.shared.fetch(force: true) { _ in }
                } label: {
                    Label(loc.t("db.refresh"), systemImage: "arrow.triangle.2.circlepath")
                }
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker(loc.t("lang.menu"), selection: $loc.lang) {
                        ForEach(Lang.allCases) { l in
                            Text("\(l.flag)  \(l.display)").tag(l)
                        }
                    }
                } label: {
                    Label("\(loc.lang.flag) \(loc.t("lang.menu"))", systemImage: "globe")
                }
            }
        }
        .onChange(of: scenePhase) { _, new in
            switch new {
            case .active:
                if activityToken == nil {
                    activityToken = ProcessInfo.processInfo.beginActivity(
                        options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .userInitiated],
                        reason: "OS Disk Manager window active")
                    AppLog.shared.info("sleep", "began activity assertion (window active)")
                }
            case .background, .inactive:
                if let t = activityToken {
                    ProcessInfo.processInfo.endActivity(t)
                    activityToken = nil
                    AppLog.shared.info("sleep", "ended activity assertion (window inactive)")
                }
            @unknown default: break
            }
        }
    }
}
