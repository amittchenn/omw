// A profile, like Instagram: picture, name and @username, counts, buttons, and their posts in a grid.
import SwiftUI

struct ProfileView: View {
    let uid: String
    @Environment(Session.self) private var session
    @State private var settings = false

    private var mine: Bool { uid == session.uid }
    private var person: Person? { session.person(uid) }
    private var posts: [Post] { session.posts.filter { $0.by == uid || $0.members.contains(uid) && mine } }
    /// hangouts you've been to together (yours: all of them)
    private var hangoutCount: Int { session.past.filter { $0.attendees.contains(uid) }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 22) {
                    Avatar(person, size: 88)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person?.name ?? "omw! user").font(.title2.weight(.bold))
                        if let code = person?.code, !code.isEmpty {
                            Text("@\(code.lowercased())").foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 28) {
                    stat(posts.count, posts.count == 1 ? "post" : "posts")
                    if mine { stat(session.friends.count, session.friends.count == 1 ? "friend" : "friends") }
                    if hangoutCount > 0 { stat(hangoutCount, hangoutCount == 1 ? "hangout" : "hangouts") }
                }
                buttons
                Divider()
                grid
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .navigationTitle(mine ? (person?.handle ?? "") : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mine {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "line.3.horizontal") }
                }
            }
        }
        .sheet(isPresented: $settings) { SettingsView() }
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(n)").font(.headline)
            Text(label).font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var buttons: some View {
        if mine {
            HStack(spacing: 8) {
                NavigationLink { ComingSoon(title: "Edit profile", symbol: "pencil") } label: { pill("Edit profile") }
                ShareLink(item: "Add me on omw! My friend ID is \(person?.code ?? "")") { pill("Share profile") }
            }
            .buttonStyle(.plain)
        } else if session.isFriend(uid) {
            HStack(spacing: 8) {
                pill("Friends", systemImage: "chevron.down")
                NavigationLink { ComingSoon(title: "Chats", symbol: "bubble.left.and.bubble.right") } label: { pill("Message") }
                    .buttonStyle(.plain)
            }
        }
    }

    private func pill(_ title: String, systemImage: String? = nil) -> some View {
        HStack(spacing: 4) {
            Text(title)
            if let systemImage { Image(systemName: systemImage).font(.caption.weight(.bold)) }
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 9))
    }

    @ViewBuilder private var grid: some View {
        if posts.isEmpty {
            ContentUnavailableView(mine ? "Share your first post" : "No posts yet", systemImage: "photo.on.rectangle.angled")
                .padding(.top, 40)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(posts) { post in
                    NavigationLink(value: PostRoute(id: post.id)) {
                        RemoteImage(source: post.allPhotos.first ?? "")
                            .aspectRatio(1, contentMode: .fill)
                            .overlay(alignment: .topTrailing) {
                                if post.allPhotos.count > 1 {
                                    Image(systemName: "square.fill.on.square.fill").font(.caption).foregroundStyle(.white).padding(6).shadow(radius: 2)
                                }
                            }
                    }
                }
            }
            .padding(.horizontal, -16)  // edge to edge, like Instagram
        }
    }
}

/// Settings (the ≡ on your profile). More of the web app's settings move here next.
struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    LabeledContent("Name", value: session.me?.name ?? "")
                    LabeledContent("Friend ID", value: session.me?.code ?? "")
                }
                Section {
                    Button("Sign out", role: .destructive) { dismiss(); session.signOut() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
