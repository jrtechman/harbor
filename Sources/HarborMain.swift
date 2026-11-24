import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var store: ProfileStore
    @Environment(\.colorScheme) private var scheme
    @Local private var selection: UUID?
    @Local private var showingNew = false
    @Local private var showingMore = false
    @Local private var showingGuide = false
    @Local private var showingUsageSetup = false
    @Local private var linkRouting = Launcher.isLinkRouter
    @Local private var query = ""
    @Local private var listMode = false
    @Local private var page = 0
    @ObservedObject private var backups = BackupManager.shared
    @ObservedObject private var usageStore = UsageStore.shared

    private var filtered: [Profile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.profiles : store.profiles.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
    private var pageCount: Int { max(1, (filtered.count + HarborMap.perPage - 1) / HarborMap.perPage) }
    private var currentPage: Int { min(page, pageCount - 1) }

    var body: some View {
        let t = HarborTheme(scheme)
        ScrollView {
            VStack(spacing: 14) {
                header(t)
                if store.profiles.isEmpty {
                    EmptyState(showingNew: $showingNew).frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    if listMode { listView(t) } else { map(t) }
                    if let p = store.profile(selection) {
                        ProfileLog(theme: t, profile: p, onMore: { showingMore = true }).id(p.id)
                    }
                }
                footer(t)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 18)
        }
        .background(t.window)
        .sheet(isPresented: $showingNew) {
            NewProfileSheet { p in selection = p.id }
        }
        .sheet(isPresented: $showingGuide) {
            WalkthroughSheet(theme: t) {
                Prefs.walkthroughSeen = true
                showingGuide = false
                // Right after the guide, offer to set up usage (if there's anything to set up against).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { maybePromptUsageSetup() }
            }
        }
        .sheet(isPresented: $showingUsageSetup, onDismiss: { Prefs.usageSetupShown = true }) {
            UsageSetupSheet(theme: t) { showingUsageSetup = false }
        }
        .sheet(isPresented: $showingMore) {
            if let p = store.profile(selection) {
                VStack(spacing: 0) {
                    HStack {
                        Text("All settings for \(p.appDisplayName)").font(.headline)
                        Spacer()
                        Button("Done") { showingMore = false }.keyboardShortcut(.defaultAction)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    Divider()
                    ProfileDetail(profile: p).id(p.id)
                }
                .frame(width: 720, height: 640)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { updateBanner }
        .onReceive(NotificationCenter.default.publisher(for: .newProfile)) { _ in showingNew = true }
        .onReceive(NotificationCenter.default.publisher(for: .showGuide)) { _ in showingGuide = true }
        .onChange(of: selection) { _, new in
            if let new, let i = filtered.firstIndex(where: { $0.id == new }) { page = i / HarborMap.perPage }
        }
        .onChange(of: query) { _, _ in page = 0 }
        .onChange(of: usageStore.snapshots) { _, _ in maybePromptUsageSetup() }
        .alert("Heads up",
               isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } }),
               actions: { Button("OK") { store.notice = nil } },
               message: { Text(store.notice ?? "") })
        .alert("Something went wrong",
               isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } }),
               actions: { Button("OK") { store.lastError = nil } },
               message: { Text(store.lastError ?? "") })
        .onAppear {
            if selection == nil { selection = store.profiles.first?.id }
            if !Prefs.walkthroughSeen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showingGuide = true }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { maybePromptUsageSetup() }
            }
            if Paths.claudeApp == nil {
                store.lastError = "Claude Desktop isn't installed in /Applications. Download it from claude.ai/download, then reopen Harbor."
            }
        }
    }

    /// Offers the one-time usage setup once there's Claude Code usage to set it up against.
    /// Never over the guide or another sheet, and never again after it has been shown.
    private func maybePromptUsageSetup() {
        guard Prefs.usageEnabled else { return }
        guard !Prefs.usageSetupShown, Prefs.walkthroughSeen,
              !showingGuide, !showingUsageSetup, !showingNew, !showingMore else { return }
        let keys = [UsageStore.mainKey] + store.profiles.map { $0.id.uuidString }
        guard keys.contains(where: { usageStore.needsSetup(key: $0) }) else { return }
        showingUsageSetup = true
    }

    // MARK: Header

    private func header(_ t: HarborTheme) -> some View {
        HStack(spacing: 12) {
            Canvas { ctx, size in
                // The burst-sail boat, as the small mark beside the name.
                let s = size.width / 200
                var hull = Path()
                hull.move(to: CGPoint(x: 8 * s, y: 32 * s))
                hull.addQuadCurve(to: CGPoint(x: 56 * s, y: 8 * s), control: CGPoint(x: 8 * s, y: 12 * s))
                hull.addLine(to: CGPoint(x: 150 * s, y: 8 * s))
                hull.addQuadCurve(to: CGPoint(x: 198 * s, y: 32 * s), control: CGPoint(x: 190 * s, y: 14 * s))
                hull.addQuadCurve(to: CGPoint(x: 150 * s, y: 56 * s), control: CGPoint(x: 190 * s, y: 50 * s))
                hull.addLine(to: CGPoint(x: 56 * s, y: 56 * s))
                hull.addQuadCurve(to: CGPoint(x: 8 * s, y: 32 * s), control: CGPoint(x: 8 * s, y: 52 * s))
                hull.closeSubpath()
                ctx.fill(hull, with: .color(Color(hex: t.night ? 0x4FA89C : 0x3E8E86)))
                var burst = Path()
                let c = CGPoint(x: 118 * s, y: 32 * s)
                for (dx, dy) in [(45.2, 8.8), (24.9, 21.6), (14.3, 41.6), (-6.1, 31.4), (-30.2, 34.7), (-33.1, 11.4),
                                 (-41.2, -8.0), (-24.2, -21.0), (-15.0, -43.5), (6.3, -32.4), (28.9, -33.2), (34.0, -11.7)] {
                    burst.move(to: c)
                    burst.addLine(to: CGPoint(x: c.x + CGFloat(dx) * 0.55 * s, y: c.y + CGFloat(dy) * 0.55 * s))
                }
                ctx.stroke(burst, with: .color(Color(hex: 0xFFF6EA)), style: StrokeStyle(lineWidth: 5 * s, lineCap: .round))
            }
            .frame(width: 52, height: 17)
            .accessibilityHidden(true)

            Text("Harbor").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(t.text)
            Text("\(store.profiles.count) berth\(store.profiles.count == 1 ? "" : "s") · \(store.running.count) under way")
                .font(.system(size: 13)).foregroundStyle(t.secondary)
            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(t.secondary)
                TextField("Find a profile", text: $query).textFieldStyle(.plain).foregroundStyle(t.text)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(width: 190)
            .background(t.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.fieldStroke))

            HStack(spacing: 3) {
                modeButton("Map", on: !listMode, t) { listMode = false }
                modeButton("List", on: listMode, t) { listMode = true }
            }
            .padding(3)
            .background(t.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.fieldStroke))

            Button("Open All") { Launcher.openAll() }
                .buttonStyle(HarborButtonStyle(kind: .ghost, theme: t))
                .disabled(store.profiles.isEmpty)
                .help("Open every profile")
            Button("+ New profile") { showingNew = true }
                .buttonStyle(HarborButtonStyle(kind: .accent, theme: t))
                .help("Create a profile for another Claude account")
        }
    }

    private func modeButton(_ title: String, on: Bool, _ t: HarborTheme, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(on ? t.primaryText : t.text)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(on ? t.primary : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Map and list

    private func map(_ t: HarborTheme) -> some View {
        let start = currentPage * HarborMap.perPage
        let items = Array(filtered.dropFirst(start).prefix(HarborMap.perPage))
        var slots: [Profile?] = items.map { Optional($0) }
        while slots.count < HarborMap.perPage { slots.append(nil) }
        // The "+ New profile" button in the corner is the only way to add a profile now.
        let showGhost = false
        return HarborMap(theme: t, slots: slots, selected: selection,
                         running: Set(store.running.keys),
                         ghostSlot: showGhost ? items.count : nil,
                         pager: pageCount > 1 ? (currentPage, pageCount, filtered.count) : nil,
                         onSelect: { selection = $0.id },
                         onOpen: { selection = $0.id; Launcher.open($0) },
                         onNew: { showingNew = true },
                         onPage: { page = max(0, min($0, pageCount - 1)) })
    }

    private func listView(_ t: HarborTheme) -> some View {
        List(selection: $selection) {
            ForEach(filtered) { p in
                HStack(spacing: 10) {
                    Circle().fill(p.color.color).frame(width: 12, height: 12)
                    Text(p.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(t.text)
                    Spacer()
                    if let u = UsageStore.shared.summary(for: p.id) {
                        Text(u).font(.system(size: 11.5)).foregroundStyle(t.secondary)
                    }
                    Text(p.standalone ? "Standalone" : "Shortcut").font(.system(size: 12)).foregroundStyle(t.secondary)
                    HStack(spacing: 5) {
                        Circle().fill(store.running[p.id] != nil ? t.lampOn : t.lampOff).frame(width: 7, height: 7)
                        Text(store.running[p.id] != nil ? "Under way" : "In port")
                            .font(.system(size: 12)).foregroundStyle(t.secondary)
                    }
                    .frame(width: 90, alignment: .leading)
                }
                .padding(.vertical, 6)
                .tag(p.id)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded { selection = p.id; Launcher.open(p) })
            }
            .onMove { from, to in if query.isEmpty { store.move(from: from, to: to) } }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(t.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(t.panelStroke))
        .frame(height: HarborMap.mapHeight)
    }

    // MARK: Banner and footer

    @ViewBuilder private var updateBanner: some View {
        let stale = store.profiles.filter { store.staleRunning.contains($0.id) }
        if !stale.isEmpty {
            VStack(spacing: 0) {
                ForEach(stale) { p in
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Update available, restart \(p.appDisplayName)")
                        Spacer()
                        Button("Restart to Update") {
                            Task { await StandaloneManager.shared.restartToUpdate(profileID: p.id) }
                        }
                        .disabled(store.buildSteps[p.id] != nil)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                if stale.count > 1 {
                    HStack {
                        Spacer()
                        Button("Restart All to Update") {
                            Task { await StandaloneManager.shared.restartAllToUpdate() }
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }
                Divider()
            }
            .background(.bar)
        }
    }

    private func footer(_ t: HarborTheme) -> some View {
        HStack(spacing: 14) {
            Toggle(isOn: Binding(get: { linkRouting }, set: { on in
                Launcher.setLinkRouting(on) { ok in linkRouting = ok ? on : Launcher.isLinkRouter }
            })) {
                Text("Send claude:// links to the active profile").font(.system(size: 12.5)).foregroundStyle(t.secondary)
            }
            .toggleStyle(.switch).controlSize(.small).tint(t.tint)
            .help("Use this so browser sign-in, magic links and shared chats open in the profile you were last using, instead of the regular Claude app. Turning it off gives the links back to Claude.")
            Spacer()
            if Prefs.usageEnabled, let u = usageStore.summary(key: UsageStore.mainKey) {
                Text("Regular Claude app: \(u)").font(.system(size: 12)).foregroundStyle(t.secondary).lineLimit(1)
            }
            Text(backups.running ? "Backing up…"
                 : backups.lastDate.map { "Backed up \(BackupSettings.when($0))" } ?? "No backup yet")
                .font(.system(size: 12)).foregroundStyle(t.secondary)
            Button("Open Regular Claude App") { Launcher.openDefaultClaude() }
                .buttonStyle(HarborButtonStyle(kind: .ghost, theme: t))
        }
    }
}

// MARK: - The ship's log: the selected profile

struct ProfileLog: View {
    @EnvironmentObject var store: ProfileStore
    let theme: HarborTheme
    let profile: Profile
    var onMore: () -> Void
    @Local private var name = ""
    @Local private var color: ProfileColor = .blue
    @Local private var shortcutExists = false
    @Local private var sessPct = ""
    @Local private var weekPct = ""
    @Local private var setupNote: String?
    @ObservedObject private var usage = UsageStore.shared

    private var running: Bool { store.running[profile.id] != nil }
    private var building: Bool { store.buildSteps[profile.id] != nil }

    var body: some View {
        let t = theme
        HStack(alignment: .top, spacing: 26) {
            identity(t).frame(width: 230, alignment: .topLeading)
            settings(t).frame(maxWidth: .infinity, alignment: .topLeading)
            if Prefs.usageEnabled {
                usageColumn(t).frame(width: 330, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: 232, alignment: .topLeading)
        .background(t.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(t.panelStroke))
        .onAppear {
            name = profile.name
            color = profile.color
            shortcutExists = ShortcutBuilder.exists(for: profile)
        }
        .onChange(of: profile.name) { _, new in name = new }
        .onChange(of: profile.color) { _, new in color = new }
        .onChange(of: store.buildSteps) { _, _ in shortcutExists = ShortcutBuilder.exists(for: profile) }
        .onChange(of: profile.standalone) { _, _ in shortcutExists = ShortcutBuilder.exists(for: profile) }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { name = profile.name; return }
        ProfileActions.commitEdits(profile, name: trimmed, color: color)
    }

    // MARK: Identity

    private func identity(_ t: HarborTheme) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(profile.appDisplayName).font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(t.text).lineLimit(1)
            Text(running ? "● Under way" : "● In port")
                .font(.system(size: 12.5)).foregroundStyle(running ? t.running : t.secondary)
            TextField("Name", text: $name).textFieldStyle(.plain).foregroundStyle(t.text)
                .onSubmit { commit() }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(t.field, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(t.fieldStroke))
            HStack(spacing: 8) {
                ForEach(ProfileColor.allCases) { c in
                    Circle().fill(c.color).frame(width: 17, height: 17)
                        .overlay(Circle().stroke(t.selection, lineWidth: c == color ? 2 : 0).padding(-3.5))
                        .onTapGesture { color = c; commit() }
                        .help(c.rawValue.capitalized)
                        .accessibilityLabel("Color \(c.rawValue)")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.vertical, 2)
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                Button(running ? "Show window" : "Open") { Launcher.open(profile) }
                    .buttonStyle(HarborButtonStyle(kind: .primary, theme: t))
                if running {
                    Button("Quit") { Launcher.quit(profile) }
                        .buttonStyle(HarborButtonStyle(kind: .ghost, theme: t))
                }
            }
        }
    }

    // MARK: Settings

    private func settings(_ t: HarborTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(t, "Standalone app", subtitle: standaloneSubtitle) {
                HStack(spacing: 8) {
                    if building { ProgressView().controlSize(.small) }
                    Toggle("", isOn: Binding(
                        get: { profile.standalone },
                        set: { on in
                            let id = profile.id
                            Task { await StandaloneManager.shared.setStandalone(on, profileID: id) }
                        }))
                        .labelsHidden().toggleStyle(.switch).tint(t.tint).disabled(building)
                }
            }
            Divider().overlay(t.divider).padding(.vertical, 10)
            row(t, "Code sessions", subtitle: "Bring over the Code tab") {
                Button("Import…") { ProfileActions.importSessions(profile) }
                    .buttonStyle(HarborButtonStyle(kind: .ghost, theme: t))
            }
            Divider().overlay(t.divider).padding(.vertical, 10)
            row(t, "Shortcut app", subtitle: "Open from Spotlight or the Dock") {
                Button(shortcutExists ? "Rebuild" : "Create") {
                    ProfileActions.buildShortcut(profile)
                    shortcutExists = ShortcutBuilder.exists(for: profile)
                }
                .buttonStyle(HarborButtonStyle(kind: .ghost, theme: t))
            }
            Spacer(minLength: 6)
            HStack {
                Spacer()
                Button("All settings…", action: onMore)
                    .buttonStyle(HarborButtonStyle(kind: .ghost, theme: t))
                    .help("Icon, Claude Code in Terminal, data folders and deleting this profile")
            }
        }
    }

    private var standaloneSubtitle: String {
        if let step = store.buildSteps[profile.id] { return step }
        if store.staleRunning.contains(profile.id) { return "Update available: restart to update" }
        return "Own name and Dock icon"
    }

    private func row<Control: View>(_ t: HarborTheme, _ title: String, subtitle: String,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(t.text)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(t.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }
    }

    // MARK: Usage

    private func usageColumn(_ t: HarborTheme) -> some View {
        let s = usage.snapshots[profile.id.uuidString]
        let hasData = (s?.weekTokens ?? 0) > 0 || (s?.sessionTokens ?? 0) > 0
        let needsSetup = hasData && (s?.sessionFraction == nil || s?.weekFraction == nil)
        return HStack(alignment: .top, spacing: 16) {
            TideTube(theme: t, fraction: hasData ? (s?.sessionFraction ?? 0) : 0)
                .frame(width: 44, height: 150)
            VStack(alignment: .leading, spacing: 8) {
                Text("SESSION TIDE (EST.)").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(t.secondary)
                if let s, hasData {
                    Text(bigReadout(s)).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(t.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(s.sessionResets.map { "Resets in \(UsageStore.relative($0))" } ?? "No active 5-hour session")
                        .font(.system(size: 12)).foregroundStyle(t.secondary)
                    HStack {
                        Text("THIS WEEK").font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(t.secondary)
                        Spacer()
                        Text(s.weekFraction.map { "\(Int(($0 * 100).rounded()))% used" } ?? "Not set up")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text)
                    }
                    .padding(.top, 4)
                    DayBars(theme: t, days: s.dayTokens).frame(height: 34)
                    if needsSetup { setupForm(t) }
                } else {
                    Text("No Claude Code activity found for this profile yet. Sessions started in its Code tab show up here.")
                        .font(.system(size: 12.5)).foregroundStyle(t.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text("Estimated from Claude Code on this Mac.")
                        .font(.system(size: 11)).foregroundStyle(t.secondary)
                    Button { usage.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(t.secondary)
                        .disabled(usage.refreshing).help("Refresh usage")
                        .accessibilityLabel("Refresh usage")
                }
            }
        }
    }

    /// Percentages need a limit. This turns what Claude's own usage page shows right now into one.
    private func setupForm(_ t: HarborTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To show percentages, enter what Claude's usage page shows now:")
                .font(.system(size: 11)).foregroundStyle(t.secondary)
            HStack(spacing: 6) {
                Text("Session").font(.system(size: 11)).foregroundStyle(t.secondary)
                TextField("%", text: $sessPct).textFieldStyle(.roundedBorder).frame(width: 46)
                Text("Week").font(.system(size: 11)).foregroundStyle(t.secondary)
                TextField("%", text: $weekPct).textFieldStyle(.roundedBorder).frame(width: 46)
                Button("Set up") { setupNote = UsageStore.shared.calibrate(sessionPct: sessPct, weekPct: weekPct, key: profile.id.uuidString) }
                    .controlSize(.small)
            }
            if let n = setupNote { Text(n).font(.system(size: 11)).foregroundStyle(t.secondary) }
        }
    }

    private func bigReadout(_ s: UsageSnapshot) -> String {
        if s.sessionResets == nil { return "Idle" }
        if let f = s.sessionFraction { return "\(Int((f * 100).rounded()))% used" }
        return "Not set up"
    }
}

/// A glass tube that fills like the tide.
struct TideTube: View {
    let theme: HarborTheme
    let fraction: Double
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 12).fill(theme.gaugeBody)
            GeometryReader { geo in
                Rectangle()
                    .fill(LinearGradient(colors: [theme.gaugeFillTop, theme.gaugeFillBottom], startPoint: .top, endPoint: .bottom))
                    .frame(height: geo.size.height * min(1, max(0, fraction)))
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            RoundedRectangle(cornerRadius: 12).stroke(theme.gaugeStroke.opacity(0.6), lineWidth: 1.5)
        }
        .accessibilityLabel("Session usage \(Int((fraction * 100).rounded())) percent")
    }
}

/// Seven small bars, one per day, today last.
struct DayBars: View {
    let theme: HarborTheme
    let days: [Int]
    var body: some View {
        let peak = max(1, days.max() ?? 1)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<7, id: \.self) { i in
                let v = i < days.count ? days[i] : 0
                RoundedRectangle(cornerRadius: 3)
                    .fill(i == 6 ? theme.barToday : theme.bar)
                    .frame(height: max(3, 34 * CGFloat(v) / CGFloat(peak)))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
