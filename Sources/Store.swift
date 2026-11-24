import AppKit
import Combine

@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published private(set) var profiles: [Profile] = []
    /// Profile id → running Claude process.
    @Published private(set) var running: [UUID: NSRunningApplication] = [:]
    @Published var defaultClaudeRunning = false
    @Published var lastError: String?
    /// One-time information for the user (shown as a dialog).
    @Published var notice: String?
    /// Profile id → what its standalone app build is doing right now.
    @Published var buildSteps: [UUID: String] = [:]
    /// Standalone apps that are open but out of date with Claude.app.
    @Published var staleRunning: Set<UUID> = []
    /// The profile whose Claude window was most recently in front (for link routing).
    @Published private(set) var lastActiveProfile: UUID?

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    private init() {
        load()
        refreshRunning()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshRunning() }
            })
        }
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.noteActivated(app) }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunning() }
        }
    }

    // MARK: Persistence

    private struct File: Codable { var version = 1; var profiles: [Profile]; var lastActive: UUID? }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.store),
              let file = try? JSONDecoder.iso.decode(File.self, from: data) else { return }
        profiles = file.profiles
        lastActiveProfile = file.lastActive
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            let data = try JSONEncoder.iso.encode(File(profiles: profiles, lastActive: lastActiveProfile))
            try data.write(to: Paths.store, options: .atomic)
        } catch {
            lastError = "Couldn't save profiles: \(error.localizedDescription)"
        }
    }

    // MARK: Editing

    @discardableResult
    func addProfile(name: String, color: ProfileColor) -> Profile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = UUID()
        let root = Paths.profilesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let p = Profile(id: id, name: trimmed, color: color,
                        dataPath: root.appendingPathComponent("Data").path,
                        codeConfigPath: root.appendingPathComponent("ClaudeCode").path,
                        createdAt: Date())
        do {
            try FileManager.default.createDirectory(at: p.dataURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            lastError = "Couldn't create the data folder: \(error.localizedDescription)"
            return nil
        }
        profiles.append(p)
        save()
        return p
    }

    /// Adds an existing profile (for example one restored from a backup) to the list.
    func adopt(_ p: Profile) {
        guard !profiles.contains(where: { $0.id == p.id }) else { return }
        profiles.append(p)
        save()
    }

    /// Profile data folders on disk that no profile in the list points to.
    func unlistedFolders() -> [UUID] {
        let listed = Set(profiles.map(\.id))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.profilesRoot.path)) ?? []
        return names.compactMap { UUID(uuidString: $0) }.filter { !listed.contains($0) }
    }

    /// Re-adds an unlisted data folder as a profile named "Recovered …".
    @discardableResult
    func recover(folder id: UUID) -> Profile {
        let root = Paths.profilesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let p = Profile(id: id, name: "Recovered \(id.uuidString.prefix(8))", color: .gray,
                        dataPath: root.appendingPathComponent("Data").path,
                        codeConfigPath: root.appendingPathComponent("ClaudeCode").path,
                        createdAt: Date())
        adopt(p)
        return p
    }

    func update(_ p: Profile) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        profiles[i] = p
        save()
    }

    func move(from: IndexSet, to: Int) {
        profiles.move(fromOffsets: from, toOffset: to)
        save()
    }

    /// Removes a profile. If `trashData`, its data folder goes to the Trash.
    func delete(_ p: Profile, trashData: Bool) {
        if running[p.id] != nil {
            lastError = "Quit \(p.appDisplayName) before deleting it."
            return
        }
        if trashData {
            let root = p.dataURL.deletingLastPathComponent()
            try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
        }
        ShortcutBuilder.removeShortcut(for: p)
        removeIconFile(p)
        profiles.removeAll { $0.id == p.id }
        if lastActiveProfile == p.id { lastActiveProfile = nil }
        save()
    }

    // MARK: Icons

    /// Uses `url` (any image file) as this profile's shortcut icon.
    func setIcon(for p: Profile, from url: URL) {
        guard let data = ShortcutBuilder.normalizedIconPNG(from: url) else {
            lastError = "Couldn't read that image. Choose a PNG, JPEG, HEIC or .icns file."
            return
        }
        do {
            try FileManager.default.createDirectory(at: Paths.iconsFolder, withIntermediateDirectories: true)
            // A new file name each time, so cached copies of the old icon are never reused.
            let dest = Paths.iconsFolder.appendingPathComponent(
                "\(p.id.uuidString)-\(Int(Date().timeIntervalSince1970)).png")
            try data.write(to: dest, options: .atomic)
            removeIconFile(p)
            var q = profile(p.id) ?? p
            q.iconPath = dest.path
            update(q)
        } catch {
            lastError = "Couldn't save the icon: \(error.localizedDescription)"
        }
    }

    func resetIcon(for p: Profile) {
        removeIconFile(p)
        var q = profile(p.id) ?? p
        q.iconPath = nil
        update(q)
    }

    func setBadge(_ on: Bool, for p: Profile) {
        var q = profile(p.id) ?? p
        q.showBadge = on
        update(q)
    }

    private func removeIconFile(_ p: Profile) {
        if let path = (profile(p.id) ?? p).iconPath { try? FileManager.default.removeItem(atPath: path) }
    }

    // MARK: Running state

    func refreshRunning() {
        let procs = ClaudeProcesses.all()
        var map: [UUID: NSRunningApplication] = [:]
        var defaultRunning = false
        for proc in procs {
            guard let path = proc.dataPath else { defaultRunning = true; continue }
            if let p = profiles.first(where: { Paths.normalized($0.dataPath) == path }) {
                map[p.id] = proc.app
            }
        }
        if map.mapValues(\.processIdentifier) != running.mapValues(\.processIdentifier) { running = map }
        if defaultRunning != defaultClaudeRunning { defaultClaudeRunning = defaultRunning }
    }

    private func noteActivated(_ app: NSRunningApplication?) {
        guard let app, Paths.isClaudeBundleID(app.bundleIdentifier) else { return }
        refreshRunning()
        if let id = running.first(where: { $0.value.processIdentifier == app.processIdentifier })?.key,
           id != lastActiveProfile {
            lastActiveProfile = id
            save()
        }
    }

    func profile(_ id: UUID?) -> Profile? { profiles.first { $0.id == id } }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
