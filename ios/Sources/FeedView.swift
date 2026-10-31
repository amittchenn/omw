// The home screen: omw! and how the night's going, who's around (status pills), what's up next, then everyone's
// memories as ticket stubs from their hangouts (who showed up when, high-fives, comments).
import SwiftUI

struct FeedView: View {
    @Environment(Session.self) private var session
    @State private var commentsFor: Post?
    @State private var chatsOpen = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                    FriendsRow()
                        .padding(.vertical, 10)
                    VStack(spacing: 10) {
                        if let next = session.upNext { UpNextCard(hangout: next) }
                        BoardCard()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    if session.posts.isEmpty {
                        VStack(spacing: 8) {
                            Ticki(mood: .wave, lines: ["Hi, I'm Ticki!", "Add friends to fill this up", "Then make a plan with the ＋"]).frame(width: 130, height: 130)
                            Text("Nothing here yet").font(.headline)
                            Text("Hang out and share the photo.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.top, 50)
                    }
                    ForEach(session.posts) { post in
                        PostCard(post: post) { commentsFor = post }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)  // our own header, like Instagram's (the bar's glass buttons squash the logo)
            .omwBackground()
            // swipe in from the very right edge for Chats, like Instagram. Only a thin strip at the screen's edge listens,
            // so scrolling the friends row or a memory's photos never opens it.
            .overlay(alignment: .trailing) { edgeSwipe(left: false) }
            .navigationDestination(isPresented: $chatsOpen) { ChatsView() }
            .withProfileRoutes()
            .sheet(item: $commentsFor) { post in
                CommentsSheet(post: post).withOmw()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

extension FeedView {
    /// omw! on the left; add friends and chats on the right, as plain icons. (No "new post": what you share on omw! is
    /// the group photo from a hangout, so the feed is everyone's memories.)
    var header: some View {
        HStack(alignment: .center, spacing: 2) {
            VStack(alignment: .leading, spacing: 0) {
                Text("omw\(Text("!").foregroundStyle(Color.sun))")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .tracking(-1)
                Text(pulse).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            NavigationLink { AddFriendsView() } label: { HeaderIcon(symbol: "person.badge.plus", count: session.incoming.count, dot: true) }
                .accessibilityLabel("Add friends")
            NavigationLink { ChatsView() } label: { HeaderIcon(symbol: "bubble.left", count: session.unreadChats) }
                .accessibilityLabel("Chats")
        }
        .buttonStyle(.plain)
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 2)
    }

    /// a live line under the logo: "Saturday night · 2 friends free"
    private var pulse: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 5 ? "late night" : hour < 12 ? "morning" : hour < 17 ? "afternoon" : "night"
        let day = Date.now.formatted(.dateTime.weekday(.wide))
        let free = session.friends.filter { $0.status == .free }.count
        let out = session.friends.filter { $0.status == .out || $0.status == .onTheWay }.count
        let what = free > 0 ? "\(free) free" : out > 0 ? "\(out) out" : "quiet so far"
        return "\(day) \(part) · \(what)"
    }

    /// a thin, invisible strip at the right screen edge that turns a swipe inward into Chats
    private func edgeSwipe(left: Bool) -> some View {
        Color.clear
            .frame(width: 14)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 15).onEnded { v in
                let dx = v.translation.width
                guard abs(dx) > 60, abs(dx) > abs(v.translation.height) * 1.5 else { return }
                if !left, dx < 0 { chatsOpen = true }
            })
    }
}

/// a header button: the icon, with a red dot or count when something's waiting
struct HeaderIcon: View {
    let symbol: String
    var count = 0
    var dot = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .regular))
            .frame(width: 42, height: 42)
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    if dot {
                        Circle().fill(.red).frame(width: 9, height: 9).offset(x: -6, y: 8)
                    } else {
                        Text("\(count)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17)
                            .background(Color.red, in: Capsule()).offset(x: -2, y: 4)
                    }
                }
            }
    }
}

/// Who's around, as a strip of status pills (not story circles): you first ("Free?" or "Free till 9", tap to set it),
/// then friends who are out, on their way or free first (with what they're up to), then everyone else, and Add.
struct FriendsRow: View {
    @Environment(Session.self) private var session
    @State private var askingFree = false

