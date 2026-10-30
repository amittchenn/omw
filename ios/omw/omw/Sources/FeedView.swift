// The home screen, like Instagram: your friends along the top (with who's out, on their way or free),
// then their posts. Likes, double-tap to like, and comments in a sheet.
import SwiftUI

struct FeedView: View {
    @Environment(Session.self) private var session
    @State private var commentsFor: Post?
    @State private var posting = false
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
                    .padding(.bottom, 10)
                    Divider()
                    if session.posts.isEmpty {
                        ContentUnavailableView("No posts yet", systemImage: "photo.on.rectangle.angled",
                                               description: Text("When your friends share photos from their hangouts, they show up here."))
                            .padding(.top, 60)
                    }
                    ForEach(session.posts) { post in
                        PostCard(post: post) { commentsFor = post }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .planButton()
            .toolbar(.hidden, for: .navigationBar)  // our own header, like Instagram's (the bar's glass buttons squash the logo)
            // swipe in from the right edge for Chats, from the left edge for a new post, like Instagram
            .simultaneousGesture(
                DragGesture(minimumDistance: 20).onEnded { v in
                    let dx = v.translation.width, dy = v.translation.height, width = UIScreen.main.bounds.width
                    guard abs(dx) > 70, abs(dx) > abs(dy) * 1.8 else { return }
                    if dx < 0, v.startLocation.x > width - 44 { chatsOpen = true }
                    else if dx > 0, v.startLocation.x < 44 { posting = true }
                }
            )
            .navigationDestination(isPresented: $chatsOpen) { ChatsView() }
            .withProfileRoutes()
            .sheet(item: $commentsFor) { post in
                CommentsSheet(post: post).withOmw()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .newPostFlow($posting)
        }
    }
}

extension FeedView {
    /// omw! on the left; add friends, post and chats on the right, as plain icons (the web app's feed header)
    var header: some View {
        HStack(spacing: 2) {
            Text("omw\(Text("!").foregroundStyle(Color.sun))")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .tracking(-1)
            Spacer()
            NavigationLink { AddFriendsView() } label: { HeaderIcon(symbol: "person.badge.plus", count: session.incoming.count, dot: true) }
                .accessibilityLabel("Add friends")
            Button { posting = true } label: { HeaderIcon(symbol: "plus.app") }
                .accessibilityLabel("New post")
            NavigationLink { ChatsView() } label: { HeaderIcon(symbol: "bubble.left", count: session.unreadChats) }
                .accessibilityLabel("Chats")
        }
        .buttonStyle(.plain)
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 2)
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

/// Friends across the top, like stories: a colored ring when they're out (yellow), on their way (blue) or free (green).
/// Like Instagram's notes, a little bubble over a picture says until when they're free; tap yours to set it.
struct FriendsRow: View {
    @Environment(Session.self) private var session
    @State private var askingFree = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                if let me = session.me {
                    Button { askingFree = true } label: {
                        bubble(me, name: "You", note: me.status == .free ? me.freeUntil.map(Self.till) : "Free?", free: me.status == .free)
                    }
                    .accessibilityLabel(me.status == .free ? "Change when you're free" : "Let friends know you're free")
                }
                ForEach(session.friends) { f in
                    NavigationLink(value: ProfileRoute(uid: f.id)) {
                        bubble(f, name: f.firstName, note: f.status == .free ? f.freeUntil.map(Self.till) : nil, free: true,
                               status: f.status == .free ? "" : f.status.label)
                    }
                }
                NavigationLink { AddFriendsView() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "person.badge.plus").font(.title2)
                            .frame(width: 62, height: 62).background(Color(.secondarySystemBackground), in: Circle())
                        Text("Add friends").font(.caption.weight(.semibold))
                    }
                    .padding(.top, 20).frame(width: 74)
                }
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

    private var freeTitle: String {
        if session.me?.status == .free, let until = session.me?.freeUntil { return "You're free till \(until.formatted(date: .omitted, time: .shortened))" }
        return "Let friends know you're free"
    }

    /// "till 9", "till 5:15" (it's always within the next few hours, so no am/pm)
    nonisolated static func till(_ date: Date) -> String {
        let h = Calendar.current.component(.hour, from: date) % 12, m = Calendar.current.component(.minute, from: date)
        return "till \(h == 0 ? 12 : h)\(m == 0 ? "" : String(format: ":%02d", m))"
    }

    private func bubble(_ person: Person, name: String, note: String?, free: Bool, status: String = "") -> some View {
        VStack(spacing: 4) {
            Avatar(person, size: 62, showStatus: true)
                .overlay(alignment: .top) {
                    if let note {
                        Text(note)
                            .font(.caption2.weight(.heavy)).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .foregroundStyle(free && note != "Free?" ? Color.freeGreen : Color.secondary)
                            .background(.regularMaterial, in: Capsule())
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                            .offset(y: -16)
                    }
                }
            Text(name).font(.caption.weight(.semibold)).lineLimit(1)
            Text(status.isEmpty ? " " : status).font(.caption2.weight(.semibold))
                .foregroundStyle(person.status.color ?? .secondary).lineLimit(1)
        }
        .padding(.top, 20)
        .frame(width: 74)
    }
}

