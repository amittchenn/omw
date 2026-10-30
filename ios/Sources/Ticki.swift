// Ticki, omw!'s mascot: a little coral alarm clock that's always "down soon". Drawn in code (sharp at any size) and
// always moving a bit, like Grok's or Duolingo's characters. One view, a few moods:
//   .wave     hello (sign in, empty friends)              .run      on the way (loading, time to leave)
//   .cheer    everyone's here / on time                    .sleepy   nothing planned
//   .worried  someone's running late, or something failed  .idle     just hanging out (bobs and blinks)
import SwiftUI

struct Ticki: View {
    enum Mood { case idle, wave, run, cheer, sleepy, worried }
    var mood: Mood = .idle
    /// what Ticki says when you tap it, one line per tap, in turn
    var lines: [String] = []

    @State private var pokedAt: Date?
    @State private var said: String?
    @State private var turn = 0
    @State private var pokes = 0

    private static let coral = Color(red: 0.95, green: 0.41, blue: 0.29)
    private static let coralDark = Color(red: 0.80, green: 0.30, blue: 0.22)
    private static let cream = Color(red: 1.0, green: 0.97, blue: 0.93)
    private static let creamShade = Color(red: 0.93, green: 0.86, blue: 0.80)
    private static let coralLight = Color(red: 1.0, green: 0.60, blue: 0.47)
    private static let ink = Color(red: 0.12, green: 0.12, blue: 0.16)
    private static let blush = Color(red: 1.0, green: 0.60, blue: 0.56)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let b = boing(timeline.date)
            Canvas { ctx, size in
                let k = min(size.width, size.height) / 200
                ctx.scaleBy(x: k, y: k)
                draw(&ctx, t, boing: b)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Circle())
        // tap Ticki and it boings, spins, and says something (and doesn't open whatever it's sitting on)
        .highPriorityGesture(TapGesture().onEnded { poke() })
        .sensoryFeedback(.impact(weight: .light, intensity: 0.8), trigger: pokes)
        .overlay(alignment: .top) {
            if let said {
                Text(said)
                    .font(.footnote.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .alignmentGuide(.top) { $0[.bottom] + 2 }
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                    .id(said)
            }
        }
        .accessibilityLabel("Ticki")
        .accessibilityAddTraits(.isButton)
    }

