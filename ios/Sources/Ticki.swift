// Ticki, omw!'s mascot: a little coral alarm clock that's always "down soon". Drawn in code (sharp at any size) and
// always moving a bit, like Grok's or Duolingo's characters. One view, a few moods:
//   .wave     hello (sign in, empty friends)              .run      on the way (loading, time to leave)
//   .cheer    everyone's here / on time                    .sleepy   nothing planned
//   .worried  someone's running late, or something failed  .idle     just hanging out (bobs and blinks)
import SwiftUI

struct Ticki: View {
    enum Mood { case idle, wave, run, cheer, sleepy, worried }
    var mood: Mood = .idle

    private static let coral = Color(red: 0.95, green: 0.41, blue: 0.29)
    private static let coralDark = Color(red: 0.80, green: 0.30, blue: 0.22)
    private static let cream = Color(red: 1.0, green: 0.97, blue: 0.93)
    private static let creamShade = Color(red: 0.93, green: 0.86, blue: 0.80)
    private static let coralLight = Color(red: 1.0, green: 0.60, blue: 0.47)
    private static let ink = Color(red: 0.12, green: 0.12, blue: 0.16)
    private static let blush = Color(red: 1.0, green: 0.60, blue: 0.56)
    private static let spark = Color(red: 1.0, green: 0.80, blue: 0.24)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let k = min(size.width, size.height) / 200
                ctx.scaleBy(x: k, y: k)
                draw(&ctx, t)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Ticki")
    }

    // everything in a 200×200 box
    private func draw(_ ctx: inout GraphicsContext, _ t: Double) {
        let speed = mood == .run ? 9.0 : mood == .cheer ? 5.0 : 2.4
        let bob = mood == .sleepy ? sin(t * 1.2) * 2 : mood == .cheer ? -abs(sin(t * speed / 2)) * 16 : sin(t * speed) * 3
        let lean = mood == .run ? -8.0 : mood == .worried ? sin(t * 14) * 2.5 : 0  // leaning into a run, or trembling

        // a soft shadow on the ground (smaller while it's up in the air)
        let lift = max(0, -bob) / 16
        ctx.fill(Path(ellipseIn: CGRect(x: 58 + 14 * lift, y: 190, width: 84 - 28 * lift, height: 10)),
                 with: .color(.black.opacity(0.22 - 0.1 * lift)))

        var fig = ctx  // the whole figure, bobbing and leaning
        fig.translateBy(x: 100, y: 100 + bob)
        fig.rotate(by: .degrees(lean))
        fig.translateBy(x: -100, y: -100)

        // speed lines behind a run, sparkles over a cheer
        if mood == .run || mood == .cheer {
            let lines: [(CGPoint, CGPoint)] = mood == .run
                ? [(CGPoint(x: 22, y: 78), CGPoint(x: 4, y: 74)), (CGPoint(x: 20, y: 100), CGPoint(x: 0, y: 100)), (CGPoint(x: 24, y: 122), CGPoint(x: 6, y: 128))]
                : [(CGPoint(x: 150, y: 30), CGPoint(x: 162, y: 14)), (CGPoint(x: 166, y: 44), CGPoint(x: 184, y: 36)), (CGPoint(x: 46, y: 34), CGPoint(x: 36, y: 18))]
            let flicker = 0.55 + 0.45 * abs(sin(t * 7))
            for (a, b) in lines {
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(Self.spark.opacity(flicker)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }
        }

        // legs: running swings them, otherwise they just stand
        let swing = mood == .run ? sin(t * speed) * 28 : mood == .cheer ? sin(t * speed) * 10 : 0
        leg(&fig, hip: CGPoint(x: 86, y: 156), angle: swing)
        leg(&fig, hip: CGPoint(x: 114, y: 156), angle: -swing)

        // arms: one waves, both go up to cheer, they pump on a run
        let wave = sin(t * 8) * 22
        let leftArm: Double = mood == .cheer ? 150 : mood == .run ? 40 + swing : 30
        let rightArm: Double = mood == .wave ? -140 + wave : mood == .cheer ? -150 : mood == .run ? -40 + swing : mood == .worried ? -10 : -30
        arm(&fig, shoulder: CGPoint(x: 44, y: 112), angle: leftArm)
        arm(&fig, shoulder: CGPoint(x: 156, y: 112), angle: rightArm)

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
            fig.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: 3), with: .color(Self.ink))
        }

        drawFace(&fig, t)
    }

    private func drawFace(_ ctx: inout GraphicsContext, _ t: Double) {
        let ink = GraphicsContext.Shading.color(Self.ink)
        // a blink every few seconds (sleepy ones stay shut)
        let blink = mood == .sleepy || t.truncatingRemainder(dividingBy: 3.6) < 0.12
        func eye(_ x: Double, wink: Bool = false) {
            if blink || wink {
                var p = Path()
                p.move(to: CGPoint(x: x - 7, y: 92))
                p.addQuadCurve(to: CGPoint(x: x + 7, y: 92), control: CGPoint(x: x, y: wink ? 84 : 98))
                ctx.stroke(p, with: ink, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            } else {
                let tall = mood == .worried ? 19.0 : 16.0
                ctx.fill(Path(ellipseIn: CGRect(x: x - 6.5, y: 90 - tall / 2, width: 13, height: tall)), with: ink)
                ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: 90 - tall / 2 + 2.5, width: 5, height: 5)), with: .color(.white))
            }
        }
        eye(82)
        eye(118, wink: mood == .wave || mood == .cheer)

        // cheeks
        ctx.fill(Path(ellipseIn: CGRect(x: 62, y: 104, width: 16, height: 9)), with: .color(Self.blush.opacity(0.7)))
        ctx.fill(Path(ellipseIn: CGRect(x: 122, y: 104, width: 16, height: 9)), with: .color(Self.blush.opacity(0.7)))

        // mouth: a big open smile, a small "o" when worried, a little line when sleepy
        switch mood {
        case .worried:
            ctx.fill(Path(ellipseIn: CGRect(x: 94, y: 112, width: 12, height: 14)), with: ink)
            // a drop of sweat
            var drop = Path()
            drop.move(to: CGPoint(x: 140, y: 66))
            drop.addQuadCurve(to: CGPoint(x: 140, y: 82), control: CGPoint(x: 150, y: 80))
            drop.addQuadCurve(to: CGPoint(x: 140, y: 66), control: CGPoint(x: 130, y: 80))
            ctx.fill(drop, with: .color(Color(red: 0.45, green: 0.75, blue: 1.0)))
        case .sleepy:
            var p = Path(); p.move(to: CGPoint(x: 93, y: 118)); p.addLine(to: CGPoint(x: 107, y: 118))
            ctx.stroke(p, with: ink, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            let z = (t * 0.6).truncatingRemainder(dividingBy: 1)
            ctx.draw(Text("z").font(.system(size: 18 + 8 * z, weight: .black, design: .rounded)).foregroundStyle(Self.ink.opacity(1 - z)),
                     at: CGPoint(x: 150 + 10 * z, y: 50 - 24 * z))
        default:
            var smile = Path()
            smile.move(to: CGPoint(x: 84, y: 109))
            smile.addQuadCurve(to: CGPoint(x: 116, y: 109), control: CGPoint(x: 100, y: 140))
            smile.closeSubpath()
            ctx.fill(smile, with: ink)
            ctx.fill(Path(ellipseIn: CGRect(x: 93, y: 118, width: 14, height: 8)), with: .color(Color(red: 1.0, green: 0.45, blue: 0.45)))
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
