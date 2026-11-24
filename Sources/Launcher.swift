import AppKit
import Carbon.HIToolbox

@MainActor
enum Launcher {
    static var store: ProfileStore { .shared }

    static func claudeAppOrReport() -> URL? {
        if let u = Paths.claudeApp { return u }
        store.lastError = "Claude Desktop isn't installed in /Applications. Download it from claude.ai/download first."
        return nil
    }

    /// Opens (or brings forward) the Claude window for a profile.
    static func open(_ p: Profile, thenOpen url: URL? = nil) {
        store.refreshRunning()
        if let app = store.running[p.id] {
            app.unhide()
            app.activate()
            if let url { deliver(url, to: app) }
            return
        }
        let standaloneApp = Paths.standaloneURL(for: p)
        let useStandalone = p.standalone
            && FileManager.default.fileExists(atPath: standaloneApp.appendingPathComponent("Contents/MacOS/\(StandaloneBuilder.launcherName)").path)
        guard useStandalone || claudeAppOrReport() != nil else { return }
        do {
            try FileManager.default.createDirectory(at: p.dataURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            store.lastError = "Couldn't create the data folder for \(p.name): \(error.localizedDescription)"
            return
        }
        if useStandalone {
            openStandalone(p, at: standaloneApp, thenOpen: url)
            return
        }
        guard let claude = Paths.claudeApp else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.arguments = ["--user-data-dir=\(p.dataPath)"]
        cfg.activates = true
        let done: @Sendable (NSRunningApplication?, Error?) -> Void = { _, error in
            Task { @MainActor in
                if let error { store.lastError = "Couldn't start \(p.appDisplayName): \(error.localizedDescription)" }
                store.refreshRunning()
            }
        }
        if let url {
            NSWorkspace.shared.open([url], withApplicationAt: claude, configuration: cfg, completionHandler: done)
        } else {
            NSWorkspace.shared.openApplication(at: claude, configuration: cfg, completionHandler: done)
        }
    }

    /// Starts a profile's standalone app. Its launcher supplies --user-data-dir.
    private static func openStandalone(_ p: Profile, at app: URL, thenOpen url: URL?) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = false
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, error in
            Task { @MainActor in
                if let error {
                    store.lastError = "Couldn't start \(p.appDisplayName): \(error.localizedDescription)"
                    return
                }
                store.refreshRunning()
                // The copy doesn't claim claude:// links, so hand the link over once it's up.
                guard let url else { return }
                for _ in 0..<40 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    store.refreshRunning()
                    if let running = store.running[p.id] {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        deliver(url, to: running)
                        return
                    }
                }
            }
        }
    }

    static func openAll() {
        for p in store.profiles where store.running[p.id] == nil { open(p) }
    }

    static func quit(_ p: Profile) {
        store.running[p.id]?.terminate()
    }

    /// Opens the regular Claude app with its normal account.
    static func openDefaultClaude() {
        guard let claude = claudeAppOrReport() else { return }
        if let app = ClaudeProcesses.all().first(where: { $0.dataPath == nil })?.app {
            app.activate()
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: claude, configuration: cfg)
    }

    // MARK: Claude Code

    /// Opens Terminal running `claude` with this profile's own CLAUDE_CONFIG_DIR.
    static func openClaudeCode(_ p: Profile) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: p.codeConfigPath, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let dir = Paths.support.appendingPathComponent("Terminal", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let script = dir.appendingPathComponent("\(p.id.uuidString).command")
            let body = """
            #!/bin/zsh -l
            export CLAUDE_CONFIG_DIR=\(shellQuote(p.codeConfigPath))
            cd ~
            clear
            echo "Claude Code — profile: \(p.name.replacingOccurrences(of: "\"", with: ""))"
            echo "Config folder: $CLAUDE_CONFIG_DIR"
            echo
            if command -v claude >/dev/null 2>&1; then
              claude
            else
              echo "The 'claude' command isn't installed. See https://docs.claude.com/claude-code"
            fi
            exec "$SHELL" -l

            """
            try body.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            store.lastError = "Couldn't open Claude Code: \(error.localizedDescription)"
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: claude:// link routing

    static var isLinkRouter: Bool {
        guard let probe = URL(string: "claude://claude.ai/new"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    static func setLinkRouting(_ on: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        let target = on ? Bundle.main.bundleURL : Paths.claudeApp
        guard let target else { completion(false); return }
        NSWorkspace.shared.setDefaultApplication(at: target, toOpenURLsWithScheme: "claude") { error in
            Task { @MainActor in
                if let error { store.lastError = "Couldn't change the claude:// link handler: \(error.localizedDescription)" }
                completion(error == nil)
            }
        }
    }

    /// Called when a claude:// link reaches Harbor.
    static func route(_ url: URL) {
        store.refreshRunning()
        let runningProfiles = store.profiles.filter { store.running[$0.id] != nil }

        if let last = store.profile(store.lastActiveProfile), store.running[last.id] != nil {
            open(last, thenOpen: url); return
        }
        if runningProfiles.count == 1 { open(runningProfiles[0], thenOpen: url); return }

        let candidates = runningProfiles.isEmpty ? store.profiles : runningProfiles
        if candidates.isEmpty { handToDefaultClaude(url); return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Which profile is this link for?"
        alert.informativeText = url.absoluteString.count > 120
            ? String(url.absoluteString.prefix(120)) + "…" : url.absoluteString
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        for p in candidates { popup.addItem(withTitle: p.appDisplayName) }
        popup.addItem(withTitle: "Regular Claude app")
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let i = popup.indexOfSelectedItem
        if i < candidates.count { open(candidates[i], thenOpen: url) } else { handToDefaultClaude(url) }
    }

    static func handToDefaultClaude(_ url: URL) {
        if let app = ClaudeProcesses.all().first(where: { $0.dataPath == nil })?.app {
            deliver(url, to: app); app.activate(); return
        }
        guard let claude = claudeAppOrReport() else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.open([url], withApplicationAt: claude, configuration: cfg)
    }

    /// Sends a "get URL" Apple event to one specific Claude process.
    static func deliver(_ url: URL, to app: NSRunningApplication) {
        let target = NSAppleEventDescriptor(processIdentifier: app.processIdentifier)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass),
                                           eventID: AEEventID(kAEGetURL),
                                           targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 10)
        } catch {
            store.lastError = "Couldn't pass the link to Claude: \(error.localizedDescription). " +
                "If macOS asked about letting Harbor control Claude, allow it in System Settings › Privacy & Security › Automation."
        }
    }
}
