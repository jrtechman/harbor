import AppKit

/// One backed-up folder inside a snapshot.
struct BackupEntry: Codable, Hashable, Identifiable {
    var id: String               // stable name, also the folder name inside the snapshot
    var kind: String             // "sessions", "agent" or "transcripts"
    var label: String            // "Work · Code-tab sessions"
    var profileID: UUID?         // nil for the regular Claude app
    var destination: String      // where a restore puts the files
    var files: Int
    var bytes: Int64
}

struct BackupManifest: Codable {
    var version = 1
    var date: Date
    var reason: String
    var profiles: [Profile]      // the profile list at the time, so a deleted profile can be brought back
    var entries: [BackupEntry]
    var copied: Int
    var linked: Int
    var failed: Int
}

struct BackupSnapshot: Identifiable, Sendable {
    var id: String               // folder name
    var url: URL
    var manifest: BackupManifest
}

/// Snapshots of what holds your Claude Code history. Never touches sign-ins, cookies or caches.
/// Unchanged files are hard-linked to the previous snapshot, so each extra snapshot costs little disk.
enum BackupEngine {
    struct Source: Sendable {
        let id: String
        let kind: String
        let label: String
        let profileID: UUID?
        let url: URL
    }

    struct Stats { var files = 0; var bytes: Int64 = 0; var linked = 0; var copied = 0; var failed = 0 }

