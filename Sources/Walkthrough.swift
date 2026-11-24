import SwiftUI

extension Notification.Name {
    static let showGuide = Notification.Name("Harbor.showGuide")
}

/// The quick "get started" guide. Shown once on first launch, and again from Settings → Help.
struct WalkthroughSheet: View {
    let theme: HarborTheme
    var onClose: () -> Void
    @Local private var index = 0

    @AppStorage(Prefs.appearanceKey) private var appearance = 0

    private struct Step {
        let symbol: String
        let title: String
        let text: String
        var points: [String] = []
        var isAppearanceStep: Bool = false
    }

    private let steps: [Step] = [
        Step(symbol: "sailboat.fill",
             title: "Welcome aboard",
             text: "Harbor lets you use several Claude accounts at the same time. Each profile is its own Claude window, with its own sign-in and its own chat history. In Harbor, every profile is a boat."),
        Step(symbol: "circle.lefthalf.filled",
             title: "Pick a look",
             text: "Harbor shows daylight in light mode and a night harbor in dark mode. Choose one to keep it, or follow your Mac.",
             isAppearanceStep: true),
        Step(symbol: "plus.circle.fill",
             title: "Add your first profile",
             text: "Press “+ New profile”, name it after the account, like Work or Personal, and pick a color.",
             points: ["Make one profile per Claude account.",
                      "The first time it opens, you sign in to that account in its window.",
                      "Your regular Claude app stays exactly as it is."]),
        Step(symbol: "rectangle.on.rectangle",
             title: "Open and switch",
             text: "Click a boat to select it, and double-click to open it. Open as many as you like at once.",
             points: ["The ship's log below the map shows the selected profile.",
                      "Switch between Map and List, or search, from the top bar.",
                      "More than six profiles? Use the pager on the map."]),
        Step(symbol: "dock.rectangle",
             title: "Give a profile its own Dock icon",
             text: "Turn on “Standalone app” in a profile's log to give it its own name and icon in the Dock and in ⌘-Tab.",
             points: ["Harbor makes a full copy of Claude for that profile, and keeps it up to date.",
                      "The first time it opens, macOS asks to use “Claude Safe Storage”. Choose Always Allow."]),
        Step(symbol: "externaldrive.fill.badge.timemachine",
             title: "Your history is backed up",
             text: "Harbor saves your Claude Code sessions and transcripts once a day, and before anything risky, like deleting a profile.",
             points: ["Choose where backups go, and restore them, in Settings → Backups.",
                      "Settings (⌘,) also has the look (day or night) and link routing.",
                      "You can open this guide again from Settings → Help."]),
    ]

    var body: some View {
        let t = theme
        let s = steps[index]
        let last = index == steps.count - 1
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [t.waterTop, t.waterBottom], startPoint: .top, endPoint: .bottom)
                Circle().fill(.white.opacity(t.night ? 0.12 : 0.28)).frame(width: 150, height: 150)
                Image(systemName: s.symbol)
                    .font(.system(size: 62, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                    .accessibilityHidden(true)
            }
            .frame(height: 170)

            VStack(alignment: .leading, spacing: 10) {
                Text("Step \(index + 1) of \(steps.count)")
                    .font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(t.secondary)
                Text(s.title).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(t.text)
                Text(s.text).font(.system(size: 14)).foregroundStyle(t.text)
                    .fixedSize(horizontal: false, vertical: true)
                if s.isAppearanceStep {
                    Picker("Look", selection: Binding(
                        get: { appearance },
                        set: { appearance = $0; AppPolicy.apply() })) {
                        Text("Follow Mac").tag(0)
                        Text("Day").tag(1)
                        Text("Night").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 6)
                    Text("Change this later in Settings → Appearance.")
                        .font(.system(size: 12)).foregroundStyle(t.secondary)
                        .padding(.top, 2)
                }
                if !s.points.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(s.points, id: \.self) { p in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(t.tint).frame(width: 6, height: 6).offset(y: -1)
                                Text(p).font(.system(size: 13)).foregroundStyle(t.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32).padding(.top, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            HStack {
                if last {
                    Spacer().frame(width: 60)
                } else {
                    Button("Skip") { onClose() }
                        .buttonStyle(.plain).foregroundStyle(t.secondary)
                        .frame(width: 60, alignment: .leading)
                }
                Spacer()
                HStack(spacing: 7) {
                    ForEach(0..<steps.count, id: \.self) { i in
                        Circle().fill(i == index ? t.accent : t.secondary.opacity(0.35)).frame(width: 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
                Spacer()
                HStack(spacing: 8) {
                    if index > 0 {
                        Button("Back") { index -= 1 }
                            .buttonStyle(HarborButtonStyle(kind: .ghost, theme: t))
                    }
                    Button(last ? "Get started" : "Next") {
                        if last { onClose() } else { index += 1 }
                    }
                    .buttonStyle(HarborButtonStyle(kind: .primary, theme: t))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
        }
        .frame(width: 560, height: 540)
        .background(t.panel)
    }
}

/// Shown once, right after the guide: percentages need a limit, and one reading from Claude's usage page sets it.
struct UsageSetupSheet: View {
    let theme: HarborTheme
    var onClose: () -> Void
    @Local private var sessionPct = ""
    @Local private var weekPct = ""
    @Local private var result: String?

    var body: some View {
        let t = theme
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(colors: [t.waterTop, t.waterBottom], startPoint: .top, endPoint: .bottom)
                Circle().fill(.white.opacity(t.night ? 0.12 : 0.28)).frame(width: 110, height: 110)
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 46)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                    .accessibilityHidden(true)
            }
            .frame(height: 130)

            VStack(alignment: .leading, spacing: 12) {
                Text("Show your usage as percentages")
                    .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(t.text)
                Text("Harbor counts your Claude Code work, but only Claude knows your limits. Open Claude's usage page, then type what it shows right now. Harbor works out the rest and keeps the percentages up to date.")
                    .font(.system(size: 13.5)).foregroundStyle(t.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("Session").font(.system(size: 13)).foregroundStyle(t.secondary)
                    TextField("%", text: $sessionPct).textFieldStyle(.roundedBorder).frame(width: 64)
                    Text("Week").font(.system(size: 13)).foregroundStyle(t.secondary).padding(.leading, 8)
                    TextField("%", text: $weekPct).textFieldStyle(.roundedBorder).frame(width: 64)
                }
                .padding(.top, 4)
                if let r = result {
                    Text(r).font(.system(size: 12.5)).foregroundStyle(t.running)
                } else {
                    Text("You can do this later in Settings → Advanced. It only counts Claude Code on this Mac, so it can read a little lower than Claude's own page.")
                        .font(.system(size: 12)).foregroundStyle(t.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 28).padding(.top, 20)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if result == nil {
                    Button("Not now") { onClose() }
                        .buttonStyle(HarborButtonStyle(kind: .ghost, theme: t))
                    Button("Set up") {
                        result = UsageStore.shared.calibrate(sessionPct: sessionPct, weekPct: weekPct)
                    }
                    .buttonStyle(HarborButtonStyle(kind: .primary, theme: t))
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { onClose() }
                        .buttonStyle(HarborButtonStyle(kind: .primary, theme: t))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
        }
        .frame(width: 500, height: 440)
        .background(t.panel)
    }
}
