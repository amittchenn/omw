// The first time you sign in: Ticki shows you around in three swipes (who it is, leave times, the on-time board).
// Seen once per phone (@AppStorage), and you can skip it.
import SwiftUI

struct TickiTour: View {
    var done: () -> Void
    @State private var page = 0

    private struct Page { let mood: Ticki.Mood, title: String, text: String, lines: [String] }
    private static let pages = [
        Page(mood: .wave, title: "Hi, I'm Ticki!", text: "I help you and your friends actually show up on time.",
             lines: ["Nice to meet you!", "Tap me anytime"]),
        Page(mood: .run, title: "I'll tell you when to leave", text: "Make a plan with the ＋. I work out everyone's trip, traffic and how late they usually run.",
             lines: ["Shoes on!", "I check the traffic for you"]),
        Page(mood: .cheer, title: "Then celebrate", text: "Check in when you get there, snap the group photo, and climb the on-time board.",
             lines: ["You made it!", "Don't be the late one"]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip", action: done).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.top, 8)
            TabView(selection: $page) {
                ForEach(Self.pages.indices, id: \.self) { i in
                    let p = Self.pages[i]
                    VStack(spacing: 14) {
                        Spacer()
                        Ticki(mood: p.mood, lines: p.lines).frame(width: 210, height: 210)
                        Text(p.title).font(.system(size: 28, weight: .heavy, design: .rounded)).multilineTextAlignment(.center)
                        Text(p.text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                        Spacer()
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            Button {
                if page < Self.pages.count - 1 { withAnimation(.snappy) { page += 1 } } else { done() }
            } label: {
                Text(page < Self.pages.count - 1 ? "Next" : "Let's go").font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.sun, in: .rect(cornerRadius: 16))
                    .foregroundStyle(.black)
            }
            .buttonStyle(Pressable())
            .padding(.horizontal, 20).padding(.bottom, 12)
        }
        .sensoryFeedback(.selection, trigger: page)
    }
}
