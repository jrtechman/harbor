import AppKit

/// User preferences kept in UserDefaults.
enum Prefs {
    private static let autoUpdateKey = "autoUpdateCopies"
    /// Rebuild out-of-date standalone apps by themselves when they aren't open. On by default.
    static var autoUpdateCopies: Bool {
        get { UserDefaults.standard.object(forKey: autoUpdateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoUpdateKey) }
    }

    static let showMenuBarKey = "showMenuBarIcon"
    static let hideDockKey = "hideDockIcon"
    static let showUsageKey = "showUsageInMenuBar"
    static let weekLimitKey = "weekTokenLimit"
    /// Tokens a week is measured against. 0 = automatic (the busiest earlier week, once there are two weeks of history).
    static var weekTokenLimit: Int { UserDefaults.standard.integer(forKey: weekLimitKey) }
    static let sessionLimitKey = "sessionTokenLimit"
    static let backupFolderKey = "backupFolder"
    static let backupKeepKey = "backupKeep"
    static let autoBackupKey = "autoBackup"
    /// Where backups go. Nil = Harbor's own folder.
    static var backupFolder: URL? {
        UserDefaults.standard.string(forKey: backupFolderKey).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }
    /// How many snapshots to keep.
    static var backupKeep: Int { let n = UserDefaults.standard.integer(forKey: backupKeepKey); return n > 0 ? n : 14 }
    /// Daily automatic backups. On by default.
    static var autoBackup: Bool { UserDefaults.standard.object(forKey: autoBackupKey) as? Bool ?? true }
    /// Whether the usage feature shows anywhere in the app. Off for now; the code stays for later.
    static let usageEnabled = false
    static let usageSetupShownKey = "usageSetupShown"
    /// Whether the one-time "set up usage" prompt has been shown.
    static var usageSetupShown: Bool {
        get { UserDefaults.standard.bool(forKey: usageSetupShownKey) }
        set { UserDefaults.standard.set(newValue, forKey: usageSetupShownKey) }
    }
    static let walkthroughSeenKey = "walkthroughSeen"
    /// Whether the get-started guide has been shown.
    static var walkthroughSeen: Bool {
        get { UserDefaults.standard.bool(forKey: walkthroughSeenKey) }
        set { UserDefaults.standard.set(newValue, forKey: walkthroughSeenKey) }
    }
    static let appearanceKey = "appearance"
    /// 0 = follow macOS, 1 = day, 2 = night.
    static var appearance: Int { UserDefaults.standard.integer(forKey: appearanceKey) }
    /// Tokens a 5-hour session is measured against. 0 = automatic (the busiest earlier session).
    static var sessionTokenLimit: Int {
        UserDefaults.standard.integer(forKey: sessionLimitKey)
    }
    /// The menu bar icon. On by default.
    static var showMenuBarIcon: Bool {
        UserDefaults.standard.object(forKey: showMenuBarKey) as? Bool ?? true
    }
    /// Hide the Dock icon. Only takes effect while the menu bar icon is on, so Harbor stays reachable.
    static var hideDockIcon: Bool {
        UserDefaults.standard.object(forKey: hideDockKey) as? Bool ?? false
    }
}

