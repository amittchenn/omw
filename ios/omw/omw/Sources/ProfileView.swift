// A profile, like Instagram: picture, name and @username, counts, buttons, and their posts in a grid.
import SwiftUI
import UIKit
import AuthenticationServices
import FirebaseAuth
internal import FirebaseFirestoreInternal

struct ProfileView: View {
    let uid: String
    @Environment(Session.self) private var session
    @State private var settings = false
    @State private var posting = false
    @State private var removing = false
    @State private var card: Card?  // for people who aren't your friends: their public card
    @State private var tab = Tab.posts
    @State private var friendCount = 0

    enum Tab: String, CaseIterable { case posts = "Posts", places = "Places", calendar = "Calendar" }

    private var mine: Bool { uid == session.uid }
    private var person: Person? { session.person(uid) }
    private var name: String { person?.name ?? card?.name ?? "omw! user" }
    private var code: String { person?.code ?? card?.code ?? "" }
    private var posts: [Post] { session.posts.filter { $0.by == uid || $0.members.contains(uid) && mine } }
    /// hangouts you've been to together (yours: all of them)
    private var hangoutCount: Int { session.past.filter { $0.attendees.contains(uid) }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 22) {
                    Avatar(photo: person?.photo ?? card?.photo ?? "", name: name, size: 88)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.title2.weight(.bold))
                        if !code.isEmpty {
                            Text("@\(code.lowercased())").foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 28) {
                    stat(posts.count, posts.count == 1 ? "post" : "posts")
                    if mine || session.isFriend(uid) {
                        NavigationLink { FriendsListView(uid: uid) } label: {
                            stat(mine ? session.friends.count : friendCount, (mine ? session.friends.count : friendCount) == 1 ? "friend" : "friends")
                        }
                        .buttonStyle(.plain)
                    }
                    if hangoutCount > 0 { stat(hangoutCount, hangoutCount == 1 ? "hangout" : "hangouts") }
                }
                buttons
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)
            if mine {
                tabs
                switch tab {
                case .posts: grid.padding(.top, 1.5)  // edge to edge, like Instagram
                case .places: PlacesList()
                case .calendar: MemoriesCalendar()
                }
            } else {
                Divider()
                grid.padding(.top, 1.5)
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle(mine ? (person?.handle ?? "") : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mine {
                ToolbarItem(placement: .topBarLeading) {
                    Button { posting = true } label: { Image(systemName: "plus.app") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "line.3.horizontal") }
                }
            }
        }
        .sheet(isPresented: $settings) { SettingsView() }
        .newPostFlow($posting)
        .confirmationDialog("Remove \(name.split(separator: " ").first.map(String.init) ?? name)?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { session.removeFriend(uid) }
        } message: {
            Text("You'll both need to add each other again to plan together and see friends-only posts.")
        }
        .task(id: uid) {
            if person == nil { session.cards([uid]) { card = $0[uid] } }
            if !mine, session.isFriend(uid) {
                session.db.collection("users").document(uid).collection("friends").getDocuments { snap, _ in
                    MainActor.assumeIsolated { friendCount = snap?.documents.count ?? 0 }
                }
            }
        }
    }

    /// Posts | Places | Calendar, underlined like Instagram's
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { withAnimation(.snappy(duration: 0.2)) { tab = t } } label: {
                    Label(t.rawValue, systemImage: t == .posts ? "square.grid.3x3" : t == .places ? "star" : "calendar")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(tab == t ? Color.primary : Color.clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
        .sensoryFeedback(.selection, trigger: tab)
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
                NavigationLink { EditProfileView() } label: { pill("Edit profile") }
                ShareLink(item: "Add me on omw! My username is @\(code.lowercased())") { pill("Share profile") }
            }
            .buttonStyle(.plain)
        } else if !session.isFriend(uid) {
            HStack { FriendButton(uid: uid, card: card ?? person.map { Card(person: $0) }); Spacer() }
        } else {
            HStack(spacing: 8) {
                Menu {
                    Button("Remove friend", systemImage: "person.badge.minus", role: .destructive) { removing = true }
                } label: { pill("Friends", systemImage: "chevron.down") }
                .buttonStyle(.plain)
                NavigationLink { DirectChat(uid: uid) } label: { pill("Message") }
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
            ContentUnavailableView {
                Label(mine ? "Share your first post" : session.isFriend(uid) || mine ? "No posts yet" : "Add them to see their posts",
                      systemImage: mine || session.isFriend(uid) ? "photo.on.rectangle.angled" : "lock")
            } actions: {
                if mine { Button("New post") { posting = true }.buttonStyle(.borderedProminent).tint(Color.primary) }
            }
            .padding(.top, 40)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1.5), count: 3), spacing: 1.5) {
                ForEach(posts) { post in
                    NavigationLink(value: PostRoute(id: post.id)) {
                        Color(.secondarySystemFill)
                            .aspectRatio(3 / 4, contentMode: .fit)  // portrait tiles, like the web app
                            .overlay { RemoteImage(source: post.allPhotos.first ?? "") }
                            .clipped()
                            .contentShape(Rectangle())
                            .overlay(alignment: .topTrailing) {
                                if post.allPhotos.count > 1 {
                                    Image(systemName: "square.fill.on.square.fill").font(.caption).foregroundStyle(.white).padding(6).shadow(radius: 2)
                                }
                            }
                    }
                }
            }
        }
    }
}

