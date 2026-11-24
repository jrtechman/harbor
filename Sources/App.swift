import AppKit
import ServiceManagement
import SwiftUI

@main
struct HarborApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = ProfileStore.shared
    @ObservedObject private var usage = UsageStore.shared
    @AppStorage(Prefs.showMenuBarKey) private var showMenuBar = true
    @AppStorage(Prefs.showUsageKey) private var showUsage = true

    var body: some Scene {
        Window("Harbor", id: "main") {
            MainView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1100, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Profile…") { NotificationCenter.default.post(name: .newProfile, object: nil) }
                    .keyboardShortcut("n")
            }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent().environmentObject(store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2.circle")
                if Prefs.usageEnabled, showUsage, let title = usage.menuBarTitle(for: store.lastActiveProfile) {
                    Text(title)
                }
            }
        }

        Settings {
            AdvancedSettings().environmentObject(store)
        }
    }
}

struct AdvancedSettings: View {
    @EnvironmentObject var store: ProfileStore
    @Environment(\.openWindow) private var openWindow
    @Local private var working = false
    @Local private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Local private var autoUpdate = Prefs.autoUpdateCopies
    @AppStorage(Prefs.harborAutoUpdateKey) private var autoUpdateHarbor = false
    @AppStorage(Prefs.showMenuBarKey) private var showMenuBar = true
    @AppStorage(Prefs.hideDockKey) private var hideDock = false
    @AppStorage(Prefs.showUsageKey) private var showUsage = true
    @AppStorage(Prefs.sessionLimitKey) private var sessionLimit = 0
    @AppStorage(Prefs.weekLimitKey) private var weekLimit = 0
    @Local private var sessionPct = ""
    @Local private var weekPct = ""
    @Local private var calibrateNote: String?
    @AppStorage(Prefs.appearanceKey) private var appearance = 0

    /// Sets the limits so Harbor's percentages match what Claude's own usage page shows right now.
    private func calibrate() {
        calibrateNote = UsageStore.shared.calibrate(sessionPct: sessionPct, weekPct: weekPct)
    }