    private static let nameFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HHmmss"
        return f
    }()

    // MARK: Which folders

    /// The folders that hold session history: the regular app's, each profile's, and unlisted data folders.
    static func sources(profiles: [Profile], unlisted: [UUID], home: URL = Paths.home) -> [Source] {
        let fm = FileManager.default
        var out: [Source] = []
        func add(_ id: String, _ kind: String, _ label: String, _ pid: UUID?, _ url: URL) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                out.append(Source(id: id, kind: kind, label: label, profileID: pid, url: url))
            }
        }
        let main = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        add("main-sessions", "sessions", "Regular Claude · Code-tab sessions", nil, main.appendingPathComponent("claude-code-sessions"))
        add("main-agent", "agent", "Regular Claude · local agent sessions", nil, main.appendingPathComponent("local-agent-mode-sessions"))
        add("main-transcripts", "transcripts", "Regular Claude · Claude Code transcripts", nil, home.appendingPathComponent(".claude/projects"))
        for p in profiles {
            let key = p.id.uuidString
            add("profile-\(key)-sessions", "sessions", "\(p.name) · Code-tab sessions", p.id, p.dataURL.appendingPathComponent("claude-code-sessions"))
            add("profile-\(key)-agent", "agent", "\(p.name) · local agent sessions", p.id, p.dataURL.appendingPathComponent("local-agent-mode-sessions"))
            add("profile-\(key)-transcripts", "transcripts", "\(p.name) · Claude Code transcripts", p.id,
                URL(fileURLWithPath: p.codeConfigPath).appendingPathComponent("projects"))
        }
        for u in unlisted {
            let short = String(u.uuidString.prefix(8))
            let base = Paths.profilesRoot.appendingPathComponent(u.uuidString, isDirectory: true)
            add("unlisted-\(u.uuidString)-sessions", "sessions", "Unlisted folder \(short) · Code-tab sessions", u,
                base.appendingPathComponent("Data/claude-code-sessions"))
            add("unlisted-\(u.uuidString)-agent", "agent", "Unlisted folder \(short) · local agent sessions", u,
                base.appendingPathComponent("Data/local-agent-mode-sessions"))
        }
        return out
    }

    // MARK: Snapshots

    static func list(root: URL) -> [BackupSnapshot] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var snaps: [BackupSnapshot] = []
        for d in dirs where !d.lastPathComponent.hasPrefix(".") {
            let m = d.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: m),
                  let manifest = try? JSONDecoder.iso.decode(BackupManifest.self, from: data) else { continue }
            snaps.append(BackupSnapshot(id: d.lastPathComponent, url: d, manifest: manifest))
        }
        return snaps.sorted { $0.manifest.date > $1.manifest.date }
    }

    /// Blocking. Makes one snapshot, then removes the oldest beyond `keep`.
    static func run(root: URL, sources: [Source], profiles: [Profile], reason: String, keep: Int,
                    now: Date = Date()) throws -> BackupSnapshot {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // Clear leftovers of a snapshot that never finished.
        for d in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where d.lastPathComponent.hasPrefix(".incomplete-") {
            let age = (try? d.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { now.timeIntervalSince($0) } ?? 9999
            if age > 600 { try? fm.removeItem(at: d) }
        }

        var name = nameFormat.string(from: now)
        var n = 2
        while fm.fileExists(atPath: root.appendingPathComponent(name).path) { name = nameFormat.string(from: now) + "-\(n)"; n += 1 }
        let tmp = root.appendingPathComponent(".incomplete-\(name)", isDirectory: true)
        let final = root.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp.appendingPathComponent("files"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let previous = list(root: root).first?.url

        var entries: [BackupEntry] = []
        var total = Stats()
        for s in sources {
            let st = copyTree(from: s.url, to: tmp.appendingPathComponent("files/\(s.id)"),
                              previous: previous?.appendingPathComponent("files/\(s.id)"))
            entries.append(BackupEntry(id: s.id, kind: s.kind, label: s.label, profileID: s.profileID,
                                       destination: s.url.path, files: st.files, bytes: st.bytes))
            total.copied += st.copied; total.linked += st.linked; total.failed += st.failed
        }
        let manifest = BackupManifest(date: now, reason: reason, profiles: profiles, entries: entries,
                                      copied: total.copied, linked: total.linked, failed: total.failed)
        try JSONEncoder.iso.encode(manifest).write(to: tmp.appendingPathComponent("manifest.json"))
        // A readable copy of the profile list, for a person looking in the folder.
        if let list = try? Data(contentsOf: Paths.store) { try? list.write(to: tmp.appendingPathComponent("profiles.json")) }
        try fm.moveItem(at: tmp, to: final)

        // Keep the newest `keep`.
        let all = list(root: root)
        for old in all.dropFirst(max(1, keep)) { try? fm.removeItem(at: old.url) }
        return BackupSnapshot(id: name, url: final, manifest: manifest)
    }

    /// Copies a folder. Files unchanged since the previous snapshot are hard-linked instead of copied.
    static func copyTree(from src: URL, to dst: URL, previous: URL?) -> Stats {
        let fm = FileManager.default
        var st = Stats()
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for rel in (try? fm.subpathsOfDirectory(atPath: src.path)) ?? [] {
            if rel.hasSuffix(".DS_Store") { continue }
            let s = src.appendingPathComponent(rel), d = dst.appendingPathComponent(rel)
            guard let attrs = try? fm.attributesOfItem(atPath: s.path), let type = attrs[.type] as? FileAttributeType else { continue }
            if type == .typeDirectory {
                try? fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                continue
            }
            guard type == .typeRegular else { continue }       // symlinks and special files are skipped
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            st.files += 1; st.bytes += size
            if let prev = previous {
                let p = prev.appendingPathComponent(rel)
                if let pa = try? fm.attributesOfItem(atPath: p.path),
                   (pa[.size] as? NSNumber)?.int64Value == size,
                   abs(((pa[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince(mtime)) < 1,
                   (try? fm.linkItem(at: p, to: d)) != nil {
                    st.linked += 1
                    continue
                }
            }
            do {
                try fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                try fm.copyItem(at: s, to: d)
                try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: d.path)
                st.copied += 1
            } catch {
                st.failed += 1
            }
        }
        return st
    }

    /// Puts back files that are missing. Never overwrites and never deletes, so a restore can't lose anything.
    static func restore(_ entry: BackupEntry, from snapshot: BackupSnapshot) -> (copied: Int, skipped: Int, failed: Int) {
        let fm = FileManager.default
        let src = snapshot.url.appendingPathComponent("files/\(entry.id)")
        let dst = URL(fileURLWithPath: entry.destination, isDirectory: true)
        var r = (copied: 0, skipped: 0, failed: 0)
        for rel in (try? fm.subpathsOfDirectory(atPath: src.path)) ?? [] {
            let s = src.appendingPathComponent(rel), d = dst.appendingPathComponent(rel)
            guard let attrs = try? fm.attributesOfItem(atPath: s.path), (attrs[.type] as? FileAttributeType) == .typeRegular else { continue }
            if fm.fileExists(atPath: d.path) { r.skipped += 1; continue }
            do {
                try fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: s, to: d)
                if let m = attrs[.modificationDate] as? Date { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: d.path) }
                r.copied += 1
            } catch { r.failed += 1 }
        }
        return r
    }
}

/// Runs backups: daily while Harbor is open, and before anything that could lose history.
@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()

    @Published private(set) var running = false
    @Published private(set) var snapshots: [BackupSnapshot] = []
    @Published private(set) var lastSummary: String?
    private var timer: Timer?

    var root: URL { Prefs.backupFolder ?? Paths.support.appendingPathComponent("Backups", isDirectory: true) }
    var lastDate: Date? { snapshots.first?.manifest.date }

    func start() {
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.maybeAuto() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.maybeAuto() }
        }
    }

    func refresh() { snapshots = BackupEngine.list(root: root) }

    private func maybeAuto() {
        guard Prefs.autoBackup, !running else { return }
        refresh()
        if let last = lastDate, Date().timeIntervalSince(last) < 86400 { return }
        Task { _ = await backup(reason: "Daily backup") }
    }

    /// Makes a snapshot now. Returns true when it was saved.
    @discardableResult
    func backup(reason: String) async -> Bool {
        while running { try? await Task.sleep(nanoseconds: 300_000_000) }
        running = true
        defer { running = false }
        let store = ProfileStore.shared
        let profiles = store.profiles
        let unlisted = store.unlistedFolders()
        let sources = BackupEngine.sources(profiles: profiles, unlisted: unlisted)
        let root = self.root, keep = Prefs.backupKeep
        let result: Result<BackupSnapshot, Error> = await Task.detached(priority: .utility) {
            Result { try BackupEngine.run(root: root, sources: sources, profiles: profiles, reason: reason, keep: keep) }
        }.value
        switch result {
        case .success(let snap):
            refresh()
            let m = snap.manifest
            lastSummary = "Backed up \(m.entries.reduce(0) { $0 + $1.files }) files (\(m.copied) new or changed)."
                + (m.failed > 0 ? " \(m.failed) couldn't be read." : "")
            return true
        case .failure(let error):
            lastSummary = "The backup didn't finish: \(error.localizedDescription)"
            return false
        }
    }

    /// A backup before something risky. If it fails, the caller should not go ahead.
    func protect(_ reason: String) async -> Bool {
        let ok = await backup(reason: reason)
        if !ok { ProfileStore.shared.lastError = "Harbor couldn't back up first, so nothing was changed. \(lastSummary ?? "")" }
        return ok
    }

    struct RestoreOutcome { let text: String; let ok: Bool }

    /// Restores missing files from a snapshot, and says what happened.
    func restore(_ entry: BackupEntry, from snap: BackupSnapshot) async -> RestoreOutcome {
        let store = ProfileStore.shared
        store.refreshRunning()
        if let pid = entry.profileID, store.running[pid] != nil {
            return RestoreOutcome(text: "Quit that profile first, so its files aren't changing while they're restored.", ok: false)
        }
        if entry.profileID == nil, ClaudeProcesses.all().contains(where: { $0.dataPath == nil }) {
            return RestoreOutcome(text: "Quit the regular Claude app first, so its files aren't changing while they're restored.", ok: false)
        }
        // A fresh backup first, so a restore can itself be undone.
        guard await backup(reason: "Before restoring \(entry.label)") else {
            return RestoreOutcome(text: "Harbor couldn't back up first, so nothing was restored. \(lastSummary ?? "")", ok: false)
        }
        if let pid = entry.profileID, store.profile(pid) == nil,
           let p = snap.manifest.profiles.first(where: { $0.id == pid }) {
            store.adopt(p)
        }
        let r = await Task.detached(priority: .userInitiated) { BackupEngine.restore(entry, from: snap) }.value
        let text = "Restored \(r.copied) file\(r.copied == 1 ? "" : "s"); \(r.skipped) were already there"
            + (r.failed > 0 ? "; \(r.failed) couldn't be copied." : ".")
        return RestoreOutcome(text: text, ok: r.failed == 0)
    }
}