    private var sorted: [Person] {
        func rank(_ p: Person) -> Int { switch p.status { case .free: 0; case .onTheWay: 1; case .out: 2; case .none: 3 } }
        return session.friends.sorted { (rank($0), $0.firstName) < (rank($1), $1.firstName) }
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if let me = session.me {
                    Button { askingFree = true } label: {
                        pill(me, name: "You", text: me.status == .free ? (me.freeUntil.map { "Free \(Self.till($0))" } ?? "Free") : "Free?",
                             tint: me.status == .free ? .freeGreen : nil, mine: true)
                    }
                    .accessibilityLabel(me.status == .free ? "Change when you're free" : "Let friends know you're free")
                }
                ForEach(sorted) { f in
                    NavigationLink(value: ProfileRoute(uid: f.id)) {
                        pill(f, name: f.firstName, text: status(f), tint: f.status.color)
                    }
                }
                NavigationLink { AddFriendsView() } label: {
                    Image(systemName: "plus").font(.subheadline.weight(.bold))
                        .frame(width: 40, height: 40)
                        .background(Color.omwCard, in: Circle())
                }
                .accessibilityLabel("Add friends")
            }
            .padding(.horizontal, 14)
        }
        .scrollIndicators(.hidden)
        .buttonStyle(.plain)
        .sheet(isPresented: $askingFree) {
            FreeSheet().withOmw()
                .presentationDragIndicator(.visible)
        }
    }

    private func status(_ f: Person) -> String? {
        switch f.status {
        case .free: f.freeUntil.map { "Free \(Self.till($0))" } ?? "Free"
        case .none: nil
        default: f.status.label
        }
    }

    /// a face and a name, and what they're up to in their color: one pill
    private func pill(_ person: Person, name: String, text: String?, tint: Color?, mine: Bool = false) -> some View {
        HStack(spacing: 8) {
            Avatar(person, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.subheadline.weight(.bold)).lineLimit(1)
                if let text {
                    Text(text).font(.caption.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(tint ?? .secondary)
                }
            }
        }
        .padding(.leading, 5).padding(.trailing, 14)
        .frame(height: 40)
        .background(Color.omwCard, in: Capsule())
        .overlay(Capsule().strokeBorder(tint?.opacity(0.7) ?? (mine ? Color.sun.opacity(0.8) : .clear), lineWidth: 1.5))
    }

    private var freeTitle: String {
        if session.me?.status == .free, let until = session.me?.freeUntil { return "You're free till \(until.formatted(date: .omitted, time: .shortened))" }
        return "Let friends know you're free"
    }

    /// "till 9", "till 5:15" (it's always within the next few hours, so no am/pm)
    nonisolated static func till(_ date: Date) -> String {
        let h = Calendar.current.component(.hour, from: date) % 12, m = Calendar.current.component(.minute, from: date)
        return "till \(h == 0 ? 12 : h)\(m == 0 ? "" : String(format: ":%02d", m))"
    }

}

/// A memory, as a ticket stub from the hangout (not an Instagram post): what and where on top, the group photo with
/// a stamp ("ALL ON TIME" or who was late), who showed up in the order they arrived, a perforated tear line, then
/// high-fives (double-tap the photo too), comments and the place's stars.
struct PostCard: View {
    let post: Post
    var onComments: () -> Void
    @Environment(Session.self) private var session
    @State private var page = 0
    @State private var bigClap = false
    @State private var rating = false

    private var liked: Bool { session.uid.map { post.likes.contains($0) } ?? false }
    private var mine: Bool { post.by == session.uid }

    /// the stamp: everyone on time, or the latest one
    private var stamp: (text: String, ok: Bool)? {
        guard let worst = post.late.max(by: { $0.value < $1.value }) else { return nil }
        if worst.value <= Session.lateAfterMinutes { return ("ALL ON TIME", true) }
        let m = worst.value < 60 ? "+\(Int(worst.value.rounded())) MIN" : "+\(Int((worst.value / 60).rounded())) H"
        return ("\(first(worst.key).uppercased()) \(m)", false)
    }

    private func first(_ uid: String) -> String {
        uid == session.uid ? "You" : session.person(uid)?.firstName ?? post.names[uid]?.split(separator: " ").first.map(String.init) ?? "Friend"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            top
            photos.padding(.horizontal, 10)
            if !post.late.isEmpty { arrivals }
            if !post.caption.isEmpty {
                Text(line(session.handle(post.by, in: post), post.caption)).font(.subheadline).padding(.horizontal, 16)
            }
            TearLine()
            bottom
            commentsPreview.padding(.horizontal, 16)
        }
        .padding(.vertical, 14)
        .background(Color.omwCard, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .onAppear { session.watchComments(post.id) }
        .sheet(isPresented: $rating) {
            RankSheet(place: RankedPlace(name: post.venueName, address: post.address, venue: post.venue), post: post.id)
                .withOmw().presentationDetents([.height(380)]).presentationDragIndicator(.visible)
        }
    }

