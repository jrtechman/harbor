import AppKit

/// Profile actions shared by the main window's log panel and the full settings sheet.
@MainActor
enum ProfileActions {
    static var store: ProfileStore { .shared }

    /// Renames/recolors a profile and rebuilds its standalone app or shortcut. `name` must be non-empty.
    static func commitEdits(_ profile: Profile, name: String, color: ProfileColor) {
        let old = profile
        var p = profile
        p.name = String(name.prefix(40))
        p.color = color
        guard p != old else { return }
        if p.standalone && store.running[p.id] != nil {
            store.lastError = "Quit \(old.appDisplayName) first, then save again so its app can be rebuilt."
            return
        }
        store.update(p)
        if p.standalone {
            Task { await StandaloneManager.shared.rebuild(p, replacingNameOf: old) }
        } else if ShortcutBuilder.exists(for: old) {
            _ = try? ShortcutBuilder.build(for: p, replacingNameOf: old)
        }
    }

    /// Creates or rebuilds the profile's shortcut app (or its standalone app) and reveals it.
    static func buildShortcut(_ profile: Profile) {
        if let p = store.profile(profile.id), p.standalone {
            Task {
                if await StandaloneManager.shared.rebuild(p) {
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.standaloneURL(for: p)])
                }
            }
            return
        }
        do {
            let url = try ShortcutBuilder.build(for: profile)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            store.lastError = "Couldn't create the app: \(error.localizedDescription)"
        }
    }

    /// Previews and, once confirmed, copies the regular app's Claude Code sessions into the profile.
    static func importSessions(_ profile: Profile) {
        guard store.running[profile.id] == nil else {
            store.lastError = "Quit \(profile.appDisplayName) first, so its files aren't changing while they're copied."
            return
        }
        store.refreshRunning()
        if SessionImporter.readsLiveClaude, ClaudeProcesses.all().contains(where: { $0.dataPath == nil }) {
            store.lastError = "Quit the regular Claude app first, so its files aren't changing while they're read."
            return
        }
        let preview = SessionImporter.preview(source: SessionImporter.defaultSource, into: profile.dataURL)
        if let problem = preview.problem { store.notice = problem; return }
        if preview.entries.isEmpty {
            store.notice = "This profile already has all \(preview.alreadyThere) of the regular app's Claude Code sessions."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Import \(preview.entries.count) Claude Code session\(preview.entries.count == 1 ? "" : "s")?"
        let titles = preview.entries.prefix(8).map { "• " + $0.title }.joined(separator: "\n")
        let more = preview.entries.count > 8 ? "\n…and \(preview.entries.count - 8) more" : ""
        let skip = preview.alreadyThere > 0 ? "\n\n\(preview.alreadyThere) already in this profile will be skipped." : ""
        alert.informativeText = "Into \(profile.appDisplayName):\n\(titles)\(more)\(skip)\n\nThe regular app isn't changed. You can undo this afterwards."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            // Back up first, so an import can always be undone from a snapshot as well.
            guard await BackupManager.shared.protect("Before importing sessions into \(profile.appDisplayName)") else { return }
            do {
                let written = try SessionImporter.run(preview, profileID: profile.id)
                store.notice = "Imported \(written.count) session\(written.count == 1 ? "" : "s"). They appear in \(profile.appDisplayName)'s Code tab the next time it opens."
            } catch {
                store.lastError = "Couldn't import sessions: \(error.localizedDescription)"
            }
        }
    }

    static func undoImport(_ profile: Profile) {
        do {
            let n = try SessionImporter.undoLast(profileID: profile.id)
            store.notice = "Removed \(n) imported session\(n == 1 ? "" : "s")."
        } catch {
            store.lastError = "Couldn't undo the import: \(error.localizedDescription)"
        }
    }
}
