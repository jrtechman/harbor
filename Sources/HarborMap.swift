import SwiftUI

/// The harbor: profiles are boats moored along piers, seen from above. Six berths per page.
/// Daylight in light mode; at night the lighthouse beam finds the selected profile and open boats show their lights.
struct HarborMap: View {
    static let perPage = 6
    static let boatW: CGFloat = 132
    static var boatH: CGFloat { boatW * 64 / 200 }
    static let mapHeight: CGFloat = 316

    let theme: HarborTheme
    let slots: [Profile?]           // exactly `perPage` entries for the current page
    let selected: UUID?
    let running: Set<UUID>
    let ghostSlot: Int?             // empty berth that offers "New profile"
    let pager: (page: Int, pages: Int, total: Int)?
    var onSelect: (Profile) -> Void
    var onOpen: (Profile) -> Void
    var onNew: () -> Void
    var onPage: (Int) -> Void

    /// Top-left of a berth's boat. Two boats per pier, along its south side.
    static func origin(_ k: Int) -> CGPoint {
        let pier = k / 2, side = k % 2
        return CGPoint(x: 72 + CGFloat(side) * (boatW + 16), y: 22 + 96 * CGFloat(pier) + 20)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(ctx, size) }
                    .accessibilityHidden(true)

                ForEach(0..<Self.perPage, id: \.self) { k in
                    let o = Self.origin(k)
                    if let p = slots[k] {
                        berth(p)
                            .position(x: o.x + Self.boatW / 2, y: o.y + (Self.boatH + 28) / 2)
                    } else if ghostSlot == k {
                        ghost()
                            .position(x: o.x + Self.boatW / 2, y: o.y + (Self.boatH + 28) / 2)
                    }
                }

