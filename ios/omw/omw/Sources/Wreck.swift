// Wreck mode: driving to a spot on Georgia Tech's campus, your car is the Ramblin' Wreck. The car icon becomes a tiny
// gold roadster and "On the way" becomes "Ramblin' Wreck en route 🐝" (the planner, directions, the plan, the feed).
import SwiftUI
import CoreLocation
#if canImport(LocationEssentials)
import LocationEssentials  // where iOS 26 keeps coordinates and distances
#endif

enum Wreck {
    /// Georgia Tech's main campus, roughly: North Ave up to 14th St, Northside Dr across to Tech Square
    static func onCampus(_ c: CLLocationCoordinate2D?) -> Bool {
        guard let c else { return false }
        return (33.7700...33.7865).contains(c.latitude) && (-84.4075 ... -84.3880).contains(c.longitude)
    }

    /// driving (the default way to get anywhere) to somewhere on campus
    static func on(mode: String?, to c: CLLocationCoordinate2D?) -> Bool {
        (mode ?? "driving") == "driving" && onCampus(c)
    }

    static let enRoute = "Ramblin' Wreck en route 🐝"
    static let name = "Ramblin' Wreck"
}

/// a tiny gold vintage roadster, drawn (no image files): sized to sit where an SF Symbol would
struct WreckIcon: View {
    var size: CGFloat = 18
    private static let gold = Color(red: 0.70, green: 0.64, blue: 0.41)       // old gold
    private static let goldDark = Color(red: 0.52, green: 0.46, blue: 0.27)
    private static let tyre = Color(red: 0.12, green: 0.12, blue: 0.16)

    var body: some View {
        Canvas { ctx, box in
            // drawn on a 26 × 16 grid, scaled to fit
            let k = min(box.width / 26, box.height / 16)
            ctx.translateBy(x: (box.width - 26 * k) / 2, y: (box.height - 16 * k) / 2)
            ctx.scaleBy(x: k, y: k)
            func rr(_ r: CGRect, _ c: CGFloat) -> Path { Path(roundedRect: r, cornerRadius: c) }
            // the open cab and its folded top
            ctx.fill(rr(CGRect(x: 4, y: 3, width: 8, height: 6), 1.5), with: .color(Self.goldDark))
            ctx.fill(rr(CGRect(x: 3, y: 2.2, width: 10, height: 1.6), 0.8), with: .color(Self.tyre))
            // the long hood out front, and the tall radiator
            ctx.fill(rr(CGRect(x: 11, y: 6, width: 11, height: 4), 1.2), with: .color(Self.gold))
            ctx.fill(rr(CGRect(x: 21.5, y: 4.2, width: 2.6, height: 6.6), 0.8), with: .color(Self.goldDark))
            // the body, low and long, with a white pinstripe
            ctx.fill(rr(CGRect(x: 1.5, y: 8, width: 22, height: 4), 1.6), with: .color(Self.gold))
            ctx.fill(Path(CGRect(x: 3, y: 9.4, width: 18, height: 0.7)), with: .color(.white.opacity(0.9)))
            // the headlamp
            ctx.fill(Path(ellipseIn: CGRect(x: 23.4, y: 6.4, width: 2.2, height: 2.2)), with: .color(.white))
            // big spoked wheels
            for x in [6.0, 18.5] {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 3.4, y: 9.4, width: 6.8, height: 6.8)), with: .color(Self.tyre))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: 11.2, width: 3.2, height: 3.2)), with: .color(Self.gold))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 0.6, y: 12.2, width: 1.2, height: 1.2)), with: .color(Self.tyre))
            }
        }
        .frame(width: size * 26 / 16, height: size)
        .accessibilityLabel(Wreck.name)
    }
}

/// how you're getting there, as an icon: the usual symbol, or the Wreck on the way to campus
struct ModeIcon: View {
    let mode: String
    var to: CLLocationCoordinate2D?
    var size: CGFloat = 18

    var body: some View {
        if Wreck.on(mode: mode, to: to) {
            WreckIcon(size: size)
        } else {
            Image(systemName: Travel.symbol(mode))
        }
    }
}

extension Session {
    /// a friend on the way, driving, to a plan of yours on campus
    func inTheWreck(_ p: Person) -> Bool {
        guard p.status == .onTheWay else { return false }
        return hangouts.contains { h in
            !h.isOver && h.attendees.contains(p.id) && abs(h.start.timeIntervalSinceNow) < 3 * 3600
                && Wreck.on(mode: h.modes[p.id], to: h.venue)
        }
    }

    /// what a friend is up to, in words ("On the way", or the Wreck)
    func statusLabel(_ p: Person) -> String {
        inTheWreck(p) ? Wreck.enRoute : p.status.label
    }
}
