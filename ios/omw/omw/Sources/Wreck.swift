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
    static let short = "In the Wreck 🐝"
    static let gold = Color(red: 0.70, green: 0.64, blue: 0.41)      // old gold: the car, its route, its pulse
    static let goldDeep = Color(red: 0.55, green: 0.49, blue: 0.29)
    static let goldBright = Color(red: 0.86, green: 0.76, blue: 0.42)  // the route line: old gold reads olive on a dark map  // where the full line won't fit (the feed's pills)
}

extension Color {
    /// the Wreck's gold, for words: a deeper gold on cream by day, old gold on plum by night
    static let wreckGold = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.80, green: 0.73, blue: 0.47, alpha: 1)
                                                                          : UIColor(red: 0.47, green: 0.39, blue: 0.14, alpha: 1) })
}

/// a tiny gold 1930s coupe, drawn (no image files): sized to sit where an SF Symbol would
struct WreckIcon: View {
    var size: CGFloat = 18
    /// picked as the way there: it pops a little wheelie
    var selected = false
    /// grows with the text around it (as an SF Symbol would), unless it sits in a fixed-size button
    var scales = true
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
    private var h: CGFloat { scales ? size * min(textScale, 1.8) : size }
    @State private var hops = 0
    @Environment(\.accessibilityReduceMotion) private var still
    private static let gold = Color(red: 0.70, green: 0.64, blue: 0.41)       // old gold
    private static let goldDeep = Color(red: 0.55, green: 0.49, blue: 0.29)
    private static let glass = Color(red: 0.16, green: 0.19, blue: 0.27)
    private static let tyre = Color(red: 0.11, green: 0.11, blue: 0.14)

