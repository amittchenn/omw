// The rest of the web app's social bits:
//   the on-time board (web/leaderboard.js): who arrives within 5 minutes of the start, from everyone's check-ins
//   up next (web/feed.js upNext): your next plan in the next two days, on top of the feed
//   blocking someone, and making your account private or public (web/feed.js)
//   a friends list you can open from a profile, like Instagram's
import SwiftUI
import FirebaseFirestore

/// one person on the board
struct Standing: Identifiable {
    let id: String
    let name: String
    let hangouts: Int
    let onTime: Int
    let averageLate: Double
    let trend: Double            // negative: getting better lately
    var percent: Int { hangouts == 0 ? 0 : Int((100 * Double(onTime) / Double(hangouts)).rounded()) }
}

extension Session {
    static let lateAfterMinutes = 5.0

    /// you and your friends, most on time first (people without check-ins last)
    var standings: [Standing] {
        guard let me else { return [] }
        let people = [me] + friends
        var seen: [String: [String: Double]] = [:]  // person → hangout → minutes late
        for p in people { seen[p.id] = p.checkins }
        for h in hangouts.sorted(by: { $0.start < $1.start }) {
            for (who, at) in h.arrivals where seen[who] != nil {
                seen[who]?[h.id] = at.timeIntervalSince(h.start) / 60
            }
        }
        let list = people.map { p -> Standing in
            let lates = Array((seen[p.id] ?? [:]).values)
            let n = lates.count
            let avg = n > 0 ? lates.reduce(0, +) / Double(n) : 0
            var trend = 0.0
            if n >= 6 {
                let recent = Array(lates.suffix(3)), before = Array(lates.suffix(6).prefix(3))
                trend = recent.reduce(0, +) / 3 - before.reduce(0, +) / 3
            }
            return Standing(id: p.id, name: p.id == uid ? "You" : p.name, hangouts: n,
                            onTime: lates.filter { $0 <= Self.lateAfterMinutes }.count, averageLate: avg, trend: trend)
        }
        return list.sorted { a, b in
            if (a.hangouts > 0) != (b.hangouts > 0) { return a.hangouts > 0 }
            if a.percent != b.percent { return a.percent > b.percent }
            return a.averageLate < b.averageLate
        }
    }

    /// your next plan, if it's in the next two days
    var upNext: Hangout? {
        hangouts.filter { $0.end > .now && $0.start.timeIntervalSinceNow < 48 * 3600 }.min { $0.start < $1.start }
    }

    /// hides everything posted by or with them, and they can't find you in search
    func block(_ other: String) {
        guard let uid else { return }
        me?.blocked.append(other)
        db.collection("users").document(uid).setData(["blocked": FieldValue.arrayUnion([other])], merge: true)
    }

    func unblock(_ other: String) {
        guard let uid else { return }
        me?.blocked.removeAll { $0 == other }
        db.collection("users").document(uid).setData(["blocked": FieldValue.arrayRemove([other])], merge: true)
    }

    /// public: anyone on omw! can see your posts; private: friends only. Your posts follow along.
    func setPublic(_ on: Bool) {
        guard let uid else { return }
        isPublic = on
        db.collection("publicProfiles").document(uid).setData(["public": on], merge: true)
        db.collection("feed").whereField("by", isEqualTo: uid).whereField("viewers", arrayContains: uid).getDocuments { [weak self] snap, _ in
            MainActor.assumeIsolated {
                guard let self, let snap else { return }
                let batch = self.db.batch()
                for d in snap.documents where d.data()["kind"] as? String == "post" { batch.updateData(["public": on], forDocument: d.reference) }
                batch.commit()
            }
        }
    }
}

// ---------- the feed's cards ----------
/// your next plan: when, where, who's coming, and when to leave
struct UpNextCard: View {
    let hangout: Hangout
    @Environment(Session.self) private var session

