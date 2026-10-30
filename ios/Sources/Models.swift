// What's in the database (the same documents the web app reads and writes; see web/feed.js and web/friends.js).
import Foundation
import CoreLocation
import FirebaseFirestore

/// users/{uid}: a person's profile. Friends can read it; their live location is in locations/{uid}.
struct Person: Identifiable, Equatable {
    let id: String
    var name: String
    var photo: String
    var code: String          // their friend ID, shown as @username in lowercase
    var freeUntil: Date?
    var nowKind: String?      // "out" at a hangout, or on their way
    var nowUntil: Date?
    var blocked: [String]
    var shareMode: ShareMode
    var travelMode: String       // driving, walking, cycling or transit
    var home: CLLocationCoordinate2D?
    var habits: [Double]         // minutes after their alert they really left, from their check-ins (the model learns them)

    init(id: String, data: [String: Any]) {
        self.id = id
        shareMode = ShareMode(rawValue: data["shareMode"] as? String ?? "") ?? (data["shareLive"] as? Bool == false ? .never : .whileUsing)
        name = data["name"] as? String ?? "Friend"
        photo = Self.safePhoto(data["photo"] as? String)
        code = data["code"] as? String ?? ""
        freeUntil = When.parse(data["freeUntil"])
        let now = data["now"] as? [String: Any]
        nowKind = now?["kind"] as? String
        nowUntil = When.parse(now?["until"])
        blocked = data["blocked"] as? [String] ?? []
        travelMode = data["travelMode"] as? String ?? "driving"
        if let h = data["home"] as? [String: Any], let lat = (h["lat"] as? NSNumber)?.doubleValue, let lng = (h["lng"] as? NSNumber)?.doubleValue {
            home = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        habits = Array((data["habits"] as? [[String: Any]] ?? []).compactMap { ($0["delay"] as? NSNumber)?.doubleValue }.suffix(30))
    }

    static func == (a: Person, b: Person) -> Bool {
        a.id == b.id && a.name == b.name && a.photo == b.photo && a.code == b.code && a.freeUntil == b.freeUntil
            && a.nowKind == b.nowKind && a.nowUntil == b.nowUntil && a.blocked == b.blocked && a.shareMode == b.shareMode
            && a.travelMode == b.travelMode && a.habits == b.habits
    }

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
    var handle: String { code.isEmpty ? firstName.lowercased() : code.lowercased() }

    enum Status { case out, onTheWay, free, none }
    var status: Status {
        if let until = nowUntil, until > .now { return nowKind == "out" ? .out : .onTheWay }
        if let free = freeUntil, free > .now { return .free }
        return .none
    }

    /// Only pictures we can show safely: https links or JPEG/PNG/WebP data.
    static func safePhoto(_ s: String?) -> String {
        guard let s else { return "" }
        return s.hasPrefix("https://") || s.hasPrefix("data:image/jpeg") || s.hasPrefix("data:image/png") || s.hasPrefix("data:image/webp") ? s : ""
    }
}

/// Sharing your location with friends, like Apple's own choices: never, while you're using omw!, or always
/// (in the background too, so you're checked in when you arrive even with omw! closed). users/{uid}.shareMode;
/// the web app reads users/{uid}.shareLive (on unless "never").
enum ShareMode: String, CaseIterable, Identifiable {
    case never, whileUsing = "using", always
    var id: String { rawValue }
    var title: String {
        switch self { case .never: "Never"; case .whileUsing: "While using the app"; case .always: "Always" }
    }
    var detail: String {
        switch self {
        case .never: "Friends don't see where you are. You check in with “I'm here”."
        case .whileUsing: "Friends see you on the map while omw! is open."
        case .always: "Friends see roughly where you are, and you're checked in when you arrive, even with omw! closed."
        }
    }
}

/// feed/{id}: a post (kind "post") or a group photo from a hangout.
struct Post: Identifiable, Equatable {
    let id: String
    var kind: String
    var by: String
    var byName: String
    var members: [String]
    var names: [String: String]
    var handles: [String: String]
    var photo: String
    var photos: [String]
    var caption: String
    var title: String
    var at: Date
    var venueName: String
    var address: String
    var likes: [String]
    var tagged: [String]
    var isPublic: Bool
    var venue: [Double]   // [lat, lng] of the place, if there is one

    init(id: String, data: [String: Any]) {
        self.id = id
        kind = data["kind"] as? String ?? ""
        by = data["by"] as? String ?? ""
        byName = data["byName"] as? String ?? ""
        members = data["members"] as? [String] ?? []
        names = data["names"] as? [String: String] ?? [:]
        handles = data["handles"] as? [String: String] ?? [:]
        photo = Person.safePhoto(data["photo"] as? String)
        photos = (data["photos"] as? [String] ?? []).map { Person.safePhoto($0) }.filter { !$0.isEmpty }
        caption = data["caption"] as? String ?? ""
        title = data["title"] as? String ?? ""
        at = When.parse(data["at"]) ?? .distantPast
        venueName = data["venueName"] as? String ?? ""
        address = data["address"] as? String ?? ""
        likes = data["likes"] as? [String] ?? []
        tagged = data["tagged"] as? [String] ?? []
        isPublic = data["public"] as? Bool ?? false
        venue = (data["venue"] as? [NSNumber] ?? []).map(\.doubleValue)
    }

