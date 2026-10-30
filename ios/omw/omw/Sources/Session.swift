// Who's signed in, and everything about them that stays live: your profile, your friends (and where they are),
// the feed, comments and your plans. Firestore listeners call back on the main thread, so the work runs there.
import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

@MainActor @Observable
final class Session {
    var user: User?
    var me: Person?
    var friends: [Person] = []
    var spots: [String: LiveSpot] = [:]
    var allPosts: [Post] = []
    var hangouts: [Hangout] = []
    var invites: [Hangout] = []          // plans you're asked to and haven't answered
    var comments: [String: [Comment]] = [:]
    var hidden: Set<String> = []
    var incoming: [FriendRequest] = []   // people who want to be your friend
    var outgoing: [String] = []          // people you asked
    var isPublic = true                  // your account: public (anyone sees your posts) or private (friends only)
    var chats: [Chat] = []               // DMs and group chats you're in
    var planMessages: [String: [ChatMessage]] = [:]  // each live plan's group chat (Chats.swift)
    var planSeen: [String: Date] = [:]   // when you last opened each plan's chat (kept on this phone)

    @ObservationIgnored let db = Firestore.firestore()
    @ObservationIgnored private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var stops: [ListenerRegistration] = []
    @ObservationIgnored private var friendStops: [String: [ListenerRegistration]] = [:]
    @ObservationIgnored private var friendsByID: [String: Person] = [:]
    @ObservationIgnored private var commentStops: [String: ListenerRegistration] = [:]
    @ObservationIgnored private var planChatStops: [String: ListenerRegistration] = [:]

    var uid: String? { user?.uid }