    // ---------- the stub: what, where, when ----------
    private var top: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(post.title.isEmpty ? (post.venueName.isEmpty ? "A hangout" : post.venueName) : post.title)
                    .font(.system(size: 19, weight: .heavy, design: .rounded)).lineLimit(2)
                HStack(spacing: 6) {
                    Text([post.title.contains(post.venueName) ? "" : post.venueName, post.at.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .lineLimit(1)
                    if let s = post.averageRating {
                        Label(String(format: "%.1f", s / 2), systemImage: "star.fill").labelStyle(.titleAndIcon).foregroundStyle(Color.sun)
                    }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            menu
        }
        .padding(.horizontal, 16)
    }

    private var menu: some View {
        Menu {
            if mine {
                Button("Delete memory", systemImage: "trash", role: .destructive) { session.deletePost(post) }
            } else {
                Button("Hide", systemImage: "eye.slash") { withAnimation(.snappy(duration: 0.25)) { session.hide(post) } }
                Button("Report", systemImage: "exclamationmark.bubble", role: .destructive) { session.report(post) }
                Button("Block \(session.handle(post.by, in: post))", systemImage: "hand.raised", role: .destructive) { session.block(post.by) }
            }
            if !post.venueName.isEmpty {
                Button("Rate \(post.venueName)", systemImage: "star") { rating = true }
            }
        } label: {
            Image(systemName: "ellipsis").font(.headline).frame(width: 32, height: 32).foregroundStyle(.secondary)
        }
    }

    // ---------- the photo, with its stamp ----------
    private var photos: some View {
        TabView(selection: $page) {
            ForEach(Array(post.allPhotos.enumerated()), id: \.offset) { i, photo in
                RemoteImage(source: photo).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: post.allPhotos.count > 1 ? .always : .never))
        .aspectRatio(4 / 5, contentMode: .fit)
        .background(Color.omwCard2)
        .clipShape(.rect(cornerRadius: 18))
        .overlay(alignment: .topTrailing) {
            if let stamp {
                Text(stamp.text)
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .tracking(1)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(stamp.ok ? Color.freeGreen : Color.orange)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(stamp.ok ? Color.freeGreen : Color.orange, lineWidth: 2))
                    .rotationEffect(.degrees(-8))
                    .padding(14)
            }
        }
        .overlay {
            Image(systemName: "hands.clap.fill")
                .font(.system(size: 90))
                .foregroundStyle(Color.sun)
                .shadow(radius: 12)
                .scaleEffect(bigClap ? 1 : 0.4)
                .opacity(bigClap ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onTapGesture(count: 2) {  // double-tap for a high five
            if !liked { session.toggleLike(post) }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { bigClap = true }
            Task { try? await Task.sleep(for: .milliseconds(650)); withAnimation(.easeOut(duration: 0.2)) { bigClap = false } }
        }
    }

    // ---------- who showed up, in the order they arrived ----------
    private var arrivals: some View {
        let order = post.members.sorted { (post.late[$0] ?? .infinity) < (post.late[$1] ?? .infinity) }
        return ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(order, id: \.self) { u in
                    let late = post.late[u]
                    VStack(spacing: 3) {
                        Avatar(session.person(u), fallback: post.names[u] ?? "", size: 30)
                        Text(first(u)).font(.caption2.weight(.semibold)).lineLimit(1)
                        Text(late.map { $0 <= Session.lateAfterMinutes ? "on time" : "+\(Int($0.rounded()))m" } ?? "–")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(late.map { $0 <= Session.lateAfterMinutes ? Color.freeGreen : Color.orange } ?? Color.secondary)
                    }
                    .frame(minWidth: 44)
                    .opensProfile(u)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    // ---------- high-fives, comments, stars, who took it ----------
    private var bottom: some View {
        let comments = session.comments[post.id]?.count ?? 0
        return HStack(spacing: 18) {
            Button { session.toggleLike(post) } label: {
                HStack(spacing: 5) {
                    Image(systemName: liked ? "hands.clap.fill" : "hands.clap")
                        .foregroundStyle(liked ? Color.sun : Color.primary)
                        .contentTransition(.symbolEffect(.replace))
                    if !post.likes.isEmpty { Text("\(post.likes.count)").font(.subheadline.weight(.bold)) }
                }
            }
            .accessibilityLabel(liked ? "Take back your high five" : "High five")
            .sensoryFeedback(.impact(weight: .light), trigger: liked)
            Button(action: onComments) {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left")
                    if comments > 0 { Text("\(comments)").font(.subheadline.weight(.bold)) }
                }
            }
            if !post.venueName.isEmpty {
                Button { rating = true } label: { Image(systemName: "star") }
                    .accessibilityLabel("Rate \(post.venueName)")
            }
            Spacer()
            NavigationLink(value: ProfileRoute(uid: post.by)) {
                Text("📸 \(first(post.by)) · \(When.ago(post.at))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 20, weight: .medium))
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var commentsPreview: some View {
        let list = session.comments[post.id] ?? []
        if list.count > 2 {
            Button("View all \(list.count) comments", action: onComments)
                .font(.subheadline).foregroundStyle(.secondary).buttonStyle(.plain)
        }
        ForEach(list.suffix(2)) { c in
            Text(line(session.handle(c.from, name: c.name), c.text)).font(.subheadline).lineLimit(2)
                .onTapGesture(perform: onComments)
        }
    }
}

/// a ticket's perforated tear line: a dashed rule with a notch cut into each side
struct TearLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(Color.omwBG).frame(width: 18, height: 18).offset(x: -9)
            Line().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 5])).foregroundStyle(Color(.separator)).frame(height: 1)
            Circle().fill(Color.omwBG).frame(width: 18, height: 18).offset(x: 9)
        }
        .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in r: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: 0, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); return p }
    }
}

