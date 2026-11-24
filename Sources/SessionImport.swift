import Foundation

/// Copies Claude Code session entries (the Code tab's chat list) from one Claude data folder
/// into a Harbor profile's data folder, so a new profile doesn't start with an empty Code tab.
///
/// Safety rules:
/// - Copy only. The source is never changed.
/// - Fields that carry permissions or account-specific connections are removed, so an imported
///   session never inherits grants (computer use, clipboard, always-allowed tools) or connector
///   settings from the account it came from.
/// - Existing sessions are never overwritten.
/// - Every import is recorded, so it can be undone.
/// The chat transcripts themselves live under ~/.claude/projects and are not copied.
enum SessionImporter {
    /// Keys removed from each imported session file.
    static let strippedKeys: Set<String> = [
        "enabledMcpTools", "remoteMcpServersConfig", "connectorKeyHolders",
        "cuAllowedApps", "cuGrantFlags", "chromePermissionMode",
        "sessionPermissionUpdates", "alwaysAllowedReasons",
        "promptAppendSnapshot", "toolSurfaceSnapshot",
    ]

    struct Entry {
        let url: URL
        let sessionID: String
        let title: String
    }

    struct Preview {
        var entries: [Entry] = []          // sessions that would be copied
        var alreadyThere = 0               // sessions the profile already has
        var destination: URL?              // account/org folder inside the profile
        var problem: String?               // why an import can't happen yet
    }

    /// Debug/testing override: set HARBOR_IMPORT_SOURCE to read from another folder.
    private static var sourceOverride: String? {
        ProcessInfo.processInfo.environment["HARBOR_IMPORT_SOURCE"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static var defaultSource: URL {
        if let o = sourceOverride { return URL(fileURLWithPath: o, isDirectory: true) }
        return Paths.home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }

    /// True when reading from the live regular Claude app, whose files must not be changing.
    static var readsLiveClaude: Bool { sourceOverride == nil }

    private static let fm = FileManager.default

    /// The `<account>/<org>` folders under a data folder's claude-code-sessions.
    private static func idFolders(in data: URL) -> [URL] {
        let root = data.appendingPathComponent("claude-code-sessions", isDirectory: true)
        let accounts = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return accounts.flatMap { a -> [URL] in
            guard (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [] }
            let orgs = (try? fm.contentsOfDirectory(at: a, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            return orgs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
    }

    private static func sessionFiles(in folder: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// What an import from `source` into `destData` would do. Reads names and titles only.
    static func preview(source: URL, into destData: URL) -> Preview {
        var p = Preview()
        let sources = idFolders(in: source).flatMap(sessionFiles(in:))
        guard !sources.isEmpty else {
            p.problem = "No Claude Code sessions were found in the main Claude app."
            return p
        }
        // The profile's own account folder exists once its Code tab has been opened while signed in.
        guard let dest = idFolders(in: destData).max(by: { modified($0) < modified($1) }) else {
            p.problem = "Open this profile, sign in, and open its Code tab once. Then try again."
            return p
        }
        p.destination = dest
        let have = Set(sessionFiles(in: dest).map(\.lastPathComponent))
        var seen = Set<String>()
        for url in sources.sorted(by: { modified($0) > modified($1) }) {
            let name = url.lastPathComponent
            guard seen.insert(name).inserted else { continue }
            if have.contains(name) { p.alreadyThere += 1; continue }
            let obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
            guard let obj, let id = obj["sessionId"] as? String else { continue }
            p.entries.append(Entry(url: url, sessionID: id, title: (obj["title"] as? String) ?? "Untitled"))
        }
        if p.entries.isEmpty && p.alreadyThere == 0 { p.problem = "No readable Claude Code sessions were found." }
        return p
    }

    /// Copies the previewed sessions. Returns the file names written.
    @discardableResult
    static func run(_ preview: Preview, profileID: UUID) throws -> [String] {
        guard let dest = preview.destination else { return [] }
        var written: [String] = []
        for e in preview.entries {
            let target = dest.appendingPathComponent(e.url.lastPathComponent)
            guard !fm.fileExists(atPath: target.path) else { continue }
            guard var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: e.url)) as? [String: Any] else { continue }
            for k in strippedKeys { obj.removeValue(forKey: k) }
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            let tmp = dest.appendingPathComponent(".harbor-import-\(UUID().uuidString).tmp")
            try data.write(to: tmp)
            try fm.moveItem(at: tmp, to: target)
            written.append(target.lastPathComponent)
        }
        try record(written, in: dest, profileID: profileID)
        return written
    }

    // MARK: Undo

    private struct Record: Codable { var folder: String; var files: [String]; var date: Date }

    private static func recordURL(_ id: UUID) -> URL {
        Paths.support.appendingPathComponent("Imports/\(id.uuidString).json")
    }

    private static func record(_ files: [String], in folder: URL, profileID: UUID) throws {
        guard !files.isEmpty else { return }
        try fm.createDirectory(at: recordURL(profileID).deletingLastPathComponent(), withIntermediateDirectories: true)
        var all = (try? load(profileID)) ?? []
        all.append(Record(folder: folder.path, files: files, date: Date()))
        try JSONEncoder.iso.encode(all).write(to: recordURL(profileID), options: .atomic)
    }

    private static func load(_ id: UUID) throws -> [Record] {
        try JSONDecoder.iso.decode([Record].self, from: Data(contentsOf: recordURL(id)))
    }

    static func lastImportCount(profileID: UUID) -> Int {
        ((try? load(profileID)) ?? []).last?.files.count ?? 0
    }

    /// Removes the files written by the most recent import.
    @discardableResult
    static func undoLast(profileID: UUID) throws -> Int {
        var all = try load(profileID)
        guard let last = all.popLast() else { return 0 }
        var removed = 0
        for f in last.files {
            let u = URL(fileURLWithPath: last.folder).appendingPathComponent(f)
            if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u); removed += 1 }
        }
        if all.isEmpty { try? fm.removeItem(at: recordURL(profileID)) }
        else { try JSONEncoder.iso.encode(all).write(to: recordURL(profileID), options: .atomic) }
        return removed
    }
}
