// Ticki, omw!'s mascot: a little coral alarm clock that's always "down soon". Drawn in code (sharp at any size) and
// always moving a bit, like Grok's or Duolingo's characters. One view, a few moods:
//   .wave     hello (sign in, empty friends)              .run      on the way (loading, time to leave)
//   .cheer    everyone's here / on time                    .sleepy   nothing planned
//   .worried  someone's running late, or something failed  .idle     just hanging out (breathes, blinks, fidgets)
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
    @State private var pokeKind = 0
    @State private var seed = Double.random(in: 0..<1000)

    private static let coral = Color(red: 0.95, green: 0.41, blue: 0.29)
    private static let coralDark = Color(red: 0.80, green: 0.30, blue: 0.22)
    private static let coralDeep = Color(red: 0.62, green: 0.21, blue: 0.16)   // the side of the case, in shadow
    private static let cream = Color(red: 1.0, green: 0.97, blue: 0.93)
    private static let creamShade = Color(red: 0.93, green: 0.86, blue: 0.80)
    private static let coralLight = Color(red: 1.0, green: 0.60, blue: 0.47)
    private static let ink = Color(red: 0.12, green: 0.12, blue: 0.16)
    private static let blush = Color(red: 1.0, green: 0.60, blue: 0.56)
    /// how much bigger than its square Ticki may draw (spins, jumps, raised arms)
    private static let room = 1.8

    var body: some View {
        // Ticki takes up a square, but draws in a bigger one around it (no clipping), so arms, bells and jumps that
        // swing outside the square while it spins or hops never get cut off at an invisible edge
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { g in
                    let side = min(g.size.width, g.size.height)
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let b = boing(timeline.date)
                        Canvas { ctx, size in
                            ctx.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
                            ctx.scaleBy(x: side / 200, y: side / 200)
                            draw(&ctx, t, boing: b)
                        }
                    }
                    .frame(width: side * Self.room, height: side * Self.room)
                    .position(x: g.size.width / 2, y: g.size.height / 2)
                    .allowsHitTesting(false)
                }
            }
        .contentShape(Circle())
        // tap Ticki and it boings, spins, and says something (and doesn't open whatever it's sitting on)
        .onTapGesture { poke() }
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
        pokeKind = (pokeKind + Int.random(in: 1...3)) % 4  // a different reaction from last time
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
    // Slow, eased loops instead of constant jiggle (breathing with a little squash and stretch, jumps with anticipation
    // and a landing squash), and never quite the same twice: every few seconds Ticki picks something different to do
    // (a glance, a hop, a stretch, a head tilt), blinks at its own times, and each Ticki on screen has its own rhythm.

    private static func ease(_ x: Double) -> Double { let x = min(max(x, 0), 1); return x * x * (3 - 2 * x) }
    /// 0…1 through a loop of `period` seconds
    private static func phase(_ t: Double, _ period: Double) -> Double { (t / period).truncatingRemainder(dividingBy: 1) }
    /// a steady "random" 0…1 for a moment k (the same k always gives the same number, so frames agree)
    private func rnd(_ k: Double) -> Double {
        let x = sin((k + seed) * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }
    /// 0→1→0 over `length` seconds starting at `start` (eased in and out)
    private static func bump(_ x: Double, _ start: Double, _ length: Double) -> Double {
        let u = (x - start) / length
        guard u > 0, u < 1 else { return 0 }
        return sin(u * .pi)
    }

    private struct Pose {
        var lift = 0.0                 // up off the ground
        var sx = 1.0, sy = 1.0         // squash and stretch, from the feet
        var tilt = 0.0                 // degrees
        var leftArm = 30.0, rightArm = -30.0
        var leftLeg = 0.0, rightLeg = 0.0
        var look = 0.0                 // eyes left/right
    }

    /// a little something every few seconds while idling: nothing, a glance, a hop, a stretch, or a head tilt
    private func fidget(_ t: Double, _ p: inout Pose) {
        let beat = 4.8
        let k = (t / beat).rounded(.down)
        let x = t - k * beat
        let start = 0.4 + rnd(k + 0.3) * 2.6
        let side = rnd(k + 0.7) < 0.5 ? -1.0 : 1.0
        switch rnd(k) {
        case ..<0.3: break
        case ..<0.55: p.look += side * 3 * min(1, Self.bump(x, start, 1.4) * 2)
        case ..<0.7:
            let u = (x - start) / 0.5
            if u > 0, u < 1 { p.lift = 9 * 4 * u * (1 - u) } else if u >= 1, u < 1.3 { p.sy -= 0.05 * sin((u - 1) / 0.3 * .pi); p.sx += 0.04 * sin((u - 1) / 0.3 * .pi) }
        case ..<0.85:
            let s = Self.bump(x, start, 1.3)
            p.sy += 0.05 * s; p.sx -= 0.03 * s
            p.leftArm += 100 * s; p.rightArm -= 100 * s
        default: p.tilt += side * 7 * Self.bump(x, start, 1.5); p.look += side * 2 * Self.bump(x, start, 1.5)
        }
    }

    private func pose(_ t0: Double) -> Pose {
        let t = t0 + seed  // each Ticki on its own rhythm
        var p = Pose()
        let breathe = sin(t * 2 * .pi / 3.2)
        switch mood {
        case .idle:
            p.sy = 1 + 0.022 * breathe; p.sx = 1 - 0.016 * breathe
            p.leftArm = 28 + 3 * breathe; p.rightArm = -28 - 3 * breathe
            fidget(t, &p)
        case .wave:
            p.sy = 1 + 0.02 * breathe; p.sx = 1 - 0.015 * breathe
            // raise, wave 2 to 4 times (faster or slower), lower, rest; now and then just hang out instead
            let beat = 3.8
            let k = (t / beat).rounded(.down)
            let x = t - k * beat
            if rnd(k + 0.1) < 0.25 { fidget(t, &p); break }
            let waves = 2.0 + (rnd(k + 0.2) * 3).rounded(.down)
            let speed = 0.44 + rnd(k + 0.4) * 0.16
            let hold = 0.35 + waves * speed
            let up = Self.ease(x / 0.35) * (1 - Self.ease((x - hold) / 0.4))
            p.rightArm = -30 + (-115 * up) + up * sin((x - 0.35) * 2 * .pi / speed) * 18
            p.tilt = (rnd(k + 0.5) < 0.5 ? 4 : -3) * up
        case .run:
            let w = t * 2 * .pi * 1.6                 // strides a second
            let s = sin(w)
            p.lift = abs(s) * 7
            let ground = 1 - abs(s)                    // squash as each foot lands
            p.sy = 1 - 0.05 * ground; p.sx = 1 + 0.04 * ground
            p.tilt = -6 + sin(t * 0.9) * 2
            p.leftLeg = s * 30; p.rightLeg = -s * 30
            p.leftArm = 40 - s * 35; p.rightArm = -40 - s * 35
            p.look = 2
        case .cheer:
            // crouch, then a jump, a spinning jump, or two little hops; land squashed, pause
            let beat = 1.9
            let k = (t / beat).rounded(.down)
            let x = t - k * beat
            let kind = rnd(k)
            let crouch = Self.ease(x / 0.18) * (1 - Self.ease((x - 0.18) / 0.08))
            if kind > 0.75 {
                // two little hops
                let h1 = (x - 0.24) / 0.3, h2 = (x - 0.6) / 0.3
                let air = h1 > 0 && h1 < 1 ? h1 : h2 > 0 && h2 < 1 ? h2 : -1
                p.lift = air >= 0 ? 14 * 4 * air * (1 - air) : 0
                if air < 0 { p.sy = 1 - 0.08 * crouch; p.sx = 1 + 0.06 * crouch }
                p.leftArm = 120; p.rightArm = -120 - (air >= 0 ? 20 * sin(air * .pi) : 0)
            } else {
                let air = x > 0.24 && x < 0.80 ? (x - 0.24) / 0.56 : -1
                let land = x >= 0.80 ? sin(min((x - 0.80) / 0.22, 1) * .pi) * exp(-(x - 0.80) * 4) : 0
                if air >= 0 {
                    p.lift = (22 + 8 * rnd(k + 0.6)) * 4 * air * (1 - air)
                    p.sy = 1 + 0.05 * (1 - abs(air - 0.5) * 2); p.sx = 1 - 0.035 * (1 - abs(air - 0.5) * 2)
                    if kind > 0.5 { p.tilt = (rnd(k + 0.8) < 0.5 ? 360 : -360) * Self.ease(air) }
                } else {
                    let squash = max(crouch, land)
                    p.sy = 1 - 0.10 * squash; p.sx = 1 + 0.08 * squash
                }
                let arms = air >= 0 ? 1.0 : Self.ease(1 - crouch)
                p.leftArm = 30 + 115 * arms; p.rightArm = -30 - 115 * arms
                p.leftLeg = air >= 0 ? -10 * sin(air * .pi) : 0; p.rightLeg = -p.leftLeg
            }
        case .sleepy:
            let slow = sin(t * 2 * .pi / 4.2)
            p.sy = 1 + 0.03 * slow; p.sx = 1 - 0.02 * slow
            p.tilt = 7 + 1.5 * slow
            p.leftArm = 18; p.rightArm = -18
            // now and then the head drops, then jerks back up
            let beat = 6.0, k = (t / beat).rounded(.down), x = t - k * beat
            if rnd(k) > 0.5 { p.tilt += 10 * Self.bump(x, 1 + rnd(k + 0.2) * 3, 1.0) }
        case .worried:
            let amp = 2 + rnd((t / 2.6).rounded(.down)) * 3
            p.sy = 1 + 0.015 * breathe
            p.tilt = sin(t * 2 * .pi / 2.6) * amp       // a slow, nervous sway
            p.leftArm = 12; p.rightArm = -12
            p.look = sin(t * 2 * .pi / 2.6) > 0 ? 3 : -3
        }
        return p
    }

    /// how open the eyes are, 0…1: a quick eased blink at its own time each few seconds, sometimes twice
    private func eyesOpen(_ t0: Double) -> Double {
        if mood == .sleepy { return 0 }
        let t = t0 + seed
        let beat = 3.9
        let k = (t / beat).rounded(.down)
        let x = t - k * beat
        let at = 0.2 + rnd(k + 0.9) * 3.2
        func blink(_ s: Double) -> Double { let d = abs(x - s) / 0.075; return d < 1 ? 1 - Self.ease(1 - d) : 1 }
        return min(blink(at), rnd(k + 0.45) > 0.75 ? blink(at + 0.24) : 1)
    }

    // everything in a 200×200 box
    private func draw(_ ctx: inout GraphicsContext, _ t: Double, boing: Double?) {
        var p = pose(t)
        if let b = boing {
            switch pokeKind {
            case 0, 1:
                // squash, hop with a full spin (either way), land with a wobble
                let squash = 1 - Self.ease(b / 0.15)
                let air = b > 0.15 && b < 0.7 ? (b - 0.15) / 0.55 : -1
                if air >= 0 {
                    p.lift = 30 * 4 * air * (1 - air)
                    p.tilt = (pokeKind == 0 ? 360 : -360) * Self.ease(air)
                    p.sy = 1.05; p.sx = 0.96
                } else if b <= 0.15 {
                    p.sy = 1 - 0.12 * (1 - squash); p.sx = 1 + 0.1 * (1 - squash)
                } else {
                    let w = (b - 0.7) / 0.3
                    p.sy = 1 - 0.08 * sin(w * .pi) * (1 - w); p.sx = 1 + 0.06 * sin(w * .pi) * (1 - w)
                }
                p.leftArm = 140; p.rightArm = -140
            case 2:
                // squished flat like a spring, then boings back
                let w = sin(b * .pi * 3) * (1 - b)
                p.sy = 1 - 0.18 * w; p.sx = 1 + 0.14 * w
                p.leftArm = 70; p.rightArm = -70
            default:
                // a giggly wiggle
                p.tilt = sin(b * .pi * 6) * 12 * (1 - b)
                p.lift = 6 * sin(b * .pi)
                p.leftArm = 60 + 30 * sin(b * .pi * 6); p.rightArm = -60 + 30 * sin(b * .pi * 6)
            }
        }

        // a soft shadow on the ground (a gradient, not a blur, so nothing but Ticki is ever drawn), smaller and lighter
        // while up in the air
        let up = min(p.lift / 26, 1)
        var shadow = ctx
        shadow.translateBy(x: 100, y: 190)
        shadow.scaleBy(x: 1, y: 0.16)
        let r = 44 - 16 * up
        shadow.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)),
                    with: .radialGradient(Gradient(colors: [.black.opacity(0.3 - 0.14 * up), .black.opacity(0.12 - 0.06 * up), .clear]),
                                          center: .zero, startRadius: 0, endRadius: r))

        var fig = ctx  // the whole figure: lifted, squashed from the feet, tilted
        fig.translateBy(x: 100, y: 188 - p.lift)
        fig.scaleBy(x: p.sx, y: p.sy)
        fig.rotate(by: .degrees(p.tilt))
        fig.translateBy(x: -100, y: -188)

        leg(&fig, hip: CGPoint(x: 86, y: 156), angle: p.leftLeg)
        leg(&fig, hip: CGPoint(x: 114, y: 156), angle: p.rightLeg)
        arm(&fig, shoulder: CGPoint(x: 44, y: 112), angle: p.leftArm)
        arm(&fig, shoulder: CGPoint(x: 156, y: 112), angle: p.rightArm)

        // the alarm bells on top, little glossy domes tucked behind the case
        for side in [-1.0, 1.0] {
            var bell = fig
            bell.translateBy(x: 100 + side * 44, y: 50)
            bell.rotate(by: .degrees(side * 38))
            bell.fill(Path(roundedRect: CGRect(x: -2.5, y: -2, width: 5, height: 12), cornerRadius: 2), with: .color(Self.ink.opacity(0.8)))
            var dome = Path()
            dome.addArc(center: CGPoint(x: 0, y: -2), radius: 15, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            dome.closeSubpath()
            bell.fill(dome, with: .radialGradient(Gradient(colors: [Self.coralLight, Self.coral, Self.coralDark]),
                                                  center: CGPoint(x: -5, y: -11), startRadius: 1, endRadius: 20))
            bell.fill(Path(ellipseIn: CGRect(x: -9, y: -13, width: 7, height: 4)), with: .color(.white.opacity(0.55)))
        }

        // the clock: a thick coral puck lit from the top left. Its side shows below and to the right, the face is sunk
        // in under a glass cover, and the rim catches the light.
        fig.fill(Path(ellipseIn: CGRect(x: 38, y: 41, width: 128, height: 128)), with: .color(Self.coralDeep))  // the side
        let caseShape = Path(ellipseIn: CGRect(x: 36, y: 36, width: 128, height: 128))
        fig.fill(caseShape, with: .radialGradient(Gradient(colors: [Self.coralLight, Self.coral, Self.coralDark]),
                                                  center: CGPoint(x: 76, y: 62), startRadius: 4, endRadius: 112))
        fig.stroke(Path(ellipseIn: CGRect(x: 37.5, y: 37.5, width: 125, height: 125)),
                   with: .linearGradient(Gradient(colors: [.white.opacity(0.55), .clear, .clear, .black.opacity(0.18)]),
                                         startPoint: CGPoint(x: 50, y: 40), endPoint: CGPoint(x: 150, y: 160)), lineWidth: 3)
        let faceRect = CGRect(x: 50, y: 50, width: 100, height: 100)
        let faceShape = Path(ellipseIn: faceRect)
        fig.fill(faceShape, with: .radialGradient(Gradient(colors: [Self.cream, Self.cream, Self.creamShade]),
                                                  center: CGPoint(x: 94, y: 92), startRadius: 0, endRadius: 62))
        // sunk in: shade along the top inside edge (a gradient centered low, darkest at the top rim)
        fig.fill(faceShape, with: .radialGradient(Gradient(colors: [.clear, .clear, Self.coralDeep.opacity(0.32)]),
                                                  center: CGPoint(x: 102, y: 108), startRadius: 0, endRadius: 60))
        fig.stroke(Path(ellipseIn: faceRect.insetBy(dx: 1, dy: 1)),
                   with: .linearGradient(Gradient(colors: [Self.coralDark.opacity(0.7), Self.coralDark.opacity(0.15)]),
                                         startPoint: CGPoint(x: 70, y: 52), endPoint: CGPoint(x: 130, y: 150)), lineWidth: 2.5)
        for (x, y, w, h) in [(97.0, 56.0, 6.0, 11.0), (57.0, 97.0, 11.0, 6.0), (132.0, 97.0, 11.0, 6.0)] {  // 12, 9 and 3 (6 is the smile)
            fig.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: 3), with: .color(Self.ink.opacity(0.85)))
        }

        drawFace(&fig, t, open: boing == nil ? eyesOpen(t) : 0, look: boing == nil ? p.look : 0, happy: boing != nil)

        // the glass over the face: a faint sheen across the top, and a crisp highlight on the case
        var glass = fig
        glass.clip(to: faceShape)
        glass.fill(Path(ellipseIn: CGRect(x: 44, y: 38, width: 96, height: 60)),
                   with: .linearGradient(Gradient(colors: [.white.opacity(0.32), .white.opacity(0)]),
                                         startPoint: CGPoint(x: 80, y: 46), endPoint: CGPoint(x: 92, y: 92)))
        var shine = fig
        shine.translateBy(x: 64, y: 54)
        shine.rotate(by: .degrees(-38))
        shine.fill(Path(ellipseIn: CGRect(x: -15, y: -5.5, width: 30, height: 11)), with: .color(.white.opacity(0.6)))
        shine.fill(Path(ellipseIn: CGRect(x: 18, y: -3, width: 6, height: 6)), with: .color(.white.opacity(0.5)))
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
                // glossy eyes: a little lighter at the bottom, a big glint and a small one
                ctx.fill(Path(ellipseIn: CGRect(x: x - 6.5, y: 90 - tall / 2, width: 13, height: tall)),
                         with: .linearGradient(Gradient(colors: [Self.ink, Self.ink, Color(red: 0.25, green: 0.24, blue: 0.32)]),
                                               startPoint: CGPoint(x: x, y: 90 - tall / 2), endPoint: CGPoint(x: x, y: 90 + tall / 2)))
                if open > 0.6 {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: 90 - tall / 2 + 2.5, width: 4.5, height: 4.5)), with: .color(.white))
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: 90 + tall / 2 - 5, width: 2.2, height: 2.2)), with: .color(.white.opacity(0.7)))
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
        // a tube: lit on one side, shaded on the other
        a.stroke(p, with: .linearGradient(Gradient(colors: [Self.coral, Self.coralDark, Self.coralDeep]),
                                         startPoint: CGPoint(x: -4.5, y: 0), endPoint: CGPoint(x: 4.5, y: 0)),
                 style: StrokeStyle(lineWidth: 9, lineCap: .round))
        // a round hand, like a little ball
        a.fill(Path(ellipseIn: CGRect(x: -8.5, y: 25.5, width: 17, height: 17)),
               with: .radialGradient(Gradient(colors: [Self.coralLight, Self.coral, Self.coralDeep]), center: CGPoint(x: -3, y: 30), startRadius: 0, endRadius: 13))
        a.fill(Path(ellipseIn: CGRect(x: -5, y: 28, width: 5, height: 4)), with: .color(.white.opacity(0.5)))
    }

    /// a leg with a little shoe
    private func leg(_ ctx: inout GraphicsContext, hip: CGPoint, angle: Double) {
        var l = ctx
        l.translateBy(x: hip.x, y: hip.y)
        l.rotate(by: .degrees(angle))
        var p = Path(); p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: 30))
        l.stroke(p, with: .linearGradient(Gradient(colors: [Color(white: 0.32), Self.ink, Self.ink]),
                                         startPoint: CGPoint(x: -3.5, y: 0), endPoint: CGPoint(x: 3.5, y: 0)),
                 style: StrokeStyle(lineWidth: 7, lineCap: .round))
        let shoe = Path(roundedRect: CGRect(x: -10, y: 27, width: 23, height: 12), cornerRadius: 6)
        l.fill(shoe.offsetBy(dx: 0, dy: 1.5), with: .color(Self.coralDeep))  // the sole
        l.fill(shoe, with: .linearGradient(Gradient(colors: [Self.coralLight, Self.coral, Self.coralDark]),
                                          startPoint: CGPoint(x: 0, y: 27), endPoint: CGPoint(x: 0, y: 39)))
        l.fill(Path(roundedRect: CGRect(x: -6, y: 28.5, width: 10, height: 3), cornerRadius: 1.5), with: .color(.white.opacity(0.45)))
    }
}
