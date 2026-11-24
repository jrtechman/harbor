import AppKit
import SwiftUI

/// Colors a profile can be tagged with.
enum ProfileColor: String, Codable, CaseIterable, Identifiable {
    case orange, red, pink, purple, blue, teal, green, yellow, gray
    var id: String { rawValue }
    var nsColor: NSColor {
        switch self {
        case .orange: return .systemOrange
        case .red: return .systemRed
        case .pink: return .systemPink
        case .purple: return .systemPurple
        case .blue: return .systemBlue
        case .teal: return .systemTeal
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .gray: return .systemGray
        }
    }
    var color: Color { Color(nsColor: nsColor) }
}

struct Profile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var color: ProfileColor
    /// Folder Claude Desktop uses as its user-data-dir for this profile.
    var dataPath: String
    /// Folder Claude Code uses (CLAUDE_CONFIG_DIR) for this profile.
    var codeConfigPath: String
    var createdAt: Date
    /// Custom shortcut icon (a PNG Harbor keeps in its own folder). nil = Claude's icon.
    var iconPath: String?
    /// Whether the colored letter badge is drawn over the icon. nil = yes.
    var showBadge: Bool?
    /// Whether this profile has its own full copy of Claude (see StandaloneBuilder).
    var standalone: Bool = false

    var dataURL: URL { URL(fileURLWithPath: dataPath, isDirectory: true) }
    var appDisplayName: String { "Claude \(name)" }
}

extension Profile {
    /// Decodes with defaults for fields added later, so an older profiles.json still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decode(ProfileColor.self, forKey: .color)
        dataPath = try c.decode(String.self, forKey: .dataPath)
        codeConfigPath = try c.decode(String.self, forKey: .codeConfigPath)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        iconPath = try c.decodeIfPresent(String.self, forKey: .iconPath)
        showBadge = try c.decodeIfPresent(Bool.self, forKey: .showBadge)
        standalone = try c.decodeIfPresent(Bool.self, forKey: .standalone) ?? false
    }
}

enum Paths {
    static let fm = FileManager.default
    static var home: URL { fm.homeDirectoryForCurrentUser }
    static var support: URL {
        home.appendingPathComponent("Library/Application Support/Harbor", isDirectory: true)
    }
    static var profilesRoot: URL { support.appendingPathComponent("Profiles", isDirectory: true) }
    static var store: URL { support.appendingPathComponent("profiles.json") }
    static var iconsFolder: URL { support.appendingPathComponent("Icons", isDirectory: true) }
    static var shortcutsFolder: URL {
        home.appendingPathComponent("Applications/Harbor Profiles", isDirectory: true)
    }

    static var signingFolder: URL { support.appendingPathComponent("Signing", isDirectory: true) }

    static func safeName(_ s: String) -> String {
        String(s.map { "/:".contains($0) ? "-" : $0 })
    }

    /// Where a profile's app lives. A profile has either a shortcut or a standalone copy here, never both.
    static func standaloneURL(for p: Profile) -> URL {
        shortcutsFolder.appendingPathComponent(safeName(p.appDisplayName) + ".app", isDirectory: true)
    }

    static let claudeBundleID = "com.anthropic.claudefordesktop"
    static let standaloneBundlePrefix = "app.harbor.standalone."

    static func isClaudeBundleID(_ id: String?) -> Bool {
        guard let id else { return false }
        return id == claudeBundleID || id.hasPrefix(standaloneBundlePrefix)
    }

    /// The real Claude Desktop app (not a copy embedded inside another app).
    static var claudeApp: URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Claude.app"),
            home.appendingPathComponent("Applications/Claude.app"),
        ]
        for c in candidates where fm.fileExists(atPath: c.appendingPathComponent("Contents/MacOS/Claude").path) {
            return c
        }
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID),
           !u.path.contains("/Contents/Helpers/") {
            return u
        }
        return nil
    }

    static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