/// One post, like Instagram: who and where, the photos (swipe if there are several), like and comment,
/// the caption and the last comments.
struct PostCard: View {
    let post: Post
    var onComments: () -> Void
    @Environment(Session.self) private var session
    @State private var page = 0
    @State private var bigHeart = false
    @State private var rating = false

    private var liked: Bool { session.uid.map { post.likes.contains($0) } ?? false }

    /// a group photo says who was late (the latest one), or that everyone was on time
    private var lateBadge: (text: String, ok: Bool)? {
        guard let worst = post.late.max(by: { $0.value < $1.value }) else { return nil }
        if worst.value <= Session.lateAfterMinutes { return ("⚡ All on time", true) }
        let who = worst.key == session.uid ? "You" : session.person(worst.key)?.firstName ?? post.names[worst.key]?.split(separator: " ").first.map(String.init) ?? "Someone"
        let m = worst.value < 60 ? "\(Int(worst.value.rounded())) min" : "\(Int((worst.value / 60).rounded())) h"
        return ("\(who) \(m) late", false)
    }
    private var mine: Bool { post.by == session.uid }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            photos
            actions
            VStack(alignment: .leading, spacing: 6) {
                if !post.caption.isEmpty {
                    Text(line(session.handle(post.by, in: post), post.caption)).font(.subheadline)
                } else if post.isGroupPhoto, !post.title.isEmpty {
                    Text(post.title).font(.subheadline.weight(.semibold))
                }
                commentsPreview
                Text(When.ago(post.at)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 12)
        .onAppear { session.watchComments(post.id) }
        .sheet(isPresented: $rating) {
            RankSheet(place: RankedPlace(name: post.venueName, address: post.address, venue: post.venue), post: post.id)
                .withOmw().presentationDetents([.height(380)]).presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            NavigationLink(value: ProfileRoute(uid: post.by)) {
                Avatar(session.person(post.by), fallback: post.byName, size: 36)
            }
            VStack(alignment: .leading, spacing: 1) {
                NavigationLink(value: ProfileRoute(uid: post.by)) {
                    Text(session.handle(post.by, in: post)).font(.subheadline.weight(.semibold))
                }
                if !post.venueName.isEmpty {
                    HStack(spacing: 6) {
                        Text(post.venueName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let s = post.averageRating {
                            Text(String(format: "%.1f", s)).font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.freeGreen.opacity(0.2), in: Capsule())
                        }
                        if let late = lateBadge { Text(late.text).font(.caption2.weight(.bold)).foregroundStyle(late.ok ? Color.freeGreen : Color.orange) }
                    }
                }
            }
            Spacer()
            Menu {
                if mine {
                    Button("Delete post", systemImage: "trash", role: .destructive) { session.deletePost(post) }
                } else {
                    Button("Hide", systemImage: "eye.slash") { withAnimation(.snappy(duration: 0.25)) { session.hide(post) } }
                    Button("Report", systemImage: "exclamationmark.bubble", role: .destructive) { session.report(post) }
                    Button("Block \(session.handle(post.by, in: post))", systemImage: "hand.raised", role: .destructive) { session.block(post.by) }
                }
                if !post.venueName.isEmpty {
                    Button("Rate \(post.venueName)", systemImage: "star") { rating = true }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 36, height: 36)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
    }

    private var photos: some View {
        TabView(selection: $page) {
            ForEach(Array(post.allPhotos.enumerated()), id: \.offset) { i, photo in
                RemoteImage(source: photo).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: post.allPhotos.count > 1 ? .always : .never))
        .aspectRatio(4 / 5, contentMode: .fit)
        .background(Color(.secondarySystemBackground))
        .overlay {
            Image(systemName: "heart.fill")
                .font(.system(size: 96))
                .foregroundStyle(.white)
                .shadow(radius: 12)
                .scaleEffect(bigHeart ? 1 : 0.4)
                .opacity(bigHeart ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onTapGesture(count: 2) {  // double-tap to like, like Instagram
            if !liked { session.toggleLike(post) }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { bigHeart = true }
            Task { try? await Task.sleep(for: .milliseconds(650)); withAnimation(.easeOut(duration: 0.2)) { bigHeart = false } }
        }
    }

    private var actions: some View {
        let comments = session.comments[post.id]?.count ?? 0
        return HStack(spacing: 16) {
            Button { session.toggleLike(post) } label: {
                HStack(spacing: 5) {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .foregroundStyle(liked ? Color.red : Color.primary)
                        .contentTransition(.symbolEffect(.replace))
                    if !post.likes.isEmpty { Text("\(post.likes.count)").font(.subheadline.weight(.bold)) }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: liked)
            Button(action: onComments) {
                HStack(spacing: 5) {
                    Image(systemName: "message")
                    if comments > 0 { Text("\(comments)").font(.subheadline.weight(.bold)) }
                }
            }
            Spacer()
            if !post.venueName.isEmpty {
                Button { rating = true } label: { Image(systemName: "star") }
                    .accessibilityLabel("Rate \(post.venueName)")
            }
        }
        .font(.system(size: 22, weight: .medium))
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
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
                ContentUnavailableView("This post is gone", systemImage: "photo")
            }
        }
        .navigationTitle("Post")
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
                .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(Pressable())
        .foregroundStyle(.primary)
    }

    private func set(_ date: Date?) {
        session.setFree(until: date)
        dismiss()
    }
}
