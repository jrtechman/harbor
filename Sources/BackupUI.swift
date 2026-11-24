import AppKit
import SwiftUI

/// Settings → Backups.
struct BackupSettings: View {
    @EnvironmentObject var store: ProfileStore
    @ObservedObject private var backups = BackupManager.shared
    @AppStorage(Prefs.autoBackupKey) private var auto = true
    @AppStorage(Prefs.backupKeepKey) private var keep = 14
    @AppStorage(Prefs.backupFolderKey) private var folder = ""
    @Local private var showRestore = false

    var body: some View {
        Form {
            Section("Automatic backups") {
                Toggle("Back up once a day while Harbor is open", isOn: $auto)
                Picker("Keep the latest", selection: $keep) {
                    Text("7 backups").tag(7)
                    Text("14 backups").tag(14)
                    Text("30 backups").tag(30)
                    Text("60 backups").tag(60)
                }
                Text("Harbor also backs up first, every time, before it deletes a profile, removes one, imports sessions, or restores files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Where backups go") {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(backups.root.path.replacingOccurrences(of: Paths.home.path, with: "~"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }.controlSize(.small)
                        Button("Show") {
                            try? FileManager.default.createDirectory(at: backups.root, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([backups.root])
                        }.controlSize(.small)
                    }
                }
                if !folder.isEmpty {
                    Button("Use Harbor's own folder again") { folder = "" }.controlSize(.small)
                }
                Text("Backups on the same drive don't protect you if the drive fails. Choose a folder on an external drive, or one your backup tool already copies, for that.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Status") {
                LabeledContent("Last backup") {
                    Text(backups.lastDate.map { Self.when($0) } ?? "Never").foregroundStyle(.secondary)
                }
                LabeledContent("Backups kept") { Text("\(backups.snapshots.count)").foregroundStyle(.secondary) }
                if let s = backups.lastSummary { Text(s).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button(backups.running ? "Backing up…" : "Back up now") {
                        Task { await backups.backup(reason: "Manual backup") }
                    }
                    .disabled(backups.running)
                    Button("Restore…") { showRestore = true }
                        .disabled(backups.snapshots.isEmpty && store.unlistedFolders().isEmpty)
                }
            }
            Section("What's in a backup") {
                Text("Your Code-tab session lists, local agent sessions and Claude Code transcripts, for the regular Claude app and for each profile. Sign-ins, cookies and caches are never copied. Regular chats live on your Claude account and aren't part of this.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { backups.refresh() }
        .onChange(of: folder) { _, _ in backups.refresh() }
        .sheet(isPresented: $showRestore) { RestoreSheet().environmentObject(store) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for Harbor's backups"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.appendingPathComponent("Harbor Backups", isDirectory: true).path
    }

    static func when(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}

/// Pick a backup and put back what's missing.
struct RestoreSheet: View {
    @EnvironmentObject var store: ProfileStore
    @ObservedObject private var backups = BackupManager.shared
    @Environment(\.dismiss) private var dismiss
    @Local private var message: BackupManager.RestoreOutcome?
    @Local private var note: String?
    @Local private var busy = false
    @Local private var unlisted: [UUID] = []

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Restore from a backup").font(.headline)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let m = message {
                        Text(m.text).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background((m.ok ? Color.green : Color.red).opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let n = note {
                        Text(n).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !unlisted.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Data folders with no profile").font(.subheadline.bold())
                            Text("These folders are in Harbor's data folder, but no profile in your list points to them. Re-adding one shows it as a profile again.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(unlisted, id: \.self) { id in
                                HStack {
                                    Text("Folder \(id.uuidString.prefix(8))").font(.system(.body, design: .monospaced))
                                    Spacer()
                                    Button("Re-add as a profile") {
                                        store.recover(folder: id)
                                        unlisted = store.unlistedFolders()
                                        message = nil
                                        note = "Re-added as \"Recovered \(id.uuidString.prefix(8))\". Rename it from its profile page."
                                    }
                                }
                            }
                        }
                    }
                    if backups.snapshots.isEmpty {
                        Text("There are no backups yet. Use \"Back up now\" in Settings → Backups.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(backups.snapshots) { snap in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(snap.manifest.entries.filter { $0.files > 0 }) { entry in
                                    entryRow(entry, snap)
                                }
                                if snap.manifest.entries.allSatisfy({ $0.files == 0 }) {
                                    Text("Nothing was found to back up in this snapshot.").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.dateFormat.string(from: snap.manifest.date)).font(.system(size: 13, weight: .semibold))
                                Text(snap.manifest.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            Text("Restoring only adds files that are missing. It never overwrites or deletes anything, and it takes a fresh backup first.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 480, height: 560)
        .onAppear { backups.refresh(); unlisted = store.unlistedFolders() }
    }

    private func entryRow(_ entry: BackupEntry, _ snap: BackupSnapshot) -> some View {
        let missingProfile = entry.profileID.map { id in
            store.profile(id) == nil && snap.manifest.profiles.contains { $0.id == id }
        } ?? false
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.label)
                Text("\(entry.files) file\(entry.files == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(missingProfile ? "Bring back" : "Restore") {
                Task {
                    busy = true
                    note = nil
                    message = await backups.restore(entry, from: snap)
                    unlisted = store.unlistedFolders()
                    busy = false
                }
            }
            .disabled(busy)
        }
    }
}
