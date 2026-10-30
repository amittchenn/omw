// The home screen, like Instagram: your friends along the top (with who's out, on their way or free),
// then their posts. Likes, double-tap to like, and comments in a sheet.
import SwiftUI

struct FeedView: View {
    @Environment(Session.self) private var session
    @State private var commentsFor: Post?
    @State private var posting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    FriendsRow()
                        .padding(.vertical, 10)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("omw\(Text("!").foregroundStyle(Color.sun))")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink { AddFriendsView() } label: {
                        Image(systemName: "person.badge.plus")
                            .overlay(alignment: .topTrailing) {
                                if !session.incoming.isEmpty { Circle().fill(.red).frame(width: 9, height: 9).offset(x: 3, y: -2) }
                            }
                    }
                    Button { posting = true } label: { Image(systemName: "plus.app") }
                    NavigationLink { ComingSoon(title: "Chats", symbol: "bubble.left.and.bubble.right") } label: {
                        Image(systemName: "paperplane")
                    }
                }
            }
            .withProfileRoutes()
            .sheet(item: $commentsFor) { post in
                CommentsSheet(post: post)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .newPostFlow($posting)
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
        .confirmationDialog(freeTitle, isPresented: $askingFree, titleVisibility: .visible) {
            Button("For an hour") { session.setFree(hours: 1) }
            Button("Next 2 hours") { session.setFree(hours: 2) }
            if Calendar.current.component(.hour, from: .now) < 21 { Button("Tonight") { session.setFree(tonight: true) } }
            if session.me?.status == .free { Button("I'm not free anymore", role: .destructive) { session.setFree(hours: 0) } }
        } message: {
            Text(session.me?.status == .free ? "Change it, or turn it off." : "They'll see it over your picture, so they can ask you to hang out.")
        }
    }

    private var freeTitle: String {
        if session.me?.status == .free, let until = session.me?.freeUntil { return "You're free till \(until.formatted(date: .omitted, time: .shortened))" }
        return "Let friends know you're free"
    }

    /// "till 9", "till 5:15" (it's always within the next few hours, so no am/pm)
    static func till(_ date: Date) -> String {
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

    private var liked: Bool { session.uid.map { post.likes.contains($0) } ?? false }
    private var mine: Bool { post.by == session.uid }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            photos
            actions
            VStack(alignment: .leading, spacing: 6) {
                if !post.likes.isEmpty {
                    Text(post.likes.count == 1 ? "1 like" : "\(post.likes.count) likes").font(.subheadline.weight(.semibold))
                }
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
                    Text(post.venueName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Menu {
                if mine {
                    Button("Delete post", systemImage: "trash", role: .destructive) { session.deletePost(post) }
                } else {
                    Button("Hide", systemImage: "eye.slash") { withAnimation { session.hide(post) } }
                    Button("Report", systemImage: "exclamationmark.bubble", role: .destructive) { session.report(post) }
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
        HStack(spacing: 18) {
            Button { session.toggleLike(post) } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .foregroundStyle(liked ? Color.red : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .sensoryFeedback(.impact(weight: .light), trigger: liked)
            Button(action: onComments) { Image(systemName: "bubble.right") }
            Spacer()
        }
        .font(.system(size: 23))
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
            CommentsSheet(post: post).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
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