    init() {
        user = Auth.auth().currentUser
        if let user { start(user) }
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            MainActor.assumeIsolated {
                guard let self, user?.uid != self.listeningFor else { return }
                self.start(user)
            }
        }
    }

    // ---------- the feed ----------
    /// Friends' posts, newest first, without the ones you hid or from people you blocked
    var posts: [Post] {
        let blocked = Set(me?.blocked ?? [])
        return allPosts.filter { !hidden.contains($0.id) && !$0.members.contains(where: blocked.contains) }
    }

    func person(_ uid: String) -> Person? { uid == self.uid ? me : friends.first { $0.id == uid } }

    /// someone's @username: what the post remembers, else their profile, else their first name
    func handle(_ uid: String, in post: Post? = nil, name: String = "") -> String {
        if let h = post?.handles[uid], !h.isEmpty { return h }
        if let p = person(uid) { return p.handle }
        let n = name.isEmpty ? (post?.names[uid] ?? "friend") : name
        return (n.split(separator: " ").first.map(String.init) ?? n).lowercased()
    }

    func isFriend(_ uid: String) -> Bool { friends.contains { $0.id == uid } }

    func toggleLike(_ post: Post) {
        guard let uid, let i = allPosts.firstIndex(where: { $0.id == post.id }) else { return }
        let liked = allPosts[i].likes.contains(uid)
        if liked { allPosts[i].likes.removeAll { $0 == uid } } else { allPosts[i].likes.append(uid) }  // feels instant
        db.collection("feed").document(post.id).updateData(["likes": liked ? FieldValue.arrayRemove([uid]) : FieldValue.arrayUnion([uid])])
    }

    func deletePost(_ post: Post) {
        db.collection("feed").document(post.id).delete()
    }

    func hide(_ post: Post) { hidden.insert(post.id) }

    func report(_ post: Post) {
        guard let uid else { return }
        db.collection("reports").document("\(post.id)_\(uid)").setData(["post": post.id, "by": uid, "poster": post.by, "at": When.string(.now)])
    }

    // ---------- comments ----------
    func watchComments(_ postID: String) {
        guard commentStops[postID] == nil else { return }
        commentStops[postID] = db.collection("feed").document(postID).collection("comments")
            .order(by: "at").limit(to: 100)
            .addSnapshotListener { [weak self] snap, _ in
                MainActor.assumeIsolated {
                    guard let self, let snap else { return }
                    self.comments[postID] = snap.documents.map { Comment(id: $0.documentID, data: $0.data()) }
                }
            }
    }

    func addComment(_ text: String, to postID: String) {
        guard let uid else { return }
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard !text.isEmpty else { return }
        db.collection("feed").document(postID).collection("comments")
            .addDocument(data: ["from": uid, "name": String((me?.name ?? "").prefix(60)), "text": text, "at": When.string(.now)])
    }

    func deleteComment(_ comment: Comment, on postID: String) {
        db.collection("feed").document(postID).collection("comments").document(comment.id).delete()
    }

    func reportComment(_ comment: Comment, on postID: String) {
        guard let uid else { return }
        db.collection("reports").document("\(postID)_\(comment.id)_\(uid)")
            .setData(["post": postID, "comment": comment.id, "by": uid, "at": When.string(.now)])
    }

    // ---------- your plans ----------
    func hangout(_ id: String) -> Hangout? { hangouts.first { $0.id == id } ?? invites.first { $0.id == id } }
    var upcoming: [Hangout] { hangouts.filter { !$0.isOver }.sorted { $0.start < $1.start } }
    var past: [Hangout] { hangouts.filter(\.isOver).sorted { $0.start > $1.start } }

    func signOut() { try? Auth.auth().signOut() }

    // ---------- listening ----------
    @ObservationIgnored private var listeningFor: String?

    private func start(_ user: User?) {
        stopAll()
        self.user = user
        listeningFor = user?.uid
        guard let uid = user?.uid else { return }
        planSeen = (UserDefaults.standard.dictionary(forKey: "planSeen.\(uid)") as? [String: Double] ?? [:])
            .mapValues { Date(timeIntervalSince1970: $0) }

        // your profile (made the first time you sign in, like the web app does)
        let meRef = db.collection("users").document(uid)
        let firstName = user?.displayName ?? user?.email?.split(separator: "@").first.map(String.init) ?? "friend"
        stops.append(meRef.addSnapshotListener { [weak self] snap, _ in
            MainActor.assumeIsolated {
                guard let self, let snap else { return }
                if let data = snap.data() {
                    self.me = Person(id: uid, data: data)
                } else if !snap.metadata.isFromCache {
                    self.db.collection("users").document(uid).setData(["name": firstName, "travelMode": "driving", "shareLive": false], merge: true)
                }
            }
        })

        // your friends: their profiles and where they are
        stops.append(meRef.collection("friends").addSnapshotListener { [weak self] snap, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ids = Set(snap?.documents.map(\.documentID) ?? [])
                for (id, regs) in self.friendStops where !ids.contains(id) {
                    regs.forEach { $0.remove() }
                    self.friendStops[id] = nil; self.friendsByID[id] = nil; self.spots[id] = nil
                }
                for id in ids where self.friendStops[id] == nil { self.listenToFriend(id) }
                self.publishFriends()
            }
        })

        // the feed: everything you're allowed to see, newest first
        stops.append(db.collection("feed").whereField("viewers", arrayContains: uid)
            .order(by: "at", descending: true).limit(to: 60)
            .addSnapshotListener { [weak self] snap, _ in
                MainActor.assumeIsolated {
                    guard let self, let snap else { return }
                    self.allPosts = snap.documents.map { Post(id: $0.documentID, data: $0.data()) }
                }
            })

        // friend requests, both ways
        stops.append(db.collection("requests").whereField("to", isEqualTo: uid).addSnapshotListener { [weak self] snap, _ in
            MainActor.assumeIsolated {
                guard let self, let snap else { return }
                self.incoming = snap.documents.map { FriendRequest(data: $0.data()) }
            }
        })
        stops.append(db.collection("requests").whereField("from", isEqualTo: uid).addSnapshotListener { [weak self] snap, _ in
            MainActor.assumeIsolated {
                guard let self, let snap else { return }
                self.outgoing = snap.documents.compactMap { $0.data()["to"] as? String }
            }
        })
        // your public card: whether your account is public
        stops.append(db.collection("publicProfiles").document(uid).addSnapshotListener { [weak self] snap, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPublic = snap?.data()?["public"] as? Bool ?? false
            }
        })

        // plans you're asked to (and haven't said yes or no)
        stops.append(db.collection("hangouts").whereField("invited", arrayContains: uid)
            .addSnapshotListener { [weak self] snap, _ in
                MainActor.assumeIsolated {
                    guard let self, let snap else { return }
                    self.invites = snap.documents.map { Hangout(id: $0.documentID, data: $0.data()) }
                        .filter { !$0.attendees.contains(uid) && $0.rsvp[uid] == nil && !$0.isOver }
                        .sorted { $0.start < $1.start }
                }
            })

        // plans you're going to
        stops.append(db.collection("hangouts").whereField("attendees", arrayContains: uid)
            .addSnapshotListener { [weak self] snap, _ in
                MainActor.assumeIsolated {
                    guard let self, let snap else { return }
                    self.hangouts = snap.documents.map { Hangout(id: $0.documentID, data: $0.data()) }
                    self.listenToPlanChats()
                }
            })

        // your chats: DMs and groups
        stops.append(db.collection("chats").whereField("members", arrayContains: uid)
            .addSnapshotListener { [weak self] snap, _ in
                MainActor.assumeIsolated {
                    guard let self, let snap else { return }
                    self.chats = snap.documents.map { Chat(id: $0.documentID, data: $0.data()) }
                }
            })
    }

    /// every plan you're going to has a group chat until a day after it ends (like the web app's chat.js)
    private func listenToPlanChats() {
        let live = Set(hangouts.filter(\.chatOpen).map(\.id))
        for (id, stop) in planChatStops where !live.contains(id) { stop.remove(); planChatStops[id] = nil; planMessages[id] = nil }
        for id in live where planChatStops[id] == nil {
            planChatStops[id] = db.collection("hangouts").document(id).collection("messages")
                .addSnapshotListener { [weak self] snap, _ in
                    MainActor.assumeIsolated {
                        guard let self, let snap else { return }
                        self.planMessages[id] = snap.documents.map { ChatMessage(id: $0.documentID, data: $0.data()) }.sorted { $0.at < $1.at }
                    }
                }
        }
    }

    private func listenToFriend(_ id: String) {
        let profile = db.collection("users").document(id).addSnapshotListener { [weak self] snap, _ in
            MainActor.assumeIsolated {
                guard let self, let data = snap?.data() else { return }
                self.friendsByID[id] = Person(id: id, data: data)
                self.publishFriends()
            }
        }
        let location = db.collection("locations").document(id).addSnapshotListener { [weak self] snap, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let d = snap?.data()
                if let lat = (d?["lat"] as? NSNumber)?.doubleValue, let lng = (d?["lng"] as? NSNumber)?.doubleValue, let at = When.parse(d?["at"]) {
                    self.spots[id] = LiveSpot(lat: lat, lng: lng, at: at)
                } else {
                    self.spots[id] = nil
                }
            }
        }
        friendStops[id] = [profile, location]
    }

    /// friends out or on their way first, then free, then everyone else by name
    private func publishFriends() {
        let rank: (Person) -> Int = { p in
            switch p.status { case .out: 0; case .onTheWay: 1; case .free: 2; case .none: 3 }
        }
        friends = friendsByID.values.sorted { (rank($0), $0.name) < (rank($1), $1.name) }
    }

    private func stopAll() {
        stops.forEach { $0.remove() }; stops = []
        friendStops.values.flatMap { $0 }.forEach { $0.remove() }; friendStops = [:]
        commentStops.values.forEach { $0.remove() }; commentStops = [:]
        planChatStops.values.forEach { $0.remove() }; planChatStops = [:]
        chats = []; planMessages = [:]; planSeen = [:]
        friendsByID = [:]; friends = []; spots = [:]; allPosts = []; hangouts = []; comments = [:]; me = nil
        incoming = []; outgoing = []; invites = []
    }
}
