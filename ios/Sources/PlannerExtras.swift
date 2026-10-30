// The planner's extras, like the web app's: your own hangout types (users/{uid}.categories = [{ id, emoji, name }]),
// how each person gets there for this plan, and "find a spot that's fair for everyone" (the server's /ai/fair-spot:
// places near the middle of the group, everyone's real trip to each, and the fairest one picked).
import SwiftUI
import CoreLocation
import FirebaseFirestore

extension Person {
    /// the hangout types you made yourself, after the built-in ones
    static func parseCategories(_ data: [String: Any]) -> [HangoutType] {
        (data["categories"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["id"] as? String, let name = c["name"] as? String else { return nil }
            return HangoutType(id: id, name: name, symbol: "star", icon: c["emoji"] as? String ?? "star")
        }
    }
}

extension Session {
    func addCategory(_ name: String) -> HangoutType? {
        guard let uid, let me else { return nil }
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
        guard !name.isEmpty else { return nil }
        let slug = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(20))
        let id = "c_\(slug)-\(String(UUID().uuidString.prefix(4)).lowercased())"
        let all = me.categories + [HangoutType(id: id, name: name, symbol: "star", icon: "star")]
        self.me?.categories = all
        db.collection("users").document(uid).setData(["categories": all.map { ["id": $0.id, "emoji": $0.icon, "name": $0.name] }], merge: true)
        return all.last
    }

    func removeCategory(_ id: String) {
        guard let uid, let me else { return }
        let all = me.categories.filter { $0.id != id }
        self.me?.categories = all
        db.collection("users").document(uid).setData(["categories": all.map { ["id": $0.id, "emoji": $0.icon, "name": $0.name] }], merge: true)
    }

    /// where you leave from when nothing fresher is known
    func setHome(_ p: PlaceHit) {
        guard let uid, let lat = p.lat, let lng = p.lng else { return }
        self.me?.home = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        db.collection("users").document(uid).setData(["home": ["lat": lat, "lng": lng], "homeName": p.name ?? "Home",
                                                      "homeAddress": p.address ?? ""], merge: true)
    }
}

enum Travel {
    static let modes = ["driving", "walking", "cycling", "transit"]
    static func symbol(_ m: String) -> String {
        switch m { case "walking": "figure.walk"; case "cycling": "bicycle"; case "transit": "tram.fill"; default: "car.fill" }
    }
    static func name(_ m: String) -> String {
        switch m { case "walking": "Walk"; case "cycling": "Bike"; case "transit": "Transit"; default: "Drive" }
    }
}

// ---------- fair spot ----------
struct FairRequest: Encodable {
    let query: String
    let people: [Who]
    let lat: Double
    let lng: Double
    struct Who: Encodable {
        let id: String
        let name: String
        let home: [Double]?
        let mode: String
    }
}

struct FairAnswer: Decodable {
    let candidates: [Candidate]
    let pick: Int?
    let why: String?
    let missing_home: [String]?

    struct Candidate: Decodable {
        let name: String
        let address: String?
        let lat: Double
        let lng: Double
        let rating: Double?
        let price: String?
        let type: String?
        let open: Bool?
        let times: [String: Int]
        let worst: Int
        let spread: Int
    }
}

