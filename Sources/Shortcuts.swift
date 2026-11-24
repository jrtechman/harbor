import AppKit

/// Builds a small "Claude <Name>.app" per profile in ~/Applications/Harbor Profiles,
/// with a color-badged icon, so a profile can be opened from Spotlight, Launchpad or the Dock.
@MainActor
enum ShortcutBuilder {
    static func url(for p: Profile) -> URL {
        Paths.standaloneURL(for: p)
    }

    static func exists(for p: Profile) -> Bool {
        FileManager.default.fileExists(atPath: url(for: p).path)
    }

    static func safeName(_ s: String) -> String {
        String(s.map { "/:".contains($0) ? "-" : $0 })
    }

    static func removeShortcut(for p: Profile) {
        let u = url(for: p)
        if FileManager.default.fileExists(atPath: u.path) { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
    }

    @discardableResult
    static func build(for p: Profile, replacingNameOf old: Profile? = nil) throws -> URL {
        guard let claude = Paths.claudeApp else {
            throw NSError(domain: "Harbor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Claude Desktop isn't installed in /Applications."])
        }
        let fm = FileManager.default
        if let old, old.name != p.name { removeShortcut(for: old) }
        let app = url(for: p)
        if fm.fileExists(atPath: app.path) { try fm.removeItem(at: app) }
        let contents = app.appendingPathComponent("Contents")
        let macos = contents.appendingPathComponent("MacOS")
        let res = contents.appendingPathComponent("Resources")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: res, withIntermediateDirectories: true)

        let q = Launcher.shellQuote
        let script = """
        #!/bin/sh
        # Opens Claude Desktop with the "\(p.name.replacingOccurrences(of: "\n", with: " "))" profile (made by Harbor).
        # Harbor brings an already-open profile forward instead of starting a second copy.
        /usr/bin/open -g "harbor://open/\(p.id.uuidString)" 2>/dev/null && exit 0
        # Fallback if Harbor isn't installed: start Claude only if this profile isn't running.
        DATA=\(q(p.dataPath))
        /usr/bin/pgrep -qf -- "--user-data-dir=$DATA" && exit 0
        mkdir -p "$DATA"
        exec /usr/bin/open -n -a \(q(claude.path)) --args "--user-data-dir=$DATA"

        """
        let exe = macos.appendingPathComponent("launch")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let info: [String: Any] = [
            "CFBundleExecutable": "launch",
            "CFBundleIdentifier": "app.harbor.shortcut.\(p.id.uuidString.lowercased())",
            "CFBundleName": p.appDisplayName,
            "CFBundleDisplayName": p.appDisplayName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleIconFile": "ProfileIcon",
            "LSMinimumSystemVersion": "14.0",
            "LSUIElement": true,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))

        try writeIcon(for: p, claude: claude, to: res.appendingPathComponent("ProfileIcon.icns"))
        adHocSign(app)
        NSWorkspace.shared.noteFileSystemChanged(app.path)
        return app
    }

    // MARK: Icon

    static func badgedIcon(for p: Profile, claude: URL?, size: CGFloat) -> NSImage {
        let custom = p.iconPath.flatMap { NSImage(contentsOfFile: $0) }
        let base = custom
            ?? claude.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)!
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        base.draw(in: fitRect(base.size, in: NSRect(x: 0, y: 0, width: size, height: size)),
                  from: .zero, operation: .sourceOver, fraction: 1)
        if p.showBadge == false { img.unlockFocus(); return img }
        let d = size * 0.44
        let badge = NSRect(x: size - d - size * 0.04, y: size * 0.04, width: d, height: d)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: badge.insetBy(dx: -size * 0.018, dy: -size * 0.018)).fill()
        p.color.nsColor.setFill()
        NSBezierPath(ovalIn: badge).fill()
        let letter = String(p.name.first.map { String($0).uppercased() } ?? "?")
        let font = NSFont.systemFont(ofSize: d * 0.58, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let s = letter as NSString
        let ts = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: badge.midX - ts.width / 2, y: badge.midY - ts.height / 2), withAttributes: attrs)
        img.unlockFocus()
        return img
    }

    /// The largest rect with `size`'s aspect ratio that fits centered inside `box`.
    static func fitRect(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    /// Reads any image file (PNG, JPEG, HEIC, .icns…) and returns a 1024×1024 transparent PNG
    /// with the image fitted inside, so non-square pictures aren't stretched.
    static func normalizedIconPNG(from url: URL) -> Data? {
        guard let img = NSImage(contentsOf: url), img.size.width > 0, img.size.height > 0 else { return nil }
        let side: CGFloat = 1024
        let canvas = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            img.draw(in: fitRect(img.size, in: rect), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        return renderBitmap(canvas, pixels: Int(side))?.representation(using: .png, properties: [:])
    }

    static func writeIcon(for p: Profile, claude: URL, to dest: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("pd-\(UUID().uuidString).iconset", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                           (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                           (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
            let image = badgedIcon(for: p, claude: claude, size: CGFloat(px))
            guard let rep = renderBitmap(image, pixels: px),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: tmp.appendingPathComponent("icon_\(name).png"))
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        task.arguments = ["-c", "icns", tmp.path, "-o", dest.path]
        try task.run()
        task.waitUntilExit()
    }

    static func renderBitmap(_ image: NSImage, pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func adHocSign(_ app: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["--force", "--sign", "-", app.path]
        try? task.run()
        task.waitUntilExit()
    }
}