    var body: some View {
        let uid = session.uid ?? ""
        let others = hangout.attendees.filter { $0 != uid }
        // Ticki stands on top of the card, popping out over its top edge, not boxed inside it. It's separate from the
        // link: tapping Ticki is Ticki's, tapping the card opens the plan.
        VStack(spacing: 0) {
          NavigationLink(value: PlanRoute(id: hangout.id)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(dayName) · \(hangout.start.formatted(date: .omitted, time: .shortened))")
                    .font(.caption.weight(.bold)).foregroundStyle(.red).textCase(.uppercase)
                Text(hangout.title).font(.title3.weight(.bold)).lineLimit(1)
                if !hangout.venueName.isEmpty, !hangout.title.contains(hangout.venueName) {
                    Text(hangout.venueName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    HStack(spacing: -8) {
                        ForEach(others.prefix(5), id: \.self) { u in
                            Avatar(session.person(u), fallback: hangout.names[u] ?? "", size: 26)
                                .overlay(Circle().stroke(Color(.secondarySystemBackground), lineWidth: 2))
                        }
                    }
                    Text(others.isEmpty ? "Just you so far" : others.prefix(2).map { session.person($0)?.firstName ?? hangout.names[$0] ?? "Friend" }
                         .joined(separator: ", ") + (others.count > 2 ? " +\(others.count - 2)" : ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if hangout.arrivals[uid] != nil {
                    Label("You're there", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Color.freeGreen)
                } else if tooFar {
                    // a trip over 12 hours means you're nowhere near (traveling, or a simulator somewhere else)
                    Label("You're far from here right now", systemImage: "location.slash")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if let leave = hangout.alerts[uid] {
                    Label {
                        Text("Leave by \(Text(leave.formatted(date: .omitted, time: .shortened)).bold())\(hangout.travel[uid].map { " · \(Self.trip($0)) trip" } ?? "")")
                    } icon: { Image(systemName: "clock.fill") }
                    .font(.subheadline).foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 64)  // room under Ticki
            .padding(16)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
        }
        .overlay(alignment: .topTrailing) {
            // running once it's nearly time to go, cheering once you're there
            Ticki(mood: tickiMood, lines: tickiLines)
                .frame(width: 88, height: 88)
                .offset(x: -8, y: -34)
        }
        .padding(.top, 34)
    }

    private var tooFar: Bool { (hangout.travel[session.uid ?? ""] ?? 0) > 12 * 60 }

    static func trip(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) hr" : "\(m / 60) hr \(m % 60) min"
    }

    private var tickiMood: Ticki.Mood {
        let uid = session.uid ?? ""
        if hangout.arrivals[uid] != nil { return .cheer }
        if tooFar { return .worried }
        if let leave = hangout.alerts[uid], leave.timeIntervalSinceNow < 30 * 60 { return leave < .now ? .worried : .run }
        return .idle
    }

    /// what Ticki says when you tap it, about this plan
    private var tickiLines: [String] {
        let uid = session.uid ?? ""
        let start = hangout.start.formatted(date: .omitted, time: .shortened)
        if hangout.arrivals[uid] != nil {
            let here = hangout.attendees.filter { hangout.arrivals[$0] != nil }.count
            return [here == hangout.attendees.count ? "Everyone made it!" : "\(here) of \(hangout.attendees.count) here", "On time looks good on you", "Snap the group photo!"]
        }
        if tooFar { return ["That's a long way…", "Are you even in town?"] }
        guard let leave = hangout.alerts[uid] else { return ["See you at \(start)", "Tap me later, I'll know when to leave"] }
        let mins = Int(leave.timeIntervalSinceNow / 60)
        if mins < 0 { return ["You were meant to leave \(-mins) min ago!", "Go go go!", "Tell them you're on the way"] }
        if mins < 30 { return ["Leave in \(mins) min!", "Grab your keys", "Shoes on?"] }
        let when = mins < 60 * 12 ? "in \(mins / 60 > 0 ? "\(mins / 60) hr \(mins % 60) min" : "\(mins) min")" : "at \(leave.formatted(date: .omitted, time: .shortened))"
        return ["Leave \(when)", "I'll buzz you when it's time", "Don't be the late one"]
    }

    private var dayName: String {
        let cal = Calendar.current
        if cal.isDateInToday(hangout.start) { return "Today" }
        if cal.isDateInTomorrow(hangout.start) { return "Tomorrow" }
        return hangout.start.formatted(.dateTime.weekday(.wide))
    }
}

/// the top three on the board (two or more people with check-ins)
struct BoardCard: View {
    @Environment(Session.self) private var session

    var body: some View {
        let board = session.standings.filter { $0.hangouts > 0 }
        if board.count >= 2 {
            NavigationLink { BoardView() } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("On-time board", systemImage: "trophy.fill").font(.headline).foregroundStyle(.primary)
                        Spacer()
                        Text("See all").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(Array(board.prefix(3).enumerated()), id: \.element.id) { i, s in
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(.subheadline.weight(.heavy))
                                .frame(width: 24, height: 24)
                                .background(i == 0 ? Color.sun : Color(.tertiarySystemFill), in: Circle())
                                .foregroundStyle(.black)
                            Avatar(session.person(s.id), fallback: s.name, size: 30)
                            Text(s.id == session.uid ? "You" : session.person(s.id)?.firstName ?? s.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(s.percent)%").font(.subheadline.weight(.bold))
                            Text("on time").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
            }
            .buttonStyle(.plain)
        }
    }
}

/// the whole board
struct BoardView: View {
    @Environment(Session.self) private var session

    var body: some View {
        let board = session.standings
        let ranked = board.filter { $0.hangouts > 0 }
        List {
            Section {
                ForEach(Array(board.enumerated()), id: \.element.id) { i, s in
                    HStack(spacing: 12) {
                        Text(s.hangouts > 0 ? "\(i + 1)" : "·").font(.headline.monospacedDigit()).frame(width: 26)
                            .foregroundStyle(i == 0 && s.hangouts > 0 ? Color.orange : Color.secondary)
                        Avatar(session.person(s.id), fallback: s.name, size: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.subheadline.weight(.semibold))
                            Text(s.hangouts == 0 ? "No check-ins yet" : "On time \(s.onTime) of \(s.hangouts) · \(usually(s))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let badge = badge(s, i, ranked.count) {
                                Text(badge).font(.caption2.weight(.bold))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Color.sun.opacity(0.3), in: Capsule())
                            }
                        }
                        Spacer()
                        if s.hangouts > 0 {
                            VStack(spacing: 0) {
                                Text("\(s.percent)%").font(.headline)
                                Text("on time").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .opensProfile(s.id)
                    .opacity(s.hangouts == 0 ? 0.55 : 1)
                }
            } footer: {
                Text("On time = there within 5 minutes of the start.")
            }
        }
        .navigationTitle("On-time board")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func usually(_ s: Standing) -> String {
        s.averageLate < -1 ? "usually \(Int((-s.averageLate).rounded())) min early"
            : s.averageLate <= 1 ? "usually right on time" : "usually \(Int(s.averageLate.rounded())) min late"
    }

    private func badge(_ s: Standing, _ i: Int, _ ranked: Int) -> String? {
        guard s.hangouts > 0 else { return nil }
        if i == 0 && s.percent >= 50 { return "👑 Most on time" }
        if i == ranked - 1 && ranked > 1 && s.percent < 50 { return "🐢 Always “omw”" }
        if s.trend < -1 { return "Getting better" }
        if s.trend > 1 { return "Slipping lately" }
        return nil
    }
}

// ---------- friends list ----------
/// someone's friends, like Instagram's list (yours, or a friend's: friends can see each other's lists)
struct FriendsListView: View {
    let uid: String
    @Environment(Session.self) private var session
    @State private var cards: [Card] = []
    @State private var query = ""
    @State private var loaded = false

    private var mine: Bool { uid == session.uid }
    private var shown: [Card] {
        let list = mine ? session.friends.map(Card.init(person:)) : cards
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? list : list.filter { "\($0.name) \($0.code)".lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(shown) { c in
                    // straight to their profile (a link that carries its own screen, so it can't open anything else)
                    NavigationLink { ProfileView(uid: c.id) } label: {
                        HStack(spacing: 12) {
                            Avatar(photo: c.photo, name: c.name, size: 50)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.handle).font(.subheadline.weight(.bold))
                                Text(c.name).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if c.id != session.uid, !session.isFriend(c.id) { FriendButton(uid: c.id, card: c) }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .overlay(alignment: .top) {
            if !mine && !loaded {
                VStack(spacing: 16) { ForEach(0..<4, id: \.self) { _ in PlaceholderRow(size: 50) } }.padding(16)
            } else if shown.isEmpty && query.isEmpty {
                ContentUnavailableView("No friends yet", systemImage: "person.2")
            }
        }
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: uid) {
            guard !mine else { return }
            session.db.collection("users").document(uid).collection("friends").getDocuments { snap, _ in
                MainActor.assumeIsolated {
                    let ids = snap?.documents.map(\.documentID) ?? []
                    session.cards(ids) { found in
                        cards = ids.compactMap { found[$0] }.filter { !$0.name.isEmpty || !$0.code.isEmpty }
                        loaded = true
                    }
                }
            }
        }
    }
}
