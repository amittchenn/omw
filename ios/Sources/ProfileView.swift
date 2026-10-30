// A profile, like Instagram: picture, name and @username, counts, buttons, and their posts in a grid.
import SwiftUI
import UIKit
import AuthenticationServices
import FirebaseAuth
import FirebaseFirestore

struct ProfileView: View {
    let uid: String
    @Environment(Session.self) private var session
    @State private var settings = false
    @State private var posting = false
    @State private var removing = false
    @State private var card: Card?  // for people who aren't your friends: their public card
    @State private var tab = Tab.posts
    @State private var friendCount = 0

    enum Tab: String, CaseIterable { case posts = "Posts", places = "Places", memories = "Memories" }

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
                // omw!'s profile: how on time you are is the headline, not your post count
                HStack(spacing: 20) {
                    OnTimeRing(percent: onTime) {
                        Avatar(photo: person?.photo ?? card?.photo ?? "", name: name, size: 84)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.system(size: 24, weight: .heavy, design: .rounded))
                        if !code.isEmpty {
                            Text("@\(code.lowercased())").foregroundStyle(.secondary)
                        }
                        Text(punctuality.title)
                            .font(.footnote.weight(.bold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(punctuality.color.opacity(0.18), in: Capsule())
                            .foregroundStyle(punctuality.color)
                            .padding(.top, 2)
                    }
                }
                HStack(spacing: 0) {
                    stat(hangoutCount, hangoutCount == 1 ? "hangout" : "hangouts")
                    stat(onTime, "on time", suffix: "%")
                    if mine || session.isFriend(uid) {
                        NavigationLink { FriendsListView(uid: uid) } label: {
                            stat(mine ? session.friends.count : friendCount, (mine ? session.friends.count : friendCount) == 1 ? "friend" : "friends")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
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
                case .memories: MemoriesCalendar()
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
        .sheet(isPresented: $settings) { SettingsView().withOmw() }
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
                    Label(t.rawValue, systemImage: t == .posts ? "square.grid.3x3" : t == .places ? "star" : "photo.on.rectangle.angled")
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

    private func stat(_ n: Int?, _ label: String, suffix: String = "") -> some View {
        VStack(spacing: 1) {
            Text(n.map { "\($0)\(suffix)" } ?? "–").font(.system(size: 20, weight: .heavy, design: .rounded))
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// their spot on the on-time board (you and friends)
    private var standing: Standing? { session.standings.first { $0.id == uid } }
    /// how often they're on time, once they've checked in somewhere
    private var onTime: Int? { standing.flatMap { $0.hangouts > 0 ? $0.percent : nil } }

    /// a title from how on time they are, like a badge
    private var punctuality: (title: String, color: Color) {
        guard let s = standing, s.hangouts > 0 else { return ("🆕 New here", .secondary) }
        let p = "\(s.percent)% on time"
        switch s.percent {
        case 90...: return ("⏱️ Clockwork · \(p)", .freeGreen)
        case 70..<90: return ("⚡ Early bird · \(p)", .freeGreen)
        case 50..<70: return ("🙂 Mostly there · \(p)", .orange)
        case 25..<50: return ("🐢 Fashionably late · \(p)", .orange)
        default: return ("🌀 Chaos agent · \(p)", .red)
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

    @State private var privacyAsk: Bool?  // true: asking to go private, false: to go public

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
                Section("Privacy") {
                    // the switch asks first, like Instagram ("Switch to private account?")
                    Toggle(isOn: Binding(get: { !session.isPublic }, set: { privacyAsk = $0 })) {
                        Label("Private account", systemImage: "lock")
                    }
                    .tint(.green)
                    // where you are: chosen in the iPhone's Settings, like any Apple app
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        HStack {
                            Label("Location", systemImage: "location")
                            Spacer()
                            Text(location.mode == .always ? "Always" : location.mode == .never ? "Never" : "While Using")
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                    if let blocked = session.me?.blocked, !blocked.isEmpty {
                        NavigationLink { BlockedList() } label: {
                            HStack {
                                Label("Blocked", systemImage: "hand.raised")
                                Spacer()
                                Text("\(blocked.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("About") {
                    Link(destination: API.base.appending(path: "support")) { Label("Help", systemImage: "questionmark.circle") }
                    Link(destination: API.base.appending(path: "privacy")) { Label("Privacy Policy", systemImage: "hand.raised.square") }
                    Link(destination: API.base.appending(path: "terms")) { Label("Terms of Use", systemImage: "doc.text") }
                }
                .foregroundStyle(.primary)
                Section {
                    Button("Sign out") { dismiss(); session.signOut() }
                        .foregroundStyle(.primary)
                    Button(deleting ? "Deleting…" : "Delete account", role: .destructive) { confirmDelete = true }
                        .disabled(deleting)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog(privacyAsk == true ? "Switch to a private account?" : "Switch to a public account?",
                                isPresented: Binding(get: { privacyAsk != nil }, set: { if !$0 { privacyAsk = nil } }), titleVisibility: .visible) {
                Button(privacyAsk == true ? "Switch to private" : "Switch to public") {
                    if let p = privacyAsk { session.setPublic(!p) }
                    privacyAsk = nil
                }
            } message: {
                Text(privacyAsk == true ? "Only your friends will see your posts." : "Anyone on omw! will see your posts.")
            }
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

/// a ring around someone's picture that fills with how often they're on time (green), like an activity ring
struct OnTimeRing<Content: View>: View {
    let percent: Int?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(7)
            .overlay {
                Circle().stroke(Color(.tertiarySystemFill), lineWidth: 5)
                if let percent {
                    Circle()
                        .trim(from: 0, to: CGFloat(percent) / 100)
                        .stroke(percent >= 70 ? Color.freeGreen : percent >= 40 ? Color.orange : Color.red,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
    }
}
