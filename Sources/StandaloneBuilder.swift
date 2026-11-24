import AppKit

/// Builds `Claude <Name>.app`: a full copy of Claude Desktop with its own bundle ID, name and icon,
/// whose main executable is a small launcher that always passes this profile's --user-data-dir.
/// /Applications/Claude.app is only ever read.
enum StandaloneBuilder {
    static let launcherName = "HarborLauncher"
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    struct Input: Sendable {
        let profile: Profile
        let claude: URL
        let sourceVersion: String
        let icns: URL
        let destination: URL
        let progress: @Sendable (String) -> Void
    }

    struct Result: Sendable {
        var notices: [String] = []
    }

    // MARK: Claude.app inspection

    /// Claude's version, or nil if Claude.app looks half-updated (no executable, unreadable plist).
    static func sourceVersion(of claude: URL) -> String? {
        guard FileManager.default.fileExists(atPath: claude.appendingPathComponent("Contents/MacOS/Claude").path),
              let plist = readPlist(claude.appendingPathComponent("Contents/Info.plist")),
              let v = plist["CFBundleShortVersionString"] as? String, !v.isEmpty else { return nil }
        return v
    }

    static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }
        return obj as? [String: Any]
    }

    /// True when the copy is missing, was made from another Claude version, lost its launcher
    /// (Claude's updater may overwrite it), or doesn't match the profile's current name.
    static func isStale(_ p: Profile, claudeVersion: String) -> Bool {
        let app = Paths.standaloneURL(for: p)
        let fm = FileManager.default
        guard fm.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/\(launcherName)").path),
              let plist = readPlist(app.appendingPathComponent("Contents/Info.plist")) else { return true }
        return plist["HarborSourceVersion"] as? String != claudeVersion
            || plist["HarborProfileID"] as? String != p.id.uuidString
            || plist["CFBundleExecutable"] as? String != launcherName
            || plist["CFBundleDisplayName"] as? String != p.appDisplayName
    }

    // MARK: Build

    /// Blocking: run it off the main thread. Builds beside the final app and swaps it in at the end,
    /// so a failed build never leaves a half-made app behind.
    static func build(_ i: Input) throws -> Result {
        let fm = FileManager.default
        var result = Result()
        try fm.createDirectory(at: Paths.shortcutsFolder, withIntermediateDirectories: true)
        let tmp = Paths.shortcutsFolder.appendingPathComponent(".building-\(UUID().uuidString).app", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        // 1. Copy (a clone on APFS, so it takes almost no extra space).
        i.progress("Copying Claude…")
        try fm.copyItem(at: i.claude, to: tmp)

        // 2. Launcher: the bundle's main executable, so a direct launch can't fall back to the main account.
        let contents = tmp.appendingPathComponent("Contents")
        let launcher = contents.appendingPathComponent("MacOS/\(launcherName)")
        let script = """
        #!/bin/sh
        # Made by Harbor. Starts Claude with this profile's data folder.
        DIR="$(cd "$(dirname "$0")" && pwd)"
        exec "$DIR/Claude" \(shellQuote("--user-data-dir=" + i.profile.dataPath)) "$@"

        """
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        // 3. Top-level Info.plist only (never the helper apps in Contents/Frameworks).
        let plistURL = contents.appendingPathComponent("Info.plist")
        guard var plist = readPlist(plistURL) else {
            throw SigningError(message: "Couldn't read Claude's Info.plist.")
        }
        plist["CFBundleExecutable"] = launcherName
        plist["CFBundleIdentifier"] = Paths.standaloneBundlePrefix + i.profile.id.uuidString.lowercased()
        // Electron finds "<CFBundleName> Helper.app", so CFBundleName must stay "Claude".
        plist["CFBundleDisplayName"] = i.profile.appDisplayName
        plist["CFBundleIconFile"] = "ProfileIcon"
        plist.removeValue(forKey: "CFBundleIconName")
        plist.removeValue(forKey: "CFBundleURLTypes")   // Harbor routes claude:// links
        plist["HarborSourceVersion"] = i.sourceVersion
        plist["HarborProfileID"] = i.profile.id.uuidString
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        // 4. Icon
        let icon = contents.appendingPathComponent("Resources/ProfileIcon.icns")
        try? fm.removeItem(at: icon)
        try fm.copyItem(at: i.icns, to: icon)

        // 5. Clear quarantine
        Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", tmp.path])

        // 6. Sign and verify
        i.progress("Signing…")
        result.notices += try sign(tmp)
        let verify = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", tmp.path])
        guard verify.ok else { throw SigningError(message: "The new app didn't pass signature checks. \(verify.err)") }

        // Swap in atomically.
        i.progress("Finishing…")
        if fm.fileExists(atPath: i.destination.path) {
            _ = try fm.replaceItemAt(i.destination, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: i.destination)
        }
        Shell.run(lsregister, ["-f", i.destination.path])
        return result
    }

    /// Entitlements only Apple can grant to a team's apps. A locally signed app that claims them is killed at launch.
    static let restrictedEntitlements = ["com.apple.application-identifier", "com.apple.developer.team-identifier",
                                         "keychain-access-groups", "com.apple.developer.associated-domains"]

    /// Writes Claude's entitlements, minus the Apple-team-only ones, to a temp file. Nil if there are none.
    private static func filteredEntitlements(of binary: URL) -> URL? {
        filteredEntitlements(of: binary, adding: [:])
    }

    /// Same, plus `adding`. A local signature has no team ID, so macOS's library validation would refuse to let
    /// Claude load its own frameworks unless it's switched off.
    private static func filteredEntitlements(of binary: URL, adding extra: [String: Any]) -> URL? {
        let r = Shell.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", binary.path])
        guard r.ok, let data = r.out.data(using: .utf8),
              var ents = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return nil }
        for k in restrictedEntitlements { ents.removeValue(forKey: k) }
        for (k, v) in extra { ents[k] = v }
        guard let out = try? PropertyListSerialization.data(fromPropertyList: ents, format: .xml, options: 0) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-ents-\(UUID().uuidString).plist")
        return (try? out.write(to: url)) != nil ? url : nil
    }

    /// Signs with Harbor's local identity; falls back to ad-hoc. Returns notices to show the user.
    private static func sign(_ app: URL) throws -> [String] {
        var notices: [String] = []
        let flags = ["--force", "--deep", "--preserve-metadata=entitlements,flags,runtime"]
        // Claude's main binary first, with the restricted entitlements removed. The --deep pass below
        // then preserves what is left.
        let main = app.appendingPathComponent("Contents/MacOS/Claude")
        let noLV: [String: Any] = ["com.apple.security.cs.disable-library-validation": true]
        var temps: [URL] = []
        defer { temps.forEach { try? FileManager.default.removeItem(at: $0) } }
        func args(for binary: URL) -> [String] {
            guard let e = filteredEntitlements(of: binary, adding: noLV) else { return ["--force", "--preserve-metadata=flags,runtime"] }
            temps.append(e)
            return ["--force", "--preserve-metadata=flags,runtime", "--entitlements", e.path]
        }
        let mainArgs = args(for: main)
        // Helper apps load Electron Framework too, so they need the same treatment.
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        let helpers = ((try? FileManager.default.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
        let helperArgs: [(URL, [String])] = helpers.map { h in
            let exe = h.appendingPathComponent("Contents/MacOS/" + h.deletingPathExtension().lastPathComponent)
            return (h, args(for: exe))
        }
        do {
            let ready = try SigningIdentity.ensure()
            if ready.recreated {
                notices.append("Harbor made a new signing certificate. macOS may ask once more to let each standalone app use \"Claude Safe Storage\": choose Always Allow.")
            }
            guard SigningIdentity.unlock(ready) else { throw SigningError(message: "Couldn't unlock the signing keychain.") }
            let kc = ["--keychain", ready.keychain, "--sign", SigningIdentity.name]
            for (h, a) in helperArgs {
                let r = Shell.run("/usr/bin/codesign", a + kc + [h.path])
                guard r.ok else { throw SigningError(message: r.err) }
            }
            let m = Shell.run("/usr/bin/codesign", mainArgs + kc + [main.path])
            guard m.ok else { throw SigningError(message: m.err) }
            let r = Shell.run("/usr/bin/codesign", flags + kc + [app.path])
            guard r.ok else { throw SigningError(message: r.err) }
            return notices
        } catch {
            NSLog("local signing failed, signing ad-hoc instead")
            var m = Shell.run("/usr/bin/codesign", mainArgs + ["--sign", "-", main.path])
            for (h, a) in helperArgs where m.ok { m = Shell.run("/usr/bin/codesign", a + ["--sign", "-", h.path]) }
            let r = m.ok ? Shell.run("/usr/bin/codesign", flags + ["--sign", "-", app.path]) : m
            guard r.ok else { throw SigningError(message: "Couldn't sign the app. \(r.err)") }
            return ["Harbor couldn't use its signing certificate, so macOS may ask for keychain access again after the next update."]
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