/// Settings (the ≡ on your profile). More of the web app's settings move here next.
struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var appleStep = false
    @State private var deleting = false
    @State private var problem: String?

    private var usesApple: Bool { session.user?.providerData.contains { $0.providerID == "apple.com" } ?? false }

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    NavigationLink { EditProfileView() } label: {
                        HStack(spacing: 12) {
                            Avatar(session.me, size: 44)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.me?.name ?? "").font(.headline)
                                Text("@\((session.me?.code ?? "").lowercased())").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Toggle("Private account", isOn: Binding(get: { !session.isPublic }, set: { session.setPublic(!$0) }))
                    if let blocked = session.me?.blocked, !blocked.isEmpty {
                        NavigationLink("Blocked (\(blocked.count))") { BlockedList() }
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(session.isPublic ? "Anyone on omw! can see your posts, name and picture." : "Only your friends can see your posts.")
                }
                Section {
                    ForEach(ShareMode.allCases) { mode in
                        Button { location.choose(mode) } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(mode.title).foregroundStyle(.primary)
                                    Text(mode.detail).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if location.mode == mode { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.omwBlue) }
                            }
                        }
                    }
                    if location.needsSettings {
                        Button("Allow in iPhone Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } header: {
                    Text("Share my location")
                } footer: {
                    Text(location.needsSettings
                         ? (location.mode == .always ? "iPhone Settings → omw! → Location → Always." : "iPhone Settings → omw! → Location → While Using the App.")
                         : "Only your friends can see it.")
                }
                Section {
                    Button("Sign out") { dismiss(); session.signOut() }
                }
                Section {
                    Button(deleting ? "Deleting…" : "Delete account", role: .destructive) { confirmDelete = true }
                        .disabled(deleting)
                } footer: {
                    Text("Deletes your profile, friends, plans you made, photos and messages for good.")
                }
                Section {
                    Link("Privacy Policy", destination: API.base.appending(path: "privacy"))
                    Link("Terms of Use", destination: API.base.appending(path: "terms"))
                    Link("Help", destination: API.base.appending(path: "support"))
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete your omw! account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) {
                    if usesApple { appleStep = true } else { delete(appleCode: nil) }
                }
            } message: {
                Text("Your profile, friends, plans you made, photos and messages are deleted for good. This can't be undone.")
            }
            .sheet(isPresented: $appleStep) { appleConfirm.presentationDetents([.height(240)]) }
            .alert("Couldn't delete your account", isPresented: .constant(problem != nil)) {
                Button("OK") { problem = nil }
            } message: { Text(problem ?? "") }
        }
    }

    /// Apple asks apps to cancel "Sign in with Apple" when you delete your account, which takes one more OK from Apple
    private var appleConfirm: some View {
        VStack(spacing: 16) {
            Text("Confirm with Apple").font(.headline)
            Text("One last step: Apple asks you to confirm so omw! can stop using your Apple sign-in.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = []
            } onCompletion: { result in
                appleStep = false
                if case .success(let auth) = result, let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                   let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }) {
                    delete(appleCode: code)
                }
            }
            .frame(height: 50)
            .clipShape(.rect(cornerRadius: 12))
        }
        .padding(24)
    }

    private func delete(appleCode: String?) {
        deleting = true
        Task {
            do {
                if let appleCode { try? await Auth.auth().revokeToken(withAuthorizationCode: appleCode) }
                try await API.post("/account/delete")
                dismiss()
                session.signOut()
            } catch {
                problem = error.localizedDescription
            }
            deleting = false
        }
    }
}

/// people you blocked: tap to unblock
struct BlockedList: View {
    @Environment(Session.self) private var session
    @State private var cards: [String: Card] = [:]

    var body: some View {
        List(session.me?.blocked ?? [], id: \.self) { id in
            HStack(spacing: 12) {
                Avatar(photo: cards[id]?.photo ?? "", name: cards[id]?.name ?? "?", size: 40)
                Text(cards[id]?.name ?? "Someone").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Unblock") { session.unblock(id) }.buttonStyle(.bordered)
            }
        }
        .navigationTitle("Blocked")
        .navigationBarTitleDisplayMode(.inline)
        .task { session.cards(session.me?.blocked ?? []) { cards = $0 } }
    }
}
