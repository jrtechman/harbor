import Foundation

/// An estimate of Claude Code usage, counted from the session logs on this Mac.
/// It does not include chats in the Claude app or on claude.ai, and the percentage is only as good as the
/// limit it's measured against (set by you, or the busiest earlier session when left on automatic).
struct UsageSnapshot: Equatable {
    var sessionTokens: Int           // tokens in the current 5-hour block
    var sessionLimit: Int?           // tokens the block is measured against, if known
    var sessionResets: Date?         // end of the current block; nil when no block is active
    var weekTokens: Int              // tokens in the last 7 days
    var updated: Date
    var dayTokens: [Int] = []        // tokens per calendar day, oldest first, last 7 days
    var weekLimit: Int? = nil        // tokens the week is measured against, if known

    var sessionFraction: Double? {
        guard let limit = sessionLimit, limit > 0 else { return nil }
        return min(1, Double(sessionTokens) / Double(limit))
    }
    var weekFraction: Double? {
        guard let limit = weekLimit, limit > 0 else { return nil }
        return min(1, Double(weekTokens) / Double(limit))
    }
    var sessionLeftPercent: Int? { sessionFraction.map { max(0, min(100, Int(((1 - $0) * 100).rounded()))) } }
}

/// Reads Claude Code's own session logs (the same files ccusage and Claude Code Usage Monitor read).
/// Only local files are read; nothing is sent anywhere and no sign-in is touched.
enum LocalUsage {
    struct Entry { let time: Date; let tokens: Int; let key: String }

    static let blockLength: TimeInterval = 5 * 3600

    /// A set of folders to read, optionally limited to (or excluding) particular Claude Code sessions.
    struct Source: Sendable {
        var roots: [URL]
        var include: Set<String>? = nil     // only these session ids
        var exclude: Set<String> = []       // never these session ids
    }

