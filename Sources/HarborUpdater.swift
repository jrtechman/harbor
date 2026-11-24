import AppKit
import Foundation

/// Checks GitHub Releases for newer builds of Harbor itself, and either prompts about them
/// or (if turned on) downloads, installs and relaunches automatically.
@MainActor
final class HarborUpdater {
    static let shared = HarborUpdater()
    private static let repo = "jrtechman/harbor"

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }

    private var timer: Timer?
    private var promptedVersion: String?
    private var failedVersion: String?
    private var working = false

    func start() {
        check(silent: true)
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(silent: true) }
        }
    }

    /// "Check for Harbor Updates…": runs now and says so when already current.
    func checkNow() {
        promptedVersion = nil
        failedVersion = nil
        check(silent: false)
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Dot-separated numeric version compare; a leading "v" (as in GitHub tags) is ignored.
    private func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                .split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func check(silent: Bool) {
        guard !working else { return }
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let release = try JSONDecoder().decode(Release.self, from: data)
                self.handle(release, silent: silent)
            } catch {
                if !silent { self.say("Couldn't check for updates: \(error.localizedDescription)") }
            }
        }
    }

    private func handle(_ release: Release, silent: Bool) {
        guard isNewer(release.tag_name, than: currentVersion) else {
            if !silent { say("Harbor \(currentVersion) is the latest version.") }
            return
        }
        if Prefs.harborAutoUpdate {
            guard failedVersion != release.tag_name else { return }
            Task { @MainActor in await self.install(release) }
        } else {
            guard promptedVersion != release.tag_name else { return }
            promptedVersion = release.tag_name
            promptUpdate(release)
        }
    }

    private func promptUpdate(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Harbor \(release.tag_name) is available"
        alert.informativeText = "You're on \(currentVersion). Turn on automatic updates in Settings to skip this next time."
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: release.html_url) {
            NSWorkspace.shared.open(url)
        }
    }

    private func say(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Automatic install

    private func install(_ release: Release) async {
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else { return }
        working = true
        defer { working = false }
        do {
            let downloadURLString = asset.browser_download_url
            let currentApp = Bundle.main.bundleURL
            try await Task.detached(priority: .utility) {
                try Self.downloadAndInstall(downloadURLString: downloadURLString, currentApp: currentApp)
            }.value
            relaunch()
        } catch {
            failedVersion = release.tag_name
            promptUpdate(release)
        }
    }

    nonisolated private static func downloadAndInstall(downloadURLString: String, currentApp: URL) throws {
        guard let url = URL(string: downloadURLString) else {
            throw SigningError(message: "The release had no usable download link.")
        }
        let zip = try Data(contentsOf: url)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("HarborUpdate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zipFile = work.appendingPathComponent("Harbor.zip")
        try zip.write(to: zipFile)

        let unzip = Shell.run("/usr/bin/ditto", ["-x", "-k", zipFile.path, work.path])
        guard unzip.ok else { throw SigningError(message: "Couldn't unzip the update. \(unzip.err)") }

        let newApp = work.appendingPathComponent("Harbor.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            throw SigningError(message: "The update didn't contain Harbor.app.")
        }
        let verify = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        guard verify.ok else { throw SigningError(message: "The update's signature didn't check out. \(verify.err)") }

        let fm = FileManager.default
        let backup = currentApp.deletingLastPathComponent()
            .appendingPathComponent(".\(currentApp.lastPathComponent).updating-\(UUID().uuidString)")
        try fm.moveItem(at: currentApp, to: backup)
        do {
            try fm.copyItem(at: newApp, to: currentApp)
        } catch {
            try? fm.removeItem(at: currentApp)
            try? fm.moveItem(at: backup, to: currentApp)
            throw error
        }
        try? fm.removeItem(at: backup)
        NSWorkspace.shared.noteFileSystemChanged(currentApp.path)
    }

    /// Opens the freshly-installed app at the same path, then quits this (old) instance.
    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
