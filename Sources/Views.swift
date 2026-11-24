import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EmptyState: View {
    @EnvironmentObject var store: ProfileStore
    @Binding var showingNew: Bool
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.circle").font(.system(size: 52)).foregroundStyle(.secondary)
            Text("Use several Claude accounts at the same time").font(.title2)
            Text("Each profile is its own Claude window with its own sign-in and chat history.\nMake one profile per Claude account.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Create a Profile") { showingNew = true }.controlSize(.large).buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

struct ColorPickerRow: View {
    @Binding var color: ProfileColor
    var body: some View {
        HStack(spacing: 8) {
            ForEach(ProfileColor.allCases) { c in
                Circle().fill(c.color).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.primary, lineWidth: c == color ? 2 : 0).padding(-3))
                    .onTapGesture { color = c }
                    .help(c.rawValue.capitalized)
            }
        }
    }
}

struct NewProfileSheet: View {
    @EnvironmentObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    var created: (Profile) -> Void
    @Local private var name = ""
    @Local private var color: ProfileColor = .blue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Profile").font(.title2.bold())
            Text("Name it after the account, like Work or Personal. You'll sign in to that account the first time the profile opens.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Profile name", text: $name).textFieldStyle(.roundedBorder)
            ColorPickerRow(color: $color)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create and Open") {
                    if let p = store.addProfile(name: String(name.prefix(40)), color: color) {
                        created(p)
                        Launcher.open(p)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

struct ProfileDetail: View {
    @EnvironmentObject var store: ProfileStore
    let profile: Profile
    @Local private var name = ""
    @Local private var color: ProfileColor = .blue
    @Local private var confirmDelete = false
    @Local private var shortcutExists = false
    @Local private var importedCount = 0
    @ObservedObject private var usage = UsageStore.shared

    private var running: Bool { store.running[profile.id] != nil }
    private var building: Bool { store.buildSteps[profile.id] != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(nsImage: ShortcutBuilder.badgedIcon(for: profile, claude: Paths.claudeApp, size: 64))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.appDisplayName).font(.title.bold())
                        Text(running ? "Open" : "Not open").foregroundStyle(running ? .green : .secondary)
                    }
                    Spacer()
                    if running {
                        Button("Quit") { Launcher.quit(profile) }
                    }
                    Button(running ? "Show" : "Open") { Launcher.open(profile) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }

                GroupBox("Name and color") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Name", text: $name, onCommit: commitEdits).textFieldStyle(.roundedBorder)
                        ColorPickerRow(color: $color)
                        HStack {
                            Spacer()
                            Button("Save") { commitEdits() }
                                .disabled(name == profile.name && color == profile.color)
                        }
                    }.padding(6)
                }

                GroupBox("Icon") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The icon of this profile's shortcut app (Finder, Spotlight, Launchpad, and the Dock when you pin it). Once a profile's window is open, the Dock shows Claude's own icon.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Choose Icon…") { chooseIcon() }
                            if profile.iconPath != nil {
                                Button("Use Claude's Icon") {
                                    store.resetIcon(for: profile)
                                    refreshShortcut()
                                }
                            }
                            Spacer()
                            Toggle("Color badge", isOn: Binding(
                                get: { profile.showBadge ?? true },
                                set: { store.setBadge($0, for: profile); refreshShortcut() }))
                                .toggleStyle(.switch).controlSize(.small)
                        }
                    }.padding(6)
                }

                GroupBox("Standalone app") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Standalone app (own name and icon in the Dock)", isOn: Binding(
                            get: { profile.standalone },
                            set: { on in
                                let id = profile.id
                                Task { await StandaloneManager.shared.setStandalone(on, profileID: id) }
                            }))
                            .toggleStyle(.switch)
                            .disabled(building)
                        if let step = store.buildSteps[profile.id] {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(step) }
                                .foregroundStyle(.secondary)
                        }
                        if store.staleRunning.contains(profile.id) {
                            HStack {
                                Text("Update available, restart \(profile.appDisplayName)")
                                Spacer()
                                Button("Restart to Update") {
                                    let id = profile.id
                                    Task { await StandaloneManager.shared.restartToUpdate(profileID: id) }
                                }
                            }
                        }
                        Text("Makes a full copy of Claude for this profile. It's rebuilt automatically when Claude updates. The first time it opens, macOS asks to let it use \"Claude Safe Storage\" in your keychain: choose Always Allow.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(6)
                }

                if Prefs.usageEnabled {
                GroupBox("Usage (estimate)") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let s = usage.snapshots[profile.id.uuidString], s.weekTokens > 0 || s.sessionTokens > 0 {
                            if s.sessionResets != nil {
                                HStack {
                                    Text("Session (5 hours)")
                                    Spacer()
                                    Text(s.sessionFraction.map { "\(Int(($0 * 100).rounded()))% used" } ?? "Not set up")
                                        .foregroundStyle(.secondary)
                                }
                                if let f = s.sessionFraction { ProgressView(value: f) }
                                if let r = s.sessionResets {
                                    Text("Resets in \(UsageStore.relative(r))").font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("No active 5-hour session.").foregroundStyle(.secondary)
                            }
                            HStack {
                                Text("This week")
                                Spacer()
                                Text(s.weekFraction.map { "\(Int(($0 * 100).rounded()))% used" } ?? "Not set up").foregroundStyle(.secondary)
                            }
                        } else {
                            Text("No Claude Code activity found for this profile yet.").foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Counted from this profile's Claude Code logs on this Mac. It doesn't include chats in the Claude app or on claude.ai.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Refresh") { usage.refresh() }.disabled(usage.refreshing)
                        }
                    }.padding(6)
                }
                }

                GroupBox("Claude Code sessions") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Copy the Code tab's chat list from your regular Claude app into this profile. Nothing is moved or changed in the regular app, and permissions and connector settings are not copied.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Import…") { importSessions() }
                        }
                        if importedCount > 0 {
                            HStack {
                                Text("Last import added \(importedCount) session\(importedCount == 1 ? "" : "s").")
                                    .font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                Button("Undo Last Import") { undoImport() }
                            }
                        }
                    }.padding(6)
                }

                GroupBox("Shortcuts") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("An app for this profile in ~/Applications/Harbor Profiles, to open it from Spotlight, Launchpad or the Dock.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button(shortcutExists ? "Rebuild App" : "Create App") { buildShortcut() }
                            if shortcutExists {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([ShortcutBuilder.url(for: profile)])
                                }
                            }
                        }
                        Divider()
                        HStack {
                            Text("Runs Claude Code in Terminal with this profile's own sign-in (CLAUDE_CONFIG_DIR).")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Open Claude Code") { Launcher.openClaudeCode(profile) }
                        }
                    }.padding(6)
                }

                GroupBox("Data") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Claude Desktop") {
                            Text(profile.dataPath).textSelection(.enabled).font(.caption.monospaced())
                                .lineLimit(2).truncationMode(.middle)
                        }
                        LabeledContent("Claude Code") {
                            Text(profile.codeConfigPath).textSelection(.enabled).font(.caption.monospaced())
                                .lineLimit(2).truncationMode(.middle)
                        }
                        HStack {
                            Button("Show Data in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([profile.dataURL])
                            }
                            Spacer()
                            Button("Delete Profile…", role: .destructive) { confirmDelete = true }
                                .disabled(running)
                        }
                    }.padding(6)
                }
            }
            .padding(24)
        }
        .onAppear {
            name = profile.name
            color = profile.color
            shortcutExists = ShortcutBuilder.exists(for: profile)
            importedCount = SessionImporter.lastImportCount(profileID: profile.id)
        }
        .onChange(of: store.buildSteps) { _, _ in shortcutExists = ShortcutBuilder.exists(for: profile) }
        .onChange(of: profile.standalone) { _, _ in shortcutExists = ShortcutBuilder.exists(for: profile) }
        .confirmationDialog("Delete \(profile.appDisplayName)?", isPresented: $confirmDelete) {
            Button("Delete Profile and Move Data to Trash", role: .destructive) {
                let p = profile
                Task { if await BackupManager.shared.protect("Before deleting \(p.appDisplayName)") { store.delete(p, trashData: true) } }
            }
            Button("Remove Profile, Keep Data") {
                let p = profile
                Task { if await BackupManager.shared.protect("Before removing \(p.appDisplayName)") { store.delete(p, trashData: false) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Moving the data to the Trash signs this profile out and removes its local chat data.")
        }
    }

    private func importSessions() {
        ProfileActions.importSessions(profile)
        importedCount = SessionImporter.lastImportCount(profileID: profile.id)
    }

    private func undoImport() {
        ProfileActions.undoImport(profile)
        importedCount = SessionImporter.lastImportCount(profileID: profile.id)
    }

    private func commitEdits() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { name = profile.name; return }
        ProfileActions.commitEdits(profile, name: trimmed, color: color)
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.title = "Choose an icon for \(profile.appDisplayName)"
        panel.message = "Pick a square image (PNG, JPEG, HEIC or .icns). A large one looks best."
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.setIcon(for: profile, from: url)
        refreshShortcut()
    }

    /// Rebuilds the profile's shortcut app (if it exists) so it picks up icon changes.
    private func refreshShortcut() {
        guard let p = store.profile(profile.id) else { return }
        if p.standalone {
            Task { await StandaloneManager.shared.rebuild(p) }
            return
        }
        guard shortcutExists else { return }
        _ = try? ShortcutBuilder.build(for: p)
    }

    private func buildShortcut() {
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
            shortcutExists = true
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            store.lastError = "Couldn't create the app: \(error.localizedDescription)"
        }
    }
}