    /// Session ids listed in a Claude data folder's Code-tab index (the `local_*.json` files).
    /// A session's transcript is named after this id, which is how shared transcripts are tied to a profile.
    static func sessionIDs(dataFolder: URL) -> Set<String> {
        let fm = FileManager.default
        var ids = Set<String>()
        let root = dataFolder.appendingPathComponent("claude-code-sessions", isDirectory: true)
        for account in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                for f in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? []
                where f.lastPathComponent.hasPrefix("local_") && f.pathExtension == "json" {
                    guard let obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: f))) as? [String: Any] else { continue }
                    for k in ["cliSessionId", "lastAssistantCliSessionId"] {
                        if let id = obj[k] as? String, !id.isEmpty { ids.insert(id) }
                    }
                }
            }
        }
        return ids
    }

    /// True when the file is a session's transcript (or a subagent log inside that session's folder).
    private static func matches(_ url: URL, _ ids: Set<String>) -> Bool {
        for c in url.pathComponents {
            if ids.contains(c) { return true }
            if c.hasSuffix(".jsonl"), ids.contains(String(c.dropLast(6))) { return true }
        }
        return false
    }

    /// Tokens counted per message: input, output and cache creation. Cache reads are left out,
    /// since they're re-reads of the same context rather than new work.
    static func scan(sources: [Source], since: Date) -> [Entry] {
        let fm = FileManager.default
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var best: [String: Entry] = [:]   // a streamed message is logged many times: keep its largest count

        for source in sources {
        for root in source.roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                if let only = source.include, !matches(url, only) { continue }
                if !source.exclude.isEmpty, matches(url, source.exclude) { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if modified < since { continue }
                guard let data = try? Data(contentsOf: url) else { continue }
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    var start = 0
                    let needle = Array("\"usage\"".utf8)
                    for i in 0...bytes.count {
                        guard i == bytes.count || bytes[i] == 10 else { continue }
                        defer { start = i + 1 }
                        guard i > start else { continue }
                        let line = UnsafeBufferPointer(rebasing: bytes[start..<i])
                        guard contains(line, needle) else { continue }
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                              obj["type"] as? String == "assistant",
                              let msg = obj["message"] as? [String: Any],
                              let usage = msg["usage"] as? [String: Any],
                              (msg["model"] as? String) != "<synthetic>",
                              let ts = obj["timestamp"] as? String,
                              let time = iso.date(from: ts) ?? plain.date(from: ts), time >= since else { continue }
                        func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
                        let tokens = n("input_tokens") + n("output_tokens") + n("cache_creation_input_tokens")
                        let key = "\(msg["id"] as? String ?? "")|\(obj["requestId"] as? String ?? "")|\(msg["id"] == nil ? ts : "")"
                        if let old = best[key], old.tokens >= tokens { continue }
                        best[key] = Entry(time: time, tokens: tokens, key: key)
                    }
                }
            }
        }
        }
        return best.values.sorted { $0.time < $1.time }
    }

    private static func contains(_ hay: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard hay.count >= needle.count else { return false }
        let first = needle[0]
        var i = 0
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < needle.count && hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    /// Groups entries into 5-hour blocks the way ccusage does: a block starts at the hour of its first
    /// message and a new one starts after it ends or after a 5-hour gap.
    static func blocks(_ entries: [Entry]) -> [(start: Date, end: Date, tokens: Int, last: Date)] {
        var out: [(start: Date, end: Date, tokens: Int, last: Date)] = []
        for e in entries {
            if var b = out.last, e.time < b.end, e.time.timeIntervalSince(b.last) < blockLength {
                b.tokens += e.tokens; b.last = e.time
                out[out.count - 1] = b
            } else {
                let hour = Date(timeIntervalSince1970: (e.time.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
                out.append((hour, hour.addingTimeInterval(blockLength), e.tokens, e.time))
            }
        }
        return out
    }

    static func snapshot(sources: [Source], manualLimit: Int, manualWeekLimit: Int = 0, now: Date = Date()) -> UsageSnapshot {
        snapshot(entries: scan(sources: sources, since: now.addingTimeInterval(-30 * 86400)),
                 manualLimit: manualLimit, manualWeekLimit: manualWeekLimit, now: now)
    }

    static func snapshot(entries: [Entry], manualLimit: Int, manualWeekLimit: Int = 0, now: Date = Date()) -> UsageSnapshot {
        let all = blocks(entries)
        let active = all.last.flatMap { now < $0.end && now.timeIntervalSince($0.last) < blockLength ? $0 : nil }
        let earlier = all.filter { b in active.map { b.start != $0.start } ?? true }
        // On automatic, only trust "busiest earlier session" once there's some history to compare with;
        // otherwise show token counts instead of a misleading percentage.
        let autoLimit = earlier.count >= 3 ? earlier.map(\.tokens).max() : nil
        let limit = manualLimit > 0 ? manualLimit : autoLimit.flatMap { $0 > 0 ? $0 : nil }
        let week = entries.filter { $0.time >= now.addingTimeInterval(-7 * 86400) }.reduce(0) { $0 + $1.tokens }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var days = [Int](repeating: 0, count: 7)
        for e in entries {
            let back = cal.dateComponents([.day], from: cal.startOfDay(for: e.time), to: today).day ?? 99
            if back >= 0 && back < 7 { days[6 - back] += e.tokens }
        }
        // The week's limit: yours, or on automatic the busiest earlier 7 days, once there are two weeks of history.
        var perDay = [Int](repeating: 0, count: 30)
        for e in entries {
            let back = cal.dateComponents([.day], from: cal.startOfDay(for: e.time), to: today).day ?? 99
            if back >= 0 && back < 30 { perDay[back] += e.tokens }
        }
        let oldest = perDay.lastIndex(where: { $0 > 0 }) ?? 0
        var autoWeek: Int? = nil
        if oldest >= 13 {
            autoWeek = (7...23).map { end in perDay[end..<(end + 7)].reduce(0, +) }.max()
        }
        let weekLimit = manualWeekLimit > 0 ? manualWeekLimit : autoWeek.flatMap { $0 > 0 ? $0 : nil }
        return UsageSnapshot(sessionTokens: active?.tokens ?? 0, sessionLimit: limit,
                             sessionResets: active?.end, weekTokens: week, updated: now, dayTokens: days,
                             weekLimit: weekLimit)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    static let mainKey = "main"

    /// Keyed by profile id string, or "main" for the regular Claude app.
    @Published private(set) var snapshots: [String: UsageSnapshot] = [:]
    @Published private(set) var refreshing = false
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let home = Paths.home
        let profiles = ProfileStore.shared.profiles
        let manual = Prefs.sessionTokenLimit
        let manualWeek = Prefs.weekTokenLimit
        let mainKey = Self.mainKey
        Task {
            let result = await Task.detached(priority: .utility) { () -> [String: UsageSnapshot] in
                // Claude Code in a profile's Code tab keeps its transcripts in the shared ~/.claude folder.
                // Each profile's Code-tab index lists its sessions, which ties those transcripts to it.
                let shared = [home.appendingPathComponent(".claude/projects", isDirectory: true),
                              home.appendingPathComponent(".config/claude/projects", isDirectory: true)]
                let claimed = profiles.map { LocalUsage.sessionIDs(dataFolder: $0.dataURL) }
                let allClaimed = claimed.reduce(into: Set<String>()) { $0.formUnion($1) }
                var out: [String: UsageSnapshot] = [:]
                // Count each message once, even if a copied or resumed session repeats it in another file.
                let since = Date().addingTimeInterval(-30 * 86400)
                var seen = Set<String>()
                func take(_ sources: [LocalUsage.Source]) -> [LocalUsage.Entry] {
                    let fresh = LocalUsage.scan(sources: sources, since: since).filter { !seen.contains($0.key) }
                    seen.formUnion(fresh.map(\.key))
                    return fresh
                }
                for (p, ids) in zip(profiles, claimed) {
                    let own = URL(fileURLWithPath: p.codeConfigPath).appendingPathComponent("projects", isDirectory: true)
                    let entries = take([LocalUsage.Source(roots: [own]), LocalUsage.Source(roots: shared, include: ids)])
                    out[p.id.uuidString] = LocalUsage.snapshot(entries: entries, manualLimit: manual, manualWeekLimit: manualWeek)
                }
                // The regular app: everything in the shared folder that no profile claims.
                let main = take([LocalUsage.Source(roots: shared, exclude: allClaimed)])
                out[mainKey] = LocalUsage.snapshot(entries: main, manualLimit: manual, manualWeekLimit: manualWeek)
                return out
            }.value
            snapshots = result
            refreshing = false
        }
    }

    func summary(for id: UUID) -> String? { summary(key: id.uuidString) }

    /// "Session 72% · resets 38 min · Week 16%". Only percentages: nothing is shown until there's a limit to measure against.
    func summary(key: String) -> String? {
        guard let s = snapshots[key], s.weekTokens > 0 || s.sessionTokens > 0 else { return nil }
        var parts: [String] = []
        if let f = s.sessionFraction {
            if let r = s.sessionResets {
                parts.append("Session \(Int((f * 100).rounded()))%")
                parts.append("resets \(Self.relative(r))")
            } else {
                parts.append("No active session")
            }
        }
        if let f = s.weekFraction { parts.append("Week \(Int((f * 100).rounded()))%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// True when there is usage to show but no limit yet to turn it into a percentage.
    func needsSetup(key: String) -> Bool {
        guard let s = snapshots[key], s.weekTokens > 0 || s.sessionTokens > 0 else { return false }
        return s.sessionFraction == nil || s.weekFraction == nil
    }

    /// Works out the limits so Harbor's percentages match what Claude's own usage page shows right now.
    /// Returns a message to show the user.
    @discardableResult
    func calibrate(sessionPct: String, weekPct: String, key: String? = nil) -> String {
        // Use the profile being looked at, otherwise whichever has a session running, otherwise the busiest week.
        let withData = snapshots.values.filter { $0.weekTokens > 0 }
        let base = key.flatMap { snapshots[$0] }.flatMap { $0.weekTokens > 0 ? $0 : nil }
            ?? withData.filter { $0.sessionResets != nil }.max(by: { $0.sessionTokens < $1.sessionTokens })
            ?? withData.max(by: { $0.weekTokens < $1.weekTokens })
        guard let s = base else {
            return "There's no Claude Code usage on this Mac yet to set up against."
        }
        func pct(_ text: String) -> Double? {
            guard let p = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")),
                  p >= 1, p <= 100 else { return nil }
            return p
        }
        var notes: [String] = []
        if let p = pct(sessionPct) {
            if s.sessionTokens > 0, s.sessionResets != nil {
                UserDefaults.standard.set(Int((Double(s.sessionTokens) / (p / 100)).rounded()), forKey: Prefs.sessionLimitKey)
                notes.append("Session set up.")
            } else { notes.append("No session is active right now, so the session wasn't set up.") }
        }
        if let p = pct(weekPct) {
            UserDefaults.standard.set(Int((Double(s.weekTokens) / (p / 100)).rounded()), forKey: Prefs.weekLimitKey)
            notes.append("Week set up.")
        }
        refresh()
        return notes.isEmpty ? "Enter a percentage from 1 to 100 for the session, the week, or both." : notes.joined(separator: " ")
    }

    /// "55% left" for the menu bar title, from the profile most recently in front (or the regular app).
    func menuBarTitle(for id: UUID?) -> String? {
        if let id, let p = snapshots[id.uuidString]?.sessionLeftPercent, snapshots[id.uuidString]?.sessionResets != nil {
            return "\(p)% left"
        }
        if let s = snapshots[Self.mainKey], s.sessionResets != nil, let p = s.sessionLeftPercent { return "\(p)% left" }
        return nil
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    static func relative(_ date: Date) -> String {
        let secs = Int(date.timeIntervalSinceNow)
        if secs <= 0 { return "now" }
        if secs < 3600 { return "\(max(1, secs / 60)) min" }
        if secs < 86400 { return "\(secs / 3600)h \((secs % 3600) / 60)m" }
        return "\(secs / 86400)d \((secs % 86400) / 3600)h"
    }
}