                if let pg = pager {
                    HStack(spacing: 10) {
                        Button { onPage(pg.page - 1) } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(.plain).disabled(pg.page == 0).accessibilityLabel("Previous pier")
                        Text("Pier \(pg.page + 1) of \(pg.pages) · \(pg.total) berths")
                            .font(.system(size: 12)).foregroundStyle(theme.text)
                        Button { onPage(pg.page + 1) } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.plain).disabled(pg.page >= pg.pages - 1).accessibilityLabel("Next pier")
                    }
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(theme.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.panelStroke))
                    .position(x: geo.size.width - 150, y: geo.size.height - 22)
                }
            }
        }
        .frame(height: Self.mapHeight)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Berths (hit areas and name plates)

    private func berth(_ p: Profile) -> some View {
        let isSelected = p.id == selected
        let isRunning = running.contains(p.id)
        return VStack(spacing: 4) {
            Color.clear.frame(width: Self.boatW, height: Self.boatH)
            HStack(spacing: 6) {
                Circle().fill(isRunning ? theme.lampOn : theme.lampOff).frame(width: 7, height: 7)
                Text(p.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(theme.text)
            }
            .padding(.horizontal, 10)
            .frame(width: Self.boatW, height: 24)
            .background(theme.plate, in: Capsule())
            .overlay(Capsule().stroke(isSelected ? theme.selection : .clear, lineWidth: 2))
            .shadow(color: .black.opacity(theme.night ? 0.4 : 0.22), radius: 5, y: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(p) }
        .onTapGesture { onSelect(p) }
        .help("Click to select, double-click to open \(p.appDisplayName)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(p.name), \(isRunning ? "open" : "closed")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default) { onSelect(p) }
        .accessibilityAction(named: "Open") { onOpen(p) }
    }

    private func ghost() -> some View {
        Button(action: onNew) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: Self.boatH / 2)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                        .foregroundStyle(.white.opacity(theme.night ? 0.35 : 0.8))
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(theme.night ? 0.6 : 0.95))
                }
                .frame(width: Self.boatW, height: Self.boatH)
                Text("New profile").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(width: Self.boatW, height: 24)
                    .background(theme.plate.opacity(0.85), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create a new profile")
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let night = theme.night
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [theme.waterTop, theme.waterBottom]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))

        // Ripples
        for (fx, y) in [(0.50, 40.0), (0.62, 190.0), (0.55, 270.0), (0.76, 250.0), (0.45, 130.0), (0.86, 180.0)] {
            let x = w * fx
            var p = Path()
            p.move(to: CGPoint(x: x, y: y))
            p.addQuadCurve(to: CGPoint(x: x + 20, y: y), control: CGPoint(x: x + 10, y: y - 8))
            p.addQuadCurve(to: CGPoint(x: x + 40, y: y), control: CGPoint(x: x + 30, y: y + 8))
            ctx.stroke(p, with: .color(.white.opacity(night ? 0.12 : 0.38)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }

        // Shore and boardwalk, with lamps
        ctx.fill(Path(CGRect(x: 0, y: 0, width: 56, height: h)), with: .color(theme.shore))
        ctx.fill(Path(CGRect(x: 40, y: 0, width: 16, height: h)), with: .color(theme.boardwalk))
        for y in stride(from: 20.0, through: h, by: 96) {
            if night {
                ctx.fill(Path(ellipseIn: CGRect(x: 34, y: y - 14, width: 28, height: 28)),
                         with: .color(Color(hex: 0xF2C879, opacity: 0.14)))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: 44.6, y: y - 3.4, width: 6.8, height: 6.8)),
                     with: .color(night ? Color(hex: 0xF2C879) : Color(hex: 0x7A6644)))
        }

        // Lighthouse (seen from above), its beam at night, and a few rocks and buoys
        let lh = CGPoint(x: w - 110, y: 84)
        if night, let sel = selected, let k = slots.firstIndex(where: { $0?.id == sel }) {
            let o = Self.origin(k)
            var beam = Path()
            beam.move(to: lh)
            beam.addLine(to: CGPoint(x: o.x + Self.boatW + 8, y: o.y - 6))
            beam.addLine(to: CGPoint(x: o.x + Self.boatW + 8, y: o.y + Self.boatH + 6))
            beam.closeSubpath()
            ctx.fill(beam, with: .linearGradient(
                Gradient(colors: [Color(hex: 0xF2C879, opacity: 0.62), Color(hex: 0xF2C879, opacity: 0)]),
                startPoint: lh, endPoint: CGPoint(x: o.x + Self.boatW, y: o.y + Self.boatH / 2)))
        }
        for (dx, dy, rx, ry) in [(-148.0, 170.0, 22.0, 12.0), (-38.0, 230.0, 26.0, 14.0), (-228.0, 60.0, 16.0, 9.0)] {
            let r = CGRect(x: w + dx - rx, y: dy - ry, width: rx * 2, height: ry * 2)
            ctx.fill(Path(ellipseIn: r), with: .color(night ? Color(hex: 0x08141E, opacity: 0.7) : Color(hex: 0x8E8A80)))
            ctx.stroke(Path(ellipseIn: r.insetBy(dx: -8, dy: -6)), with: .color(.white.opacity(night ? 0.3 : 0.6)), lineWidth: 2)
        }
        if night {
            ctx.fill(Path(ellipseIn: CGRect(x: lh.x - 64, y: lh.y - 64, width: 128, height: 128)),
                     with: .color(Color(hex: 0xF2C879, opacity: 0.12)))
        } else {
            ctx.fill(Path(ellipseIn: CGRect(x: lh.x - 24, y: lh.y - 16, width: 76, height: 60)),
                     with: .color(Color(hex: 0x1D4B63, opacity: 0.2)))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: lh.x - 30, y: lh.y - 30, width: 60, height: 60)),
                 with: .color(night ? Color(hex: 0xE8F0F3) : Color(hex: 0xFFF6EA)))
        ctx.stroke(Path(ellipseIn: CGRect(x: lh.x - 30, y: lh.y - 30, width: 60, height: 60)),
                   with: .color(Color(hex: 0xD9755A)), lineWidth: 5)
        ctx.fill(Path(ellipseIn: CGRect(x: lh.x - 17, y: lh.y - 17, width: 34, height: 34)), with: .color(Color(hex: 0xD9755A)))
        ctx.fill(Path(ellipseIn: CGRect(x: lh.x - 6, y: lh.y - 6, width: 12, height: 12)),
                 with: .color(night ? Color(hex: 0xF2C879) : Color(hex: 0xFFF1DC)))
        for (bx, by, red) in [(w * 0.60, 110.0, true), (w * 0.68, 246.0, false)] {
            let c = red ? Color(hex: 0xE5645A) : Color(hex: 0x4FD1A1)
            if night { ctx.fill(Path(ellipseIn: CGRect(x: bx - 14, y: by - 14, width: 28, height: 28)), with: .color(c.opacity(0.25))) }
            ctx.fill(Path(ellipseIn: CGRect(x: bx - 8, y: by - 8, width: 16, height: 16)), with: .color(night ? c : (red ? c : Color(hex: 0xFFF6EA))))
            if !night { ctx.stroke(Path(ellipseIn: CGRect(x: bx - 8, y: by - 8, width: 16, height: 16)), with: .color(red ? Color(hex: 0xFFF6EA) : Color(hex: 0xD9755A)), lineWidth: 3) }
        }

        // Piers
        let pierLen: CGFloat = 16 + 2 * Self.boatW + 32 + 16
        for i in 0..<3 {
            let y = 22 + 96 * CGFloat(i)
            ctx.fill(Path(CGRect(x: 56, y: y, width: pierLen, height: 14)), with: .color(theme.pier))
            var planks = Path()
            for x in stride(from: 86.0, to: 56 + pierLen, by: 36) {
                planks.move(to: CGPoint(x: x, y: y)); planks.addLine(to: CGPoint(x: x, y: y + 14))
            }
            ctx.stroke(planks, with: .color(theme.pierLine), lineWidth: 1.5)
            for x in [120.0, 56 + Double(pierLen) - 70] {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: y + 18.5, width: 7, height: 7)), with: .color(theme.post))
            }
        }

        // Boats
        for (k, slot) in slots.enumerated() {
            guard let p = slot else { continue }
            let o = Self.origin(k)
            let isRunning = running.contains(p.id)
            if !night {
                let foam = CGRect(x: o.x - 4, y: o.y - 4, width: Self.boatW + 8, height: Self.boatH + 8)
                ctx.stroke(Path(roundedRect: foam, cornerRadius: foam.height / 2), with: .color(.white.opacity(0.55)), lineWidth: 2.5)
            }
            drawBoat(ctx, o: o, w: Self.boatW, color: p.color.color)
            if night { drawLights(ctx, o: o, lit: isRunning) }
            if p.id == selected {
                let r = CGRect(x: o.x - 8, y: o.y - 6, width: Self.boatW + 16, height: Self.boatH + 12)
                ctx.stroke(Path(roundedRect: r, cornerRadius: r.height / 2), with: .color(theme.selection),
                           style: StrokeStyle(lineWidth: 2.5, dash: [7, 6]))
            }
        }
    }

    private func drawLights(_ ctx: GraphicsContext, o: CGPoint, lit: Bool) {
        let w = Self.boatW, h = Self.boatH
        let pts: [(CGFloat, CGFloat, Color)] = [(0.56, 0.15, Color(hex: 0xE5645A)), (0.56, 0.85, Color(hex: 0x4FD1A1)), (0.05, 0.5, .white)]
        for (fx, fy, c) in pts {
            let p = CGPoint(x: o.x + w * fx, y: o.y + h * fy)
            if lit {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(c.opacity(0.32)))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.6, y: p.y - 3.6, width: 7.2, height: 7.2)), with: .color(c))
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(Color(hex: 0x4A5A66)))
            }
        }
    }

    /// A boat from above: hull, wooden deck, cabin, and the burst as its sail.
    private func drawBoat(_ ctx: GraphicsContext, o: CGPoint, w: CGFloat, color: Color) {
        let s = w / 200
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        var hull = Path()
        hull.move(to: P(8, 32))
        hull.addQuadCurve(to: P(56, 8), control: P(8, 12))
        hull.addLine(to: P(150, 8))
        hull.addQuadCurve(to: P(198, 32), control: P(190, 14))
        hull.addQuadCurve(to: P(150, 56), control: P(190, 50))
        hull.addLine(to: P(56, 56))
        hull.addQuadCurve(to: P(8, 32), control: P(8, 52))
        hull.closeSubpath()
        ctx.fill(hull, with: .color(color))

        var deck = Path()
        deck.move(to: P(20, 32))
        deck.addQuadCurve(to: P(58, 16), control: P(20, 19))
        deck.addLine(to: P(148, 16))
        deck.addQuadCurve(to: P(186, 32), control: P(178, 20))
        deck.addQuadCurve(to: P(148, 48), control: P(178, 44))
        deck.addLine(to: P(58, 48))
        deck.addQuadCurve(to: P(20, 32), control: P(20, 45))
        deck.closeSubpath()
        ctx.fill(deck, with: .color(Color(hex: theme.night ? 0xE9DCC6 : 0xF3E3CB)))
        ctx.fill(Path(roundedRect: CGRect(x: o.x + 44 * s, y: o.y + 22 * s, width: 34 * s, height: 20 * s), cornerRadius: 5 * s),
                 with: .color(Color(hex: theme.night ? 0xB9A98C : 0xC9B79A)))
        let mast = P(118, 32)
        ctx.fill(Path(ellipseIn: CGRect(x: mast.x - 4 * s, y: mast.y - 4 * s, width: 8 * s, height: 8 * s)), with: .color(Color(hex: 0x2F3E57)))

        let rays: [(CGFloat, CGFloat)] = [(45.2, 8.8), (24.9, 21.6), (14.3, 41.6), (-6.1, 31.4), (-30.2, 34.7), (-33.1, 11.4),
                                          (-41.2, -8.0), (-24.2, -21.0), (-15.0, -43.5), (6.3, -32.4), (28.9, -33.2), (34.0, -11.7)]
        var burst = Path()
        for (dx, dy) in rays {
            burst.move(to: mast)
            burst.addLine(to: CGPoint(x: mast.x + dx * 0.5 * s, y: mast.y + dy * 0.5 * s))
        }
        ctx.stroke(burst, with: .color(Color(hex: 0xD9755A)), style: StrokeStyle(lineWidth: 4.5 * s, lineCap: .round))
    }
}