/// "username the text", with the username in bold (the text is shown as typed, never as formatting)
func line(_ name: String, _ text: String) -> AttributedString {
    var bold = AttributedString(name)
    bold.font = .subheadline.weight(.semibold)
    return bold + AttributedString(" " + text)
}

/// A post on its own (from a profile's grid)
struct PostDetailView: View {
    let id: String
    @Environment(Session.self) private var session
    @State private var commentsFor: Post?

    var body: some View {
        ScrollView {
            if let post = session.allPosts.first(where: { $0.id == id }) {
                PostCard(post: post) { commentsFor = post }
            } else {
                ContentUnavailableView("This memory is gone", systemImage: "photo")
            }
        }
        .navigationTitle("Memory")
        .omwBackground()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $commentsFor) { post in
            CommentsSheet(post: post).withOmw().presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }
}

/// A screen that's on its way from the web version
struct ComingSoon: View {
    let title: String
    let symbol: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text("Coming to the new app soon. It works in the current omw! app for now."))
            .navigationTitle(title)
            .omwBackground()
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// "I'm free": for how long, so friends can ask you to hang out (it shows over your picture)
struct FreeSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var until = Date.now.addingTimeInterval(3 * 3600)

    private var free: Bool { session.me?.status == .free }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(free ? "Free till \(session.me?.freeUntil?.formatted(date: .omitted, time: .shortened) ?? "")" : "I'm free")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .padding(.top, 24)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                choice("30 min") { set(Date.now.addingTimeInterval(30 * 60)) }
                choice("1 hour") { set(Date.now.addingTimeInterval(3600)) }
                choice("2 hours") { set(Date.now.addingTimeInterval(2 * 3600)) }
                choice("3 hours") { set(Date.now.addingTimeInterval(3 * 3600)) }
                if Calendar.current.component(.hour, from: .now) < 22 {
                    choice("Tonight") { set(Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: .now)) }
                }
                choice("Pick a time") { withAnimation(.snappy(duration: 0.2)) { picking.toggle() } }
            }
            if picking {
                HStack {
                    DatePicker("Free till", selection: $until, in: Date.now.addingTimeInterval(15 * 60)..., displayedComponents: [.hourAndMinute])
                        .font(.subheadline.weight(.semibold))
                    Button("Set") { set(until) }.buttonStyle(.borderedProminent).tint(Color.freeGreen)
                }
            }
            if free {
                Button("I'm not free anymore", role: .destructive) { set(nil) }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .presentationDetents([.height(picking || free ? 400 : 320)])  // just as tall as what's in it
    }

    private func choice(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.omwCard2, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(Pressable())
        .foregroundStyle(.primary)
    }

    private func set(_ date: Date?) {
        session.setFree(until: date)
        dismiss()
    }
}