    /// Brings the main window forward and shows the get-started guide in it.
    private func showGuide() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(name: .showGuide, object: nil)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            store.lastError = "Couldn't change launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var body: some View {
        TabView {
            Form {
                Section("Help") {
                    LabeledContent("Get started guide") {
                        Button("View help") { showGuide() }
                    }
                    Text("A quick walkthrough: adding profiles, opening them, giving one its own Dock icon, and backups.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("General") {
                    Toggle("Launch at login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLogin($0) }))
                    Toggle("Update standalone apps automatically", isOn: Binding(
                        get: { autoUpdate },
                        set: { autoUpdate = $0; Prefs.autoUpdateCopies = $0
                               StandaloneManager.shared.checkForUpdates() }))
                    Text("When Claude updates, Harbor rebuilds each standalone app the next time it isn't open. Turn this off to be asked instead.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Do you need to keep Harbor running? Once a profile's window is open, it keeps working even if you quit Harbor. Quitting only stops: live status in Harbor's window and menu bar, automatic daily backups and standalone-app update checks, and quick claude:// link routing (macOS will still relaunch Harbor to handle a link, just a bit slower).")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Update Harbor itself automatically", isOn: $autoUpdateHarbor)
                    Text("Harbor checks GitHub for newer releases of itself every few hours. With this on, it downloads and installs them, then relaunches, without asking. With it off (the default), it asks first with a link to the release.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Appearance") {
                    Picker("Look", selection: $appearance) {
                        Text("Follow macOS").tag(0)
                        Text("Day").tag(1)
                        Text("Night").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Text("Harbor shows daylight in light mode and a night harbor in dark mode. Pick Day or Night to keep one look.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Menu bar and Dock") {
                    Toggle("Show menu bar icon", isOn: $showMenuBar)
                    Toggle("Hide Dock icon", isOn: $hideDock)
                        .disabled(!showMenuBar)
                    Text("The Dock icon can only be hidden while the menu bar icon is on, so you can always reach Harbor. Turning the menu bar icon off brings the Dock icon back.")
                        .font(.caption).foregroundStyle(.secondary)
                    if Prefs.usageEnabled {
                    Toggle("Show usage in the menu bar", isOn: $showUsage)
                        .disabled(!showMenuBar)
                    LabeledContent("Session limit") {
                        TextField("Session limit", value: $sessionLimit, format: .number, prompt: Text("0 = automatic"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder).frame(width: 130)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Week limit") {
                        TextField("Week limit", value: $weekLimit, format: .number, prompt: Text("0 = automatic"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder).frame(width: 130)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Match Claude's own numbers") {
                        HStack(spacing: 6) {
                            Text("Session").font(.caption).foregroundStyle(.secondary)
                            TextField("%", text: $sessionPct).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 46)
                            Text("Week").font(.caption).foregroundStyle(.secondary)
                            TextField("%", text: $weekPct).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 46)
                            Button("Calibrate") { calibrate() }.controlSize(.small)
                        }
                    }
                    Text(calibrateNote ?? "Type the percentages Claude's own usage page shows right now, and Harbor works out the limits from your usage so far.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Usage is an estimate counted from Claude Code's session logs on this Mac. It doesn't include chats in the Claude app or on claude.ai. The percentage is measured against the limit above, or on automatic against your busiest earlier 5-hour session.")
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Locations") {
                    LabeledContent("Claude Desktop") {
                        Text(Paths.claudeApp.flatMap { StandaloneBuilder.sourceVersion(of: $0) }
                             .map { "Version \($0)" } ?? "Not found")
                            .foregroundStyle(.secondary)
                    }
                    folderRow("Profile apps", Paths.shortcutsFolder)
                    folderRow("Profile data", Paths.profilesRoot)
                }
                Section {
                    Text("Standalone apps are signed with a certificate Harbor keeps in its own keychain, so macOS asks about \"Claude Safe Storage\" only once. If signing is broken, reset it. Each standalone app will then ask once more.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(working ? "Resetting…" : "Reset signing certificate") { reset() }
                        .disabled(working)
                }
            }
            .formStyle(.grouped)
            .onChange(of: showMenuBar) { _, _ in AppPolicy.apply() }
            .onChange(of: hideDock) { _, _ in AppPolicy.apply() }
            .onChange(of: appearance) { _, _ in AppPolicy.apply() }
            .onChange(of: sessionLimit) { _, _ in UsageStore.shared.refresh() }
            .onChange(of: weekLimit) { _, _ in UsageStore.shared.refresh() }
            .tabItem { Label("Advanced", systemImage: "gearshape.2") }
            BackupSettings().environmentObject(store)
                .tabItem { Label("Backups", systemImage: "externaldrive") }
        }
        .frame(width: 520, height: 860)
    }

    private func folderRow(_ title: String, _ url: URL) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(url.path.replacingOccurrences(of: Paths.home.path, with: "~"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Show") {
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
            }
        }
    }

    private func reset() {
        working = true
        Task {
            let result: Result<Void, Error> = await Task.detached {
                SigningIdentity.reset()
                do { _ = try SigningIdentity.ensure(); return .success(()) } catch { return .failure(error) }
            }.value
            working = false
            switch result {
            case .success:
                store.notice = "The signing certificate was reset. Rebuild your standalone apps to sign them with it. Each will ask once to use \"Claude Safe Storage\": choose Always Allow."
            case .failure(let e):
                store.lastError = "Couldn't reset the signing certificate: \(e.localizedDescription)"
            }
        }
    }
}

extension Notification.Name {
    static let newProfile = Notification.Name("Harbor.newProfile")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []
    private var launched = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Handle claude:// links ourselves (only used when link routing is turned on).
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        Task { @MainActor in
            AppPolicy.apply()
            StandaloneManager.shared.start()
            HarborUpdater.shared.start()
            if Prefs.usageEnabled { UsageStore.shared.start() }
            BackupManager.shared.start()
        }
        let urls = pendingURLs
        pendingURLs = []
        // Started only to open a profile from a shortcut app: don't leave the manager window up.
        if !urls.isEmpty, urls.allSatisfy({ $0.scheme == "harbor" }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.windows.filter { $0.title == "Harbor" }.forEach { $0.close() }
            }
        }
        Task { @MainActor in urls.forEach(Self.handle) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s) else { return }
        if launched {
            Task { @MainActor in Self.handle(url) }
        } else {
            pendingURLs.append(url)
        }
    }

    /// harbor://open/<profile-id> comes from shortcut apps; claude:// links get routed.
    @MainActor static func handle(_ url: URL) {
        if url.scheme == "harbor" {
            guard url.host == "open", let id = UUID(uuidString: url.lastPathComponent),
                  let p = ProfileStore.shared.profile(id) else { return }
            Launcher.open(p)
        } else {
            Launcher.route(url)
        }
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @EnvironmentObject var store: ProfileStore
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var usage = UsageStore.shared
    @ObservedObject private var backups = BackupManager.shared

    var body: some View {
        Button {
            Launcher.openDefaultClaude()
        } label: {
            Text((store.defaultClaudeRunning ? "● " : "○ ") + "Main"
                 + (Prefs.usageEnabled ? "   " + (usage.summary(key: UsageStore.mainKey)
                                                  ?? (usage.needsSetup(key: UsageStore.mainKey) ? "Usage not set up" : "")) : ""))
        }
        ForEach(store.profiles) { p in
            Button {
                Launcher.open(p)
            } label: {
                Text((store.running[p.id] != nil ? "● " : "○ ") + p.appDisplayName
                     + (Prefs.usageEnabled ? (usage.summary(for: p.id).map { "   " + $0 } ?? "") : ""))
            }
        }
        ForEach(store.profiles.filter { store.staleRunning.contains($0.id) }) { p in
            Divider()
            Button("Update available, restart \(p.appDisplayName)") {
                Task { await StandaloneManager.shared.restartToUpdate(profileID: p.id) }
            }
        }
        if store.staleRunning.count > 1 {
            Button("Restart All to Update") {
                Task { await StandaloneManager.shared.restartAllToUpdate() }
            }
        }
        if !store.profiles.isEmpty {
            Divider()
            Button("Open Every Profile") { Launcher.openAll() }
        }
        Button("Regular Claude App") { Launcher.openDefaultClaude() }
        Divider()
        Button("Manage Profiles…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(backups.running ? "Backing up…" : "Back Up Now") {
            Task { await backups.backup(reason: "Manual backup") }
        }
        .disabled(backups.running)
        Button("Get Started Guide…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(name: .showGuide, object: nil)
            }
        }
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        Button("Check for Claude Updates…") {
            NSApp.activate(ignoringOtherApps: true)
            StandaloneManager.shared.checkNow()
        }
        Button("Check for Harbor Updates…") {
            NSApp.activate(ignoringOtherApps: true)
            HarborUpdater.shared.checkNow()
        }
        Button("Quit Harbor") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