    var isGroupPhoto: Bool { kind != "post" }
    var allPhotos: [String] { photos.count > 1 ? photos : [photo].filter { !$0.isEmpty } }
}

/// feed/{post}/comments/{id}
struct Comment: Identifiable, Equatable {
    let id: String
    var from: String
    var name: String
    var text: String
    var at: Date

    init(id: String, data: [String: Any]) {
        self.id = id
        from = data["from"] as? String ?? ""
        name = data["name"] as? String ?? ""
        text = data["text"] as? String ?? ""
        at = When.parse(data["at"]) ?? .distantPast
    }
}

/// requests/{from}_{to}: someone asking to be friends
struct FriendRequest: Identifiable, Equatable {
    var from: String
    var to: String
    var fromName: String
    var fromPhoto: String
    var id: String { from }

    init(data: [String: Any]) {
        from = data["from"] as? String ?? ""
        to = data["to"] as? String ?? ""
        fromName = data["fromName"] as? String ?? "Someone"
        fromPhoto = Person.safePhoto(data["fromPhoto"] as? String)
    }
}

/// publicProfiles/{uid}: what anyone signed in can see about someone (for search and Add friends)
struct Card: Identifiable, Equatable {
    let id: String
    var name: String
    var photo: String
    var code: String
    var handle: String { code.isEmpty ? (name.split(separator: " ").first.map(String.init) ?? name).lowercased() : code.lowercased() }

    init(id: String, data: [String: Any]) {
        self.id = id
        name = data["name"] as? String ?? ""
        photo = Person.safePhoto(data["photo"] as? String)
        code = data["code"] as? String ?? ""
    }

    init(person: Person) {
        id = person.id; name = person.name; photo = person.photo; code = person.code
    }
}

/// hangouts/{id}: a plan.
struct Hangout: Identifiable, Equatable {
    let id: String
    var title: String
    var start: Date
    var durationMin: Int
    var venueName: String
    var address: String
    var attendees: [String]
    var invited: [String]
    var rsvp: [String: String]   // uid: "going" | "declined"
    var names: [String: String]
    var modes: [String: String]
    var type: String
    var createdBy: String
    var venue: CLLocationCoordinate2D?
    var arrivals: [String: Date]
    var alerts: [String: Date]
    var travel: [String: Double]  // trip minutes per person

    init(id: String, data: [String: Any]) {
        self.id = id
        title = data["title"] as? String ?? "Hangout"
        start = When.parse(data["start"]) ?? .distantPast
        durationMin = (data["durationMin"] as? NSNumber)?.intValue ?? 120
        venueName = data["venueName"] as? String ?? ""
        address = data["address"] as? String ?? ""
        attendees = data["attendees"] as? [String] ?? []
        createdBy = data["createdBy"] as? String ?? ""
        invited = data["invited"] as? [String] ?? attendees
        rsvp = data["rsvp"] as? [String: String] ?? [:]
        names = data["names"] as? [String: String] ?? [:]
        modes = data["modes"] as? [String: String] ?? [:]
        type = data["type"] as? String ?? "food"
        if let v = data["venue"] as? [NSNumber], v.count == 2 {
            venue = CLLocationCoordinate2D(latitude: v[0].doubleValue, longitude: v[1].doubleValue)
        }
        arrivals = (data["arrivals"] as? [String: Any] ?? [:]).compactMapValues { When.parse($0) }
        alerts = (data["alerts"] as? [String: Any] ?? [:]).compactMapValues { When.parse($0) }
        travel = (data["travel"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    /// check-in is open from an hour before the start to two hours after (same as the web app)
    var checkInOpen: Bool {
        let m = Date.now.timeIntervalSince(start) / 60
        return m > -60 && m < 120
    }

    static func == (a: Hangout, b: Hangout) -> Bool {
        a.id == b.id && a.start == b.start && a.attendees == b.attendees && a.arrivals == b.arrivals && a.title == b.title
            && a.invited == b.invited && a.rsvp == b.rsvp && a.alerts == b.alerts
    }

    var end: Date { start.addingTimeInterval(TimeInterval(durationMin * 60)) }
    var isOver: Bool { end < .now }
}

/// locations/{uid}: where a friend was last seen (they choose to share it).
struct LiveSpot: Equatable {
    var lat: Double
    var lng: Double
    var at: Date
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    var isFresh: Bool { Date.now.timeIntervalSince(at) < 30 * 60 }  // same as the web app: older than 30 min isn't "live"
}

/// Dates come as ISO strings from the web app ("2026-10-29T18:30:00.000Z"), local plan times ("2026-10-29T18:30"),
/// or Firestore timestamps.
enum When {
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let isoPlain = ISO8601DateFormatter()
    nonisolated(unsafe) static let local: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    static func parse(_ value: Any?) -> Date? {
        if let t = value as? Timestamp { return t.dateValue() }
        if let s = value as? String { return iso.date(from: s) ?? isoPlain.date(from: s) ?? local.date(from: String(s.prefix(16))) }
        if let n = value as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue / 1000) }
        return nil
    }

    static func string(_ date: Date) -> String { iso.string(from: date) }

    /// "just now", "5m", "3h", "2d", then the date, like Instagram
    static func ago(_ date: Date) -> String {
        let s = Date.now.timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 7 * 86400 { return "\(Int(s / 86400))d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