    var body: some View {
        Canvas { ctx, box in
            // a 1930s coupe, side on, facing right, drawn on a 32 × 18 grid
            let k = min(box.width / 32, box.height / 18)
            ctx.translateBy(x: (box.width - 32 * k) / 2, y: (box.height - 18 * k) / 2)
            ctx.scaleBy(x: k, y: k)
            // the cab: upright with a rounded roof
            var cab = Path()
            cab.move(to: CGPoint(x: 6.2, y: 9))
            cab.addLine(to: CGPoint(x: 7, y: 3.6))
            cab.addQuadCurve(to: CGPoint(x: 9, y: 2), control: CGPoint(x: 7.3, y: 2))
            cab.addLine(to: CGPoint(x: 16.2, y: 2))
            cab.addQuadCurve(to: CGPoint(x: 17.8, y: 3.4), control: CGPoint(x: 17.6, y: 2))
            cab.addLine(to: CGPoint(x: 18.6, y: 9))
            cab.closeSubpath()
            ctx.fill(cab, with: .color(Self.goldDeep))
            // its side window
            var glass = Path()
            glass.move(to: CGPoint(x: 9.6, y: 7.2))
            glass.addLine(to: CGPoint(x: 9.9, y: 4.6))
            glass.addQuadCurve(to: CGPoint(x: 10.9, y: 3.6), control: CGPoint(x: 10, y: 3.6))
            glass.addLine(to: CGPoint(x: 15.6, y: 3.6))
            glass.addQuadCurve(to: CGPoint(x: 16.4, y: 4.4), control: CGPoint(x: 16.3, y: 3.6))
            glass.addLine(to: CGPoint(x: 16.8, y: 7.2))
            glass.closeSubpath()
            ctx.fill(glass, with: .color(Self.glass))
            // the body: rounded rumble-seat tail, long hood out to the radiator
            var body = Path()
            body.move(to: CGPoint(x: 2.2, y: 12.4))
            body.addLine(to: CGPoint(x: 2.2, y: 10.4))
            body.addQuadCurve(to: CGPoint(x: 6.4, y: 7.4), control: CGPoint(x: 2.4, y: 7.4))
            body.addLine(to: CGPoint(x: 18.6, y: 7.4))
            body.addLine(to: CGPoint(x: 26.8, y: 6.4))
            body.addLine(to: CGPoint(x: 27.4, y: 12.4))
            body.closeSubpath()
            ctx.fill(body, with: .color(Self.gold))
            // the tall radiator shell
            ctx.fill(Path(roundedRect: CGRect(x: 26.4, y: 5, width: 2.4, height: 7.4), cornerRadius: 0.9), with: .color(Self.goldDeep))
            // the white pinstripe down the side
            ctx.fill(Path(CGRect(x: 3.4, y: 9.4, width: 23, height: 0.7)), with: .color(.white.opacity(0.95)))
            // sweeping fenders and the running board between them
            var fenders = Path()
            fenders.move(to: CGPoint(x: 2.6, y: 13.6))
            fenders.addQuadCurve(to: CGPoint(x: 8, y: 9.2), control: CGPoint(x: 3.2, y: 9.2))
            fenders.addQuadCurve(to: CGPoint(x: 12.4, y: 12.6), control: CGPoint(x: 11.8, y: 9.4))
            fenders.addLine(to: CGPoint(x: 20.6, y: 12.6))
            fenders.addQuadCurve(to: CGPoint(x: 25, y: 9.2), control: CGPoint(x: 21.2, y: 9.4))
            fenders.addQuadCurve(to: CGPoint(x: 30.6, y: 13.2), control: CGPoint(x: 30, y: 9.4))
            fenders.addLine(to: CGPoint(x: 30.6, y: 13.9))
            fenders.addLine(to: CGPoint(x: 2.6, y: 13.9))
            fenders.closeSubpath()
            ctx.fill(fenders, with: .color(Self.goldDeep))
            // the headlamp, perched on the fender
            ctx.fill(Path(ellipseIn: CGRect(x: 27.9, y: 7.2, width: 2.6, height: 2.6)), with: .color(Self.goldDeep))
            ctx.fill(Path(ellipseIn: CGRect(x: 28.55, y: 7.85, width: 1.3, height: 1.3)), with: .color(.white))
            // whitewall wheels with gold hubs
            for x in [8.0, 25.0] {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 3.7, y: 10.6, width: 7.4, height: 7.4)), with: .color(Self.tyre))
                ctx.stroke(Path(ellipseIn: CGRect(x: x - 2.35, y: 11.95, width: 4.7, height: 4.7)), with: .color(.white), lineWidth: 0.9)
                ctx.fill(Path(ellipseIn: CGRect(x: x - 1.3, y: 13, width: 2.6, height: 2.6)), with: .color(Self.gold))
            }
        }
        .frame(width: h * 32 / 18, height: h)
        .keyframeAnimator(initialValue: Hop(), trigger: hops) { car, hop in
            // nose up on the back wheel, then settle
            car.rotationEffect(.degrees(hop.tilt), anchor: UnitPoint(x: 0.25, y: 0.95)).offset(y: hop.lift)
        } keyframes: { _ in
            KeyframeTrack(\.tilt) {
                CubicKeyframe(-9, duration: 0.14)
                SpringKeyframe(0, duration: 0.4, spring: .bouncy(extraBounce: 0.2))
            }
            KeyframeTrack(\.lift) {
                CubicKeyframe(-2, duration: 0.14)
                SpringKeyframe(0, duration: 0.4, spring: .bouncy)
            }
        }
        .onChange(of: selected) { _, now in if now, !still { hops += 1 } }
        .sensoryFeedback(.impact(weight: .light), trigger: hops)
        .accessibilityLabel(Wreck.name)
    }
}

private struct Hop { var tilt = 0.0; var lift = 0.0 }

/// how you're getting there, as an icon: the usual symbol, or the Wreck on the way to campus
struct ModeIcon: View {
    let mode: String
    var to: CLLocationCoordinate2D?
    var size: CGFloat = 18
    var selected = false
    var scales = true

    var body: some View {
        if Wreck.on(mode: mode, to: to) {
            WreckIcon(size: size, selected: selected, scales: scales)
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
    func statusLabel(_ p: Person, short: Bool = false) -> String {
        inTheWreck(p) ? (short ? Wreck.short : Wreck.enRoute) : p.status.label
    }

    /// the colour for those words: gold in the Wreck, the status colour otherwise
    func statusColor(_ p: Person) -> Color? {
        inTheWreck(p) ? .wreckGold : p.status.textColor
    }
}