/// what kind of place → a few spots near the middle, with everyone's trip, the fairest first
struct FairSpotFinder: View {
    let people: [FairRequest.Who]
    let near: CLLocationCoordinate2D?
    var picked: (PlaceHit) -> Void
    @Environment(Session.self) private var session
    @State private var query = ""
    @State private var answer: FairAnswer?
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "scalemass").foregroundStyle(.secondary)
                TextField(people.count > 1 ? "Fair for everyone: tacos, coffee…" : "Find a spot: tacos, coffee…", text: $query)
                    .submitLabel(.search)
                    .onSubmit(find)
                if working { ProgressView() } else if !query.isEmpty {
                    Button(action: find) { Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(Color.primary) }
                        .buttonStyle(.plain)
                }
            }
            .softField()
            if let problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
            if let answer {
                if let why = answer.why, !answer.candidates.isEmpty {
                    Text(why).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(order(answer), id: \.self) { i in candidate(answer.candidates[i], best: i == answer.pick) }
                if let missing = answer.missing_home, !missing.isEmpty {
                    Text("No location for \(missing.joined(separator: ", ")).").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func order(_ a: FairAnswer) -> [Int] {
        let all = Array(a.candidates.indices)
        guard let pick = a.pick, all.contains(pick) else { return all }
        return [pick] + all.filter { $0 != pick }
    }

    private func candidate(_ c: FairAnswer.Candidate, best: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if best { Image(systemName: "star.fill").foregroundStyle(Color.sun) }
                Text(c.name).font(.subheadline.weight(.bold)).lineLimit(1)
                Spacer()
                Button("Meet here") {
                    picked(PlaceHit(kind: "place", id: nil, name: c.name, address: c.address ?? "", lat: c.lat, lng: c.lng))
                    answer = nil; query = ""
                }
                .font(.caption.weight(.bold))
                .buttonStyle(.borderedProminent).tint(best ? Color.primary : Color.secondary)
                .foregroundStyle(Color(.systemBackground))
            }
            let facts = [c.rating.map { String(format: "★ %.1f", $0) }, c.price, c.type, c.open == true ? "Open now" : c.open == false ? "Closed now" : nil]
                .compactMap { $0 }.filter { !$0.isEmpty }
            if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(people.filter { c.times[$0.id] != nil }, id: \.id) { p in
                        let m = c.times[p.id] ?? 0
                        Text("\(p.name) \(m) min")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(m == c.worst && c.spread > 5 ? Color.orange.opacity(0.2) : Color(.tertiarySystemFill), in: Capsule())
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
        .background(best ? Color.sun.opacity(0.15) : Color(.tertiarySystemFill).opacity(0.5), in: .rect(cornerRadius: 14))
    }

    private func find() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        guard !people.isEmpty else { problem = "Sign in again to search."; return }
        let center = near ?? session.me?.home ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        working = true; problem = nil
        Task {
            do {
                answer = try await API.send("/ai/fair-spot", FairRequest(query: q, people: people, lat: center.latitude, lng: center.longitude),
                                            as: FairAnswer.self)
                if answer?.candidates.isEmpty == true { problem = answer?.why; answer = nil }
            } catch { problem = error.localizedDescription }
            working = false
        }
    }
}

// ---------- Muse: plan from one sentence ----------
/// "boba with Priya Friday after 5" → who, what, when and where (the server's /ai/plan, same as the web app)
struct MuseRequest: Encodable {
    let text: String
    let friends: [Named]
    let categories: [Named]
    let now: String       // your local time, "2026-10-30T19:30"
    let lat: Double
    let lng: Double
    struct Named: Encodable { let id: String; let name: String }
}

struct MuseAnswer: Decodable {
    let who: [String]
    let type: String?
    let when: String?
    let place: PlaceHit?
    let place_options: [PlaceHit]?
    let place_query: String?
    let summary: String?
    let note: String?
}

struct MuseBar: View {
    let near: CLLocationCoordinate2D?
    var filled: (MuseAnswer) -> String   // the planner fills itself in and says what it did
    @Environment(Session.self) private var session
    @State private var text = ""
    @State private var said = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // plain, like a message: an example with one of your own friends in it
                TextField("Type it: boba with \(session.friends.first?.firstName ?? "Sam") fri 7pm", text: $text)
                    .submitLabel(.go)
                    .onSubmit(ask)
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: ask) { Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(Color.primary) }
                        .buttonStyle(.plain)
                }
            }
            .softField()
            if !said.isEmpty {
                Text(said).font(.footnote.weight(.medium)).foregroundStyle(failed ? Color.red : Color.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Fills in right away what's plain in what you typed (names, the kind of thing, the day and time), then lets the
    /// server's Muse finish it (the place, and anything said in a roundabout way) without making you wait.
    private func ask() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        text = ""
        failed = false
        said = filled(quickRead(q))
        let at = near ?? session.me?.home ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let types = HangoutType.all + (session.me?.categories ?? [])
        let request = MuseRequest(text: q, friends: session.friends.map { .init(id: $0.id, name: $0.name) },
                                  categories: types.map { .init(id: $0.id, name: $0.name) },
                                  now: When.local.string(from: .now), lat: at.latitude, lng: at.longitude)
        Task {
            if let answer = try? await API.send("/ai/plan", request, as: MuseAnswer.self) { said = filled(answer) }
        }
    }

    /// the obvious bits, on the phone: friends' names, "coffee"/"dinner"/…, "tonight"/"tomorrow"/"fri", "7pm"/"7:30"
    private func quickRead(_ q: String) -> MuseAnswer {
        let words = q.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != ":" }.map(String.init)
        let who = session.friends.filter { words.contains($0.firstName.lowercased()) }.map(\.id)
        let kinds: [(String, [String])] = [
            ("coffee", ["coffee", "boba", "cafe", "tea", "matcha", "latte"]),
            ("food", ["food", "dinner", "lunch", "breakfast", "brunch", "eat", "tacos", "pizza", "sushi", "ramen", "burgers"]),
            ("study", ["study", "homework", "library", "work"]),
            ("party", ["party", "drinks", "bar", "club", "karaoke"]),
            ("sports", ["sports", "gym", "basketball", "soccer", "tennis", "run", "hike", "volleyball"]),
        ]
        var type = kinds.first { _, keys in keys.contains { words.contains($0) } }?.0
        for c in session.me?.categories ?? [] where words.contains(c.name.lowercased()) { type = c.id }

        let cal = Calendar.current
        var day: Date?
        if words.contains("tonight") || words.contains("today") { day = .now }
        if words.contains("tomorrow") || words.contains("tmr") || words.contains("tmrw") { day = cal.date(byAdding: .day, value: 1, to: .now) }
        let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        for w in words {
            if let i = weekdays.firstIndex(where: { w.hasPrefix($0) && w.count <= 9 }) {
                day = cal.nextDate(after: .now, matching: DateComponents(weekday: i + 1), matchingPolicy: .nextTime)
            }
        }
        var hour: Int?, minute = 0
        for (k, w) in words.enumerated() {
            let pm = w.hasSuffix("pm") || words.indices.contains(k + 1) && words[k + 1] == "pm"
            let am = w.hasSuffix("am") || words.indices.contains(k + 1) && words[k + 1] == "am"
            let digits = w.replacingOccurrences(of: "pm", with: "").replacingOccurrences(of: "am", with: "")
            let parts = digits.split(separator: ":")
            guard let h = Int(parts.first ?? ""), (1...23).contains(h), parts.count <= 2,
                  pm || am || parts.count == 2 || (k > 0 && words[k - 1] == "at") else { continue }
            hour = pm && h < 12 ? h + 12 : am && h == 12 ? 0 : (!am && !pm && h < 8 ? h + 12 : h)
            minute = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        }
        var when: String?
        if day != nil || hour != nil {
            let base = day ?? .now
            var start = cal.date(bySettingHour: hour ?? 19, minute: minute, second: 0, of: base) ?? base
            if start < .now { start = cal.date(byAdding: .day, value: 1, to: start) ?? start }
            when = When.local.string(from: start)
        }
        return MuseAnswer(who: who, type: type, when: when, place: nil, place_options: nil, place_query: nil, summary: "Got it", note: nil)
    }
}
