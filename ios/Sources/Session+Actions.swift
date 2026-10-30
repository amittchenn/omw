// Adding friends and posting, on the same documents the web app uses (requests/, users/{uid}/friends/, feed/).
import UIKit
import CoreLocation
import FirebaseFirestore

extension Session {
    // ---------- friends ----------
    /// people whose username starts with what you typed (usernames are friend IDs, stored in capitals)
    func searchUsers(_ text: String, done: @escaping @MainActor ([Card]) -> Void) {
        let q = text.uppercased().replacingOccurrences(of: "@", with: "").filter { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !q.isEmpty else { done([]); return }
        db.collection("publicProfiles").whereField("code", isGreaterThanOrEqualTo: q).whereField("code", isLessThanOrEqualTo: q + "\u{f8ff}")
            .limit(to: 15)
            .getDocuments { [weak self] snap, _ in
                MainActor.assumeIsolated {
                    let blocked = Set(self?.me?.blocked ?? [])
                    done((snap?.documents ?? []).map { Card(id: $0.documentID, data: $0.data()) }.filter { !blocked.contains($0.id) && !$0.code.isEmpty })
                }
            }
    }

    /// Quick Add, like Snapchat: friends of your friends, most mutual friends first
    func quickAdd(done: @escaping @MainActor ([QuickAdd]) -> Void) {
        guard let uid else { done([]); return }
        let known = Set([uid] + friends.map(\.id) + outgoing)
        let asking = friends.prefix(40)
        guard !asking.isEmpty else { done([]); return }
        let tally = Tally(waiting: asking.count)
        for f in asking {
            db.collection("users").document(f.id).collection("friends").getDocuments { [weak self] snap, _ in
                MainActor.assumeIsolated {
                    for d in snap?.documents ?? [] where !known.contains(d.documentID) { tally.counts[d.documentID, default: 0] += 1 }
                    tally.waiting -= 1
                    guard tally.waiting == 0, let self else { return }
                    let top = tally.counts.sorted { $0.value > $1.value }.prefix(15)
                    self.cards(Array(top.map(\.key))) { cards in
                        // only people we can show (a card with a name or username)
                        done(top.compactMap { pair in cards[pair.key].flatMap { $0.name.isEmpty && $0.code.isEmpty ? nil : QuickAdd(card: $0, mutual: pair.value) } })
                    }
                }
            }
        }
    }

    /// public cards for these people
    func cards(_ ids: [String], done: @escaping @MainActor ([String: Card]) -> Void) {
        guard !ids.isEmpty else { done([:]); return }
        let tally = Tally(waiting: ids.count)
        for id in ids {
            db.collection("publicProfiles").document(id).getDocument { snap, _ in
                MainActor.assumeIsolated {
                    if let data = snap?.data() { tally.cards[id] = Card(id: id, data: data) }
                    tally.waiting -= 1
                    if tally.waiting == 0 { done(tally.cards) }
                }
            }
        }
    }

    func sendRequest(to card: Card) {
        guard let uid, let me else { return }
        outgoing.append(card.id)  // shows "Requested" right away
        db.collection("requests").document("\(uid)_\(card.id)").setData([
            "from": uid, "to": card.id, "fromName": String(me.name.prefix(60)), "fromPhoto": me.photo.count < 300_000 ? me.photo : "",
            "toName": card.name, "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    /// the database only allows these writes because their request to you exists
    func accept(_ request: FriendRequest) {
        guard let uid else { return }
        let batch = db.batch()
        batch.setData(["since": FieldValue.serverTimestamp()], forDocument: db.collection("users").document(uid).collection("friends").document(request.from))
        batch.setData(["since": FieldValue.serverTimestamp()], forDocument: db.collection("users").document(request.from).collection("friends").document(uid))
        batch.deleteDocument(db.collection("requests").document("\(request.from)_\(uid)"))
        batch.commit()
    }

    /// unfriending removes both sides (the web app does the same)
    func removeFriend(_ id: String) {
        guard let uid else { return }
        let batch = db.batch()
        batch.deleteDocument(db.collection("users").document(uid).collection("friends").document(id))
        batch.deleteDocument(db.collection("users").document(id).collection("friends").document(uid))
        batch.commit()
    }

    func decline(_ request: FriendRequest) {
        guard let uid else { return }
        db.collection("requests").document("\(request.from)_\(uid)").delete()
    }

    // ---------- plans: saying yes or no ----------
    /// Going: you join, and your own leave time is worked out from `from` (where you are, or home), like the web app.
    /// If the server can't be reached you still join; your alert just waits until it can be worked out.
    func accept(_ h: Hangout, from: CLLocationCoordinate2D?) async throws {
        guard let uid, let me else { return }
        var update: [String: Any] = ["attendees": FieldValue.arrayUnion([uid]), "rsvp.\(uid)": "going", "modes.\(uid)": me.travelMode]
        if let venue = h.venue, let from {
            let request = PlanRequest(user_ids: [uid], start_time: When.local.string(from: h.start), venue: [venue.latitude, venue.longitude],
                                      hangout_type: h.type,
                                      guests: [.init(user_id: uid, name: me.name, travel_mode: me.travelMode, home: [from.latitude, from.longitude], habits: me.habits)],
                                      utc_offset_min: TimeZone.current.secondsFromGMT(for: h.start) / 60, group_size: max(h.attendees.count + 1, 2))
            if let r = try? await API.send("/plan", request, as: [PlanResult].self).first, let leave = r.leaveAt {
                update["alerts.\(uid)"] = When.string(leave)
                update["travel.\(uid)"] = (r.travel_minutes * 10).rounded() / 10
            }
        }
        try await write(db.collection("hangouts").document(h.id), update)
    }

    /// Can't make it: you come off the plan and the others keep it. If nobody else is going or still deciding and it's
    /// yours, the plan goes away (only the planner may delete it).
    func cantMakeIt(_ h: Hangout) async throws {
        guard let uid else { return }
        let others = h.attendees.filter { $0 != uid }
        let deciding = h.invited.filter { $0 != uid && !h.attendees.contains($0) && h.rsvp[$0] == nil }
        let ref = db.collection("hangouts").document(h.id)
        if others.isEmpty, deciding.isEmpty, h.createdBy == uid {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                ref.delete { error in if let error { done.resume(throwing: error) } else { done.resume() } }
            }
            return
        }
        try await write(ref, ["attendees": FieldValue.arrayRemove([uid]), "rsvp.\(uid)": "declined"])
    }

    func write(_ ref: DocumentReference, _ update: [String: Any]) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            ref.updateData(update) { error in if let error { done.resume(throwing: error) } else { done.resume() } }
        }
    }

    // ---------- "I'm free" ----------
    /// free for the next `hours` (rounded up to a quarter hour), or tonight (till 11:59 pm); 0 hours turns it off
    func setFree(hours: Int = 0, tonight: Bool = false) {
        guard let uid else { return }
        let cal = Calendar.current
        var until: Date?
        if tonight {
            until = cal.date(bySettingHour: 23, minute: 59, second: 0, of: .now)
        } else if hours > 0 {
            let end = Date.now.addingTimeInterval(TimeInterval(hours) * 3600).timeIntervalSinceReferenceDate
            until = Date(timeIntervalSinceReferenceDate: (end / 900).rounded(.up) * 900)  // till 5:15, not 5:13
        }
        me?.freeUntil = until  // feels instant
        db.collection("users").document(uid).setData(["freeUntil": until.map { When.string($0) } ?? NSNull()], merge: true)
    }

    // ---------- posting ----------
    /// Shares a post with your friends (and everyone, if your account is public). Photos are stored as small JPEGs,
    /// like the web app: one photo up to ~280 KB, or 2 to 4 at ~155 KB each with a small cover for grids.
    func share(photos: [UIImage], caption: String, place: PlaceHit?, tagged: [String]) async throws {
        guard let uid, let me else { return }
        let many = photos.count > 1
        let encoded: [String] = await Task.detached(priority: .userInitiated) {
            photos.compactMap { Session.jpegDataURL($0, maxChars: many ? 210_000 : 380_000) }
        }.value
        guard encoded.count == photos.count, let first = photos.first else { throw API.Failure(message: "One of those photos is too big. Try another one.") }
        let cover = many ? await Task.detached { Session.jpegDataURL(first, maxChars: 60_000) }.value : encoded[0]
        guard let cover else { throw API.Failure(message: "That photo is too big. Try another one.") }

        var names = [uid: me.name]
        var handles = [uid: me.handle]
        for t in tagged { if let f = person(t) { names[t] = f.name; handles[t] = f.handle } }
        var doc: [String: Any] = [
            "kind": "post", "by": uid, "byName": me.name, "members": [uid], "names": names, "handles": handles, "tagged": tagged,
            "photo": cover, "caption": String(caption.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)), "at": When.string(.now),
            "venueName": String((place?.name ?? "").prefix(120)), "address": place?.address ?? "",
            "likes": [String](), "ratings": [String: Double](), "public": isPublic, "viewers": [uid] + friends.map(\.id),
        ]
        if many { doc["photos"] = encoded }
        if let lat = place?.lat, let lng = place?.lng { doc["venue"] = [lat, lng] } else { doc["venue"] = NSNull() }
        let feed = db.collection("feed")
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            _ = feed.addDocument(data: doc) { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
        }
    }

    /// a photo as a JPEG data URL under `maxChars`, at most 1080 px, smaller and softer until it fits
    nonisolated static func jpegDataURL(_ image: UIImage, maxChars: Int) -> String? {
        for (side, quality) in [(1080.0, 0.8), (960, 0.74), (800, 0.7), (640, 0.66), (520, 0.62)] {
            let k = min(1, side / max(image.size.width, image.size.height))
            let size = CGSize(width: (image.size.width * k).rounded(), height: (image.size.height * k).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            guard let data = small.jpegData(compressionQuality: quality) else { continue }
            let url = "data:image/jpeg;base64," + data.base64EncodedString()
            if url.count < maxChars { return url }
        }
        return nil
    }
}

/// someone you might know, and how many friends you have in common
struct QuickAdd: Identifiable {
    let card: Card
    let mutual: Int
    var id: String { card.id }
}

/// counting answers that come back one by one
@MainActor final class Tally {
    var waiting: Int
    var counts: [String: Int] = [:]
    var cards: [String: Card] = [:]
    init(waiting: Int) { self.waiting = waiting }
}