/// Shows or hides Harbor's Dock icon. Hidden only when the menu bar icon is on.
@MainActor
enum AppPolicy {
    static func apply() {
        let hide = Prefs.hideDockIcon && Prefs.showMenuBarIcon
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
        switch Prefs.appearance {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

/// Turns standalone mode on and off, rebuilds copies, and keeps them in step with Claude.app.
@MainActor
final class StandaloneManager {
    static let shared = StandaloneManager()
    private var store: ProfileStore { .shared }

    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingCheck: DispatchWorkItem?
    /// Profile → Claude version whose automatic rebuild failed, so we don't retry (and nag) every 30 minutes.
    private var failedAuto: [UUID: String] = [:]

    // MARK: Turning it on and off

    func setStandalone(_ on: Bool, profileID: UUID) async {
        guard let p = store.profile(profileID) else { return }
        if on {
            guard confirmUnmanaged() else { return }
            var q = p
            q.standalone = true
            if await rebuild(q) { store.update(q) }
        } else {
            if store.running[p.id] != nil {
                store.lastError = "Quit \(p.appDisplayName) before turning off its standalone app."
                return
            }
            var q = p
            q.standalone = false
            ShortcutBuilder.removeShortcut(for: p)
            store.update(q)
            store.staleRunning.remove(p.id)
            do { try ShortcutBuilder.build(for: q) }
            catch { store.lastError = "Couldn't restore the shortcut app: \(error.localizedDescription)" }
        }
    }

    /// Managed (MDM) installs may fight a copy of Claude, so warn first.
    private func confirmUnmanaged() -> Bool {
        let fm = FileManager.default
        let user = NSUserName()
        let paths = ["/Library/Managed Preferences/\(Paths.claudeBundleID).plist",
                     "/Library/Managed Preferences/\(user)/\(Paths.claudeBundleID).plist"]
        guard paths.contains(where: { fm.fileExists(atPath: $0) }) else { return true }
        let alert = NSAlert()
        alert.messageText = "Claude is managed by your organization"
        alert.informativeText = "Claude has managed settings on this Mac. A standalone copy may not follow them, and your IT team may not support it. Make one anyway?"
        alert.addButton(withTitle: "Make Standalone App")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Building

    /// Builds (or rebuilds) a profile's standalone app. Returns true on success.
    /// `old` is the profile before a rename, so the app under its old name can go to the Trash.
    @discardableResult
    func rebuild(_ p: Profile, replacingNameOf old: Profile? = nil, silent: Bool = false) async -> Bool {
        guard store.buildSteps[p.id] == nil else { return false }
        if store.running[p.id] != nil {
            if !silent { store.lastError = "Quit \(old?.appDisplayName ?? p.appDisplayName) first, then try again. Its standalone app can't be built while it's open." }
            return false
        }
        guard let claude = Paths.claudeApp else {
            if !silent { store.lastError = "Claude Desktop isn't installed in /Applications." }
            return false
        }
        guard let version = StandaloneBuilder.sourceVersion(of: claude) else {
            if !silent { store.lastError = "Claude looks like it's in the middle of an update. Try again in a minute." }
            return false
        }
        store.buildSteps[p.id] = "Preparing…"
        defer { store.buildSteps[p.id] = nil }

        let icns = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-icon-\(UUID().uuidString).icns")
        defer { try? FileManager.default.removeItem(at: icns) }
        do {
            try ShortcutBuilder.writeIcon(for: p, claude: claude, to: icns)
            guard FileManager.default.fileExists(atPath: icns.path) else {
                throw SigningError(message: "Couldn't make the icon.")
            }
        } catch {
            store.lastError = "Couldn't build \(p.appDisplayName): \(error.localizedDescription)"
            return false
        }

        let id = p.id
        let input = StandaloneBuilder.Input(
            profile: p, claude: claude, sourceVersion: version, icns: icns,
            destination: Paths.standaloneURL(for: p),
            progress: { step in Task { @MainActor in ProfileStore.shared.buildSteps[id] = step } })
        do {
            try? FileManager.default.createDirectory(at: p.dataURL, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let result = try await Task.detached(priority: .userInitiated) {
                try StandaloneBuilder.build(input)
            }.value
            if let old, old.name != p.name { ShortcutBuilder.removeShortcut(for: old) }
            NSWorkspace.shared.noteFileSystemChanged(input.destination.path)
            failedAuto[p.id] = nil
            store.staleRunning.remove(p.id)
            if !result.notices.isEmpty { store.notice = result.notices.joined(separator: "\n\n") }
            return true
        } catch {
            store.lastError = "Couldn't build \(p.appDisplayName): \(error.localizedDescription)"
            failedAuto[p.id] = version
            return false
        }
    }

    /// Quit, rebuild, reopen.
    func restartToUpdate(profileID: UUID) async {
        guard let p = store.profile(profileID) else { return }
        Launcher.quit(p)
        for _ in 0..<40 {
            store.refreshRunning()
            if store.running[p.id] == nil { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard store.running[p.id] == nil else {
            store.lastError = "\(p.appDisplayName) didn't quit. Save your work, quit it, then try again."
            return
        }
        failedAuto[p.id] = nil
        if await rebuild(p) { Launcher.open(p) }
    }

    /// Quit every open, out-of-date standalone app, rebuild them all, then reopen them.
    func restartAllToUpdate() async {
        let ids = store.profiles.filter { store.staleRunning.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { if let p = store.profile(id) { Launcher.quit(p) } }
        for _ in 0..<40 {
            store.refreshRunning()
            if ids.allSatisfy({ store.running[$0] == nil }) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        var rebuilt: [Profile] = []
        for id in ids {
            guard let p = store.profile(id) else { continue }
            guard store.running[id] == nil else {
                store.lastError = "\(p.appDisplayName) didn't quit. Save your work, quit it, then try again."
                continue
            }
            failedAuto[id] = nil
            if await rebuild(p) { rebuilt.append(p) }
        }
        rebuilt.forEach { Launcher.open($0) }
    }

    /// "Check for Claude Updates…": runs the check now and says so when everything is current.
    func checkNow() {
        promptedVersion = nil
        checkForUpdates()
        func say(_ text: String) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = text
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        guard let claude = Paths.claudeApp, StandaloneBuilder.sourceVersion(of: claude) != nil else {
            say("Claude Desktop isn't installed in /Applications, or is in the middle of an update. Try again in a minute.")
            return
        }
        if store.staleRunning.isEmpty && !store.profiles.contains(where: { store.buildSteps[$0.id] != nil }) {
            say("Your standalone apps are up to date with Claude.")
        }
    }

    // MARK: Keeping copies up to date

    func start() {
        checkForUpdates()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates() }
        }
        watchClaude()
    }

    /// Rebuilds out-of-date copies that aren't open; flags the ones that are.
    func checkForUpdates() {
        if watcher == nil { watchClaude() }
        guard let claude = Paths.claudeApp, let version = StandaloneBuilder.sourceVersion(of: claude) else { return }
        store.refreshRunning()
        for p in store.profiles where p.standalone {
            guard store.buildSteps[p.id] == nil, StandaloneBuilder.isStale(p, claudeVersion: version) else {
                store.staleRunning.remove(p.id)
                continue
            }
            if store.running[p.id] != nil || !Prefs.autoUpdateCopies {
                // Open, or automatic rebuilds are off: ask the user instead of rebuilding.
                store.staleRunning.insert(p.id)
            } else if failedAuto[p.id] != version {
                Task { await rebuild(p, silent: true) }
            }
        }
        promptToRestart(version: version)
    }

    /// Claude version we already asked about, so the popup shows once per update.
    private var promptedVersion: String?

    /// "Claude has a new version, restart to update." Shown once per Claude version while
    /// standalone apps that are open are out of date.
    private func promptToRestart(version: String) {
        let stale = store.profiles.filter { store.staleRunning.contains($0.id) }
        guard !stale.isEmpty, promptedVersion != version else { return }
        promptedVersion = version
        // Let the app finish launching before a modal dialog appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let stale = self.store.profiles.filter { self.store.staleRunning.contains($0.id) }
            guard !stale.isEmpty else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Claude has a new version"
            alert.informativeText = "Restart to update: " + stale.map(\.appDisplayName).joined(separator: ", ")
                + ". They'll close, update and reopen. Save your work first."
            alert.addButton(withTitle: "Restart to Update")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await self.restartAllToUpdate() }
            }
        }
    }

    /// Watches Claude.app's Info.plist; an update replaces it.
    private func watchClaude() {
        watcher?.cancel()
        watcher = nil
        guard let claude = Paths.claudeApp else { return }
        let fd = open(claude.appendingPathComponent("Contents/Info.plist").path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: .main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.claudeChanged() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func claudeChanged() {
        // The file is often replaced, so watch the new one, and give the update time to finish.
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.watchClaude()
                self?.checkForUpdates()
            }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }
}