    private func poke() {
        pokedAt = .now
        pokes += 1
        guard !lines.isEmpty else { return }
        let line = lines[turn % lines.count]
        turn += 1
        withAnimation(.spring(duration: 0.35, bounce: 0.4)) { said = line }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if said == line { withAnimation(.easeOut(duration: 0.2)) { said = nil } }
        }
    }

    /// 0…1 through the boing after a tap (nil: not boinging)
    private func boing(_ t: Date) -> Double? {
        guard let at = pokedAt else { return nil }
        let x = t.timeIntervalSince(at) / 0.75
        return x < 1 ? x : nil
    }

    // ---------- motion ----------
    // Everything is a few slow, eased loops instead of constant jiggle: breathing with a little squash and stretch,
    // jumps with anticipation and a landing squash, waves in bursts with rests between, natural (sometimes double) blinks.

    private static func ease(_ x: Double) -> Double { let x = min(max(x, 0), 1); return x * x * (3 - 2 * x) }
    /// 0…1 through a loop of `period` seconds
    private static func phase(_ t: Double, _ period: Double) -> Double { (t / period).truncatingRemainder(dividingBy: 1) }

    private struct Pose {
        var lift = 0.0                 // up off the ground
        var sx = 1.0, sy = 1.0         // squash and stretch, from the feet
        var tilt = 0.0                 // degrees
        var leftArm = 30.0, rightArm = -30.0
        var leftLeg = 0.0, rightLeg = 0.0
        var look = 0.0                 // eyes left/right
    }

    private func pose(_ t: Double) -> Pose {
        var p = Pose()
        let breathe = sin(t * 2 * .pi / 3.2)
        switch mood {
        case .idle:
            p.sy = 1 + 0.022 * breathe; p.sx = 1 - 0.016 * breathe
            p.leftArm = 28 + 3 * breathe; p.rightArm = -28 - 3 * breathe
            p.look = lookAround(t)
        case .wave:
            p.sy = 1 + 0.02 * breathe; p.sx = 1 - 0.015 * breathe
            // raise, wave three times, lower, rest
            let x = Self.phase(t, 3.4) * 3.4
            let up = Self.ease(x / 0.35) * (1 - Self.ease((x - 1.9) / 0.4))
            p.rightArm = -30 + (-115 * up) + up * sin((x - 0.35) * 2 * .pi / 0.52) * 18
            p.tilt = 4 * up
            p.look = lookAround(t)
        case .run:
            let w = t * 2 * .pi * 1.6                 // strides a second
            let s = sin(w)
            p.lift = abs(s) * 7
            let ground = 1 - abs(s)                    // squash as each foot lands
            p.sy = 1 - 0.05 * ground; p.sx = 1 + 0.04 * ground
            p.tilt = -6
            p.leftLeg = s * 30; p.rightLeg = -s * 30
            p.leftArm = 40 - s * 35; p.rightArm = -40 - s * 35
            p.look = 2
        case .cheer:
            // crouch, jump (stretched), land (squashed), settle, pause
            let x = Self.phase(t, 1.7) * 1.7
            let crouch = Self.ease(x / 0.18) * (1 - Self.ease((x - 0.18) / 0.08))
            let air = x > 0.24 && x < 0.80 ? (x - 0.24) / 0.56 : -1
            let land = x >= 0.80 ? sin(min((x - 0.80) / 0.22, 1) * .pi) * exp(-(x - 0.80) * 4) : 0
            if air >= 0 {
                p.lift = 26 * 4 * air * (1 - air)
                p.sy = 1 + 0.05 * (1 - abs(air - 0.5) * 2); p.sx = 1 - 0.035 * (1 - abs(air - 0.5) * 2)
            } else {
                let squash = max(crouch, land)
                p.sy = 1 - 0.10 * squash; p.sx = 1 + 0.08 * squash
            }
            let arms = air >= 0 ? 1.0 : Self.ease(1 - crouch)
            p.leftArm = 30 + 115 * arms; p.rightArm = -30 - 115 * arms
            p.leftLeg = air >= 0 ? -10 * sin(air * .pi) : 0; p.rightLeg = -p.leftLeg
        case .sleepy:
            let slow = sin(t * 2 * .pi / 4.2)
            p.sy = 1 + 0.03 * slow; p.sx = 1 - 0.02 * slow
            p.tilt = 7 + 1.5 * slow
            p.leftArm = 18; p.rightArm = -18
        case .worried:
            p.sy = 1 + 0.015 * breathe
            p.tilt = sin(t * 2 * .pi / 2.6) * 3        // a slow, nervous sway
            p.leftArm = 12; p.rightArm = -12
            p.look = sin(t * 2 * .pi / 2.6) > 0 ? 3 : -3
        }
        return p
    }

    /// now and then the eyes glance to one side, then back
    private func lookAround(_ t: Double) -> Double {
        let x = Self.phase(t, 6.5) * 6.5
        let side = Int(t / 6.5) % 2 == 0 ? 3.0 : -3.0
        return side * Self.ease((x - 3.6) / 0.25) * (1 - Self.ease((x - 4.8) / 0.25))
    }

    /// how open the eyes are, 0…1: a quick eased blink every few seconds, sometimes twice
    private func eyesOpen(_ t: Double) -> Double {
        if mood == .sleepy { return 0 }
        let period = 4.4
        let x = Self.phase(t, period) * period
        func blink(at s: Double) -> Double { let d = abs(x - s) / 0.075; return d < 1 ? 1 - Self.ease(1 - d) : 1 }
        let twice = Int(t / period) % 3 == 1
        return min(blink(at: 0.1), twice ? blink(at: 0.32) : 1)
    }

    // everything in a 200×200 box
    private func draw(_ ctx: inout GraphicsContext, _ t: Double, boing: Double?) {
        var p = pose(t)
        if let b = boing {
            // squash, hop with a full spin, land with a wobble
            let squash = 1 - Self.ease(b / 0.15)
            let air = b > 0.15 && b < 0.7 ? (b - 0.15) / 0.55 : -1
            if air >= 0 {
                p.lift = 30 * 4 * air * (1 - air)
                p.tilt = 360 * Self.ease(air)
                p.sy = 1.05; p.sx = 0.96
            } else if b <= 0.15 {
                p.sy = 1 - 0.12 * (1 - squash); p.sx = 1 + 0.1 * (1 - squash)
            } else {
                let w = (b - 0.7) / 0.3
                p.sy = 1 - 0.08 * sin(w * .pi) * (1 - w); p.sx = 1 + 0.06 * sin(w * .pi) * (1 - w)
            }
            p.leftArm = 140; p.rightArm = -140
        }

        // a soft shadow on the ground, smaller and lighter while up in the air
        let up = min(p.lift / 26, 1)
        ctx.fill(Path(ellipseIn: CGRect(x: 60 + 16 * up, y: 186, width: 80 - 32 * up, height: 10)),
                 with: .color(.black.opacity(0.18 - 0.08 * up)))

        var fig = ctx  // the whole figure: lifted, squashed from the feet, tilted
        fig.translateBy(x: 100, y: 188 - p.lift)
        fig.scaleBy(x: p.sx, y: p.sy)
        fig.rotate(by: .degrees(p.tilt))
        fig.translateBy(x: -100, y: -188)

        leg(&fig, hip: CGPoint(x: 86, y: 156), angle: p.leftLeg)
        leg(&fig, hip: CGPoint(x: 114, y: 156), angle: p.rightLeg)
        arm(&fig, shoulder: CGPoint(x: 44, y: 112), angle: p.leftArm)
        arm(&fig, shoulder: CGPoint(x: 156, y: 112), angle: p.rightArm)

        // the clock, lit from the top left so it looks round: a glossy coral case, a face sunk into it, a shine
        let caseShape = Path(ellipseIn: CGRect(x: 36, y: 36, width: 128, height: 128))
        fig.fill(caseShape, with: .radialGradient(Gradient(colors: [Self.coralLight, Self.coral, Self.coralDark]),
                                                  center: CGPoint(x: 78, y: 66), startRadius: 4, endRadius: 108))
        let faceShape = Path(ellipseIn: CGRect(x: 50, y: 50, width: 100, height: 100))
        fig.fill(faceShape, with: .radialGradient(Gradient(colors: [Self.cream, Self.cream, Self.creamShade]),
                                                  center: CGPoint(x: 92, y: 88), startRadius: 0, endRadius: 62))
        fig.stroke(Path(ellipseIn: CGRect(x: 51.5, y: 51.5, width: 97, height: 97)),
                   with: .color(Self.coralDark.opacity(0.45)), lineWidth: 3)  // the rim's inner edge
        var shine = fig
        shine.translateBy(x: 66, y: 56)
        shine.rotate(by: .degrees(-35))
        shine.fill(Path(ellipseIn: CGRect(x: -14, y: -6, width: 28, height: 12)), with: .color(.white.opacity(0.45)))
        for (x, y, w, h) in [(97.0, 56.0, 6.0, 11.0), (57.0, 97.0, 11.0, 6.0), (132.0, 97.0, 11.0, 6.0)] {  // 12, 9 and 3 (6 is the smile)
            fig.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: 3), with: .color(Self.ink.opacity(0.85)))
        }

        drawFace(&fig, t, open: boing == nil ? eyesOpen(t) : 0, look: boing == nil ? p.look : 0, happy: boing != nil)
    }

    private func drawFace(_ ctx: inout GraphicsContext, _ t: Double, open: Double, look: Double, happy: Bool = false) {
        let ink = GraphicsContext.Shading.color(Self.ink)
        func eye(_ x: Double) {
            let x = x + look
            if open < 0.15 {
                // shut: a soft curve (smiling when happy, sleepy otherwise)
                var p = Path()
                p.move(to: CGPoint(x: x - 7, y: 91))
                p.addQuadCurve(to: CGPoint(x: x + 7, y: 91), control: CGPoint(x: x, y: mood == .sleepy && !happy ? 97 : 85))
                ctx.stroke(p, with: ink, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            } else {
                let tall = (mood == .worried ? 18.0 : 16.0) * open
                ctx.fill(Path(ellipseIn: CGRect(x: x - 6.5, y: 90 - tall / 2, width: 13, height: tall)), with: ink)
                if open > 0.6 {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: 90 - tall / 2 + 2.5, width: 4.5, height: 4.5)), with: .color(.white))
                }
            }
        }
        eye(82)
        eye(118)

        // cheeks
        ctx.fill(Path(ellipseIn: CGRect(x: 62, y: 104, width: 16, height: 9)), with: .color(Self.blush.opacity(0.6)))
        ctx.fill(Path(ellipseIn: CGRect(x: 122, y: 104, width: 16, height: 9)), with: .color(Self.blush.opacity(0.6)))

        switch happy ? Mood.cheer : mood {
        case .worried:
            // a wobbly little mouth, and a drop of sweat that slides down and fades
            var m = Path()
            m.move(to: CGPoint(x: 91, y: 120))
            m.addCurve(to: CGPoint(x: 109, y: 120), control1: CGPoint(x: 96, y: 114), control2: CGPoint(x: 104, y: 126))
            ctx.stroke(m, with: ink, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            let d = Self.phase(t, 2.2)
            var drop = ctx
            drop.opacity = 1 - Self.ease((d - 0.6) / 0.4)
            drop.translateBy(x: 0, y: 12 * Self.ease(d / 0.9))
            var p = Path()
            p.move(to: CGPoint(x: 140, y: 62))
            p.addQuadCurve(to: CGPoint(x: 140, y: 78), control: CGPoint(x: 149, y: 76))
            p.addQuadCurve(to: CGPoint(x: 140, y: 62), control: CGPoint(x: 131, y: 76))
            drop.fill(p, with: .color(Color(red: 0.45, green: 0.75, blue: 1.0)))
        case .sleepy:
            ctx.fill(Path(ellipseIn: CGRect(x: 96, y: 114, width: 8, height: 7)), with: ink)
            // two z's drifting up and out, one after the other
            for k in 0..<2 {
                let z = Self.phase(t + Double(k) * 1.4, 2.8)
                ctx.draw(Text("z").font(.system(size: 14 + 8 * z, weight: .heavy, design: .rounded))
                            .foregroundStyle(Self.ink.opacity(0.75 * sin(z * .pi))),
                         at: CGPoint(x: 146 + 14 * z, y: 52 - 26 * z))
            }
        default:
            var smile = Path()
            let wide = mood == .cheer ? 18.0 : 15.0
            smile.move(to: CGPoint(x: 100 - wide, y: 109))
            smile.addQuadCurve(to: CGPoint(x: 100 + wide, y: 109), control: CGPoint(x: 100, y: mood == .cheer ? 142 : 134))
            smile.closeSubpath()
            ctx.fill(smile, with: ink)
            ctx.fill(Path(ellipseIn: CGRect(x: 93, y: 117, width: 14, height: 7)), with: .color(Color(red: 1.0, green: 0.45, blue: 0.45)))
        }
    }

    /// an arm: a short coral stick turned about the shoulder, with a round hand
    private func arm(_ ctx: inout GraphicsContext, shoulder: CGPoint, angle: Double) {
        var a = ctx
        a.translateBy(x: shoulder.x, y: shoulder.y)
        a.rotate(by: .degrees(angle))
        var p = Path(); p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: 30))
        a.stroke(p, with: .color(Self.coralDark), style: StrokeStyle(lineWidth: 9, lineCap: .round))
        a.fill(Path(ellipseIn: CGRect(x: -8, y: 26, width: 16, height: 16)),
               with: .radialGradient(Gradient(colors: [Self.coralLight, Self.coral]), center: CGPoint(x: -3, y: 30), startRadius: 0, endRadius: 12))
    }

    /// a leg with a little shoe
    private func leg(_ ctx: inout GraphicsContext, hip: CGPoint, angle: Double) {
        var l = ctx
        l.translateBy(x: hip.x, y: hip.y)
        l.rotate(by: .degrees(angle))
        var p = Path(); p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: 30))
        l.stroke(p, with: .color(Self.ink), style: StrokeStyle(lineWidth: 7, lineCap: .round))
        l.fill(Path(roundedRect: CGRect(x: -10, y: 27, width: 23, height: 12), cornerRadius: 6),
               with: .linearGradient(Gradient(colors: [Self.coral, Self.coralDark]), startPoint: CGPoint(x: 0, y: 27), endPoint: CGPoint(x: 0, y: 39)))
    }
}
