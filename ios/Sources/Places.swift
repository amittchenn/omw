// Places, like Beli: rank the spots you've been (how was it, then a few "which did you like more?"), your list best
// first with a score, and the places you saved from the map. All private to you, in private/{uid} (the web app's
// web/feed.js ranking and web/maptab.js saved places):
//   ranks  = { liked: [key], fine: [key], disliked: [key] }   best first
//   places = { key: { name, address, venue: [lat, lng] } }
//   saved  = [{ name, address, lat, lng, at }]
//   stars  = { key: 1…5 }   what you gave it; your list is by stars, then by your "which did you like more?" answers
// Each place is on your list once: rating it again (or the same spot under a slightly different name) replaces it.
// On posts, ratings stay out of 10 (stars × 2) so the web app reads them the same.
import SwiftUI
import CoreLocation
import FirebaseFirestore
#if canImport(LocationEssentials)
import LocationEssentials  // where iOS 26 keeps coordinates and distances
#endif

struct RankedPlace: Equatable {
    var name: String
    var address: String
    var venue: [Double]

    var dict: [String: Any] { ["name": name, "address": address, "venue": venue.count == 2 ? venue : NSNull()] }
}

struct Ranks: Equatable {
    var liked: [String] = []
    var fine: [String] = []
    var disliked: [String] = []

    subscript(_ b: RankBucket) -> [String] {
        get { switch b { case .liked: liked; case .fine: fine; case .disliked: disliked } }
        set { switch b { case .liked: liked = newValue; case .fine: fine = newValue; case .disliked: disliked = newValue } }
    }
}

enum RankBucket: String, CaseIterable, Identifiable {
    case liked, fine, disliked
    var id: String { rawValue }
    var label: String { switch self { case .liked: "I liked it"; case .fine: "It was fine"; case .disliked: "I didn't like it" } }
    var symbol: String { switch self { case .liked: "face.smiling.inverse"; case .fine: "face.dashed"; case .disliked: "hand.thumbsdown.fill" } }
    var range: (lo: Double, hi: Double) { switch self { case .liked: (6.7, 10); case .fine: (3.4, 6.6); case .disliked: (0, 3.3) } }
    var color: Color { switch self { case .liked: .freeGreen; case .fine: .orange; case .disliked: .red } }
}

struct RankedItem: Identifiable {
    let key: String
    let place: RankedPlace
    let stars: Int
    var id: String { key }
}

struct SavedPlace: Identifiable, Equatable {
    var name: String
    var address: String
    var lat: Double
    var lng: Double
    var at: String
    var id: String { String(format: "%.5f,%.5f", lat, lng) }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

extension Session {
    /// the same key the web app uses for a place
    static func placeKey(_ name: String, _ address: String) -> String {
        let raw = "\(name)|\(address)".lowercased().filter { !".#$/[]".contains($0) }
        return String(raw.prefix(200))
    }

    /// the stars you gave a place (older ratings without stars: from where it sat in your list)
    func score(of key: String) -> Double? { starsFor(key).map(Double.init) }

    func starsFor(_ key: String) -> Int? {
        if let n = stars[key] { return n }
        for b in RankBucket.allCases {
            if let i = ranks[b].firstIndex(of: key) { return min(5, max(1, Int((Self.score(b, i, ranks[b].count) / 2).rounded()))) }
        }
        return nil
    }

    /// the key a place is already on your list under: the same name and address, or the same spot nearby by a
    /// slightly different name ("Tin Drum" from a plan, "Tin Drum Asian Kitchen" from search)
    func existingKey(for place: RankedPlace) -> String? {
        let key = Self.placeKey(place.name, place.address)
        let all = RankBucket.allCases.flatMap { ranks[$0] }
        if all.contains(key) { return key }
        let name = place.name.lowercased()
        return all.first { k in
            guard let p = rankedPlaces[k] else { return false }
            let other = p.name.lowercased()
            let sameName = !name.isEmpty && (other == name || other.hasPrefix(name) || name.hasPrefix(other))
            guard sameName else { return false }
            if place.venue.count == 2, p.venue.count == 2 {
                return CLLocation(latitude: place.venue[0], longitude: place.venue[1])
                    .distance(from: CLLocation(latitude: p.venue[0], longitude: p.venue[1])) < 120
            }
            return true
        }
    }

    static func score(_ b: RankBucket, _ i: Int, _ n: Int) -> Double {
        let (lo, hi) = b.range
        return ((hi - (Double(i) + 0.5) / Double(max(n, 1)) * (hi - lo)) * 10).rounded() / 10
    }

    /// your list, best first: by stars, then in the order your comparisons put them
    var rankedList: [RankedItem] {
        var list: [(item: RankedItem, order: Int)] = []
        for key in RankBucket.allCases.flatMap({ ranks[$0] }) {
            if let place = rankedPlaces[key], let n = starsFor(key) { list.append((RankedItem(key: key, place: place, stars: n), list.count)) }
        }
        return list.sorted { ($0.item.stars, -$0.order) > ($1.item.stars, -$1.order) }.map(\.item)
    }

    /// puts a place in your list at `index` of `bucket` (taking it out of wherever it was), and on the post you rated it from
    func saveRank(_ place: RankedPlace, key: String, stars n: Int, bucket: RankBucket, index: Int, post: String?) {
        guard let uid else { return }
        // once per place: out it comes from wherever it was (and any older copy of the same spot)
        let old = existingKey(for: place)
        var gone: [String: Any] = [:]
        for k in Set([key, old].compactMap { $0 }) {
            for b in RankBucket.allCases { ranks[b].removeAll { $0 == k } }
            if k != key { rankedPlaces[k] = nil; stars[k] = nil; gone[k] = FieldValue.delete() }
        }
        ranks[bucket].insert(key, at: min(max(index, 0), ranks[bucket].count))
        rankedPlaces[key] = place
        stars[key] = n
        let ranksDoc: [String: Any] = ["liked": ranks.liked, "fine": ranks.fine, "disliked": ranks.disliked]
        var starsDoc: [String: Any] = gone
        starsDoc[key] = n
        var placesDoc: [String: Any] = gone
        placesDoc[key] = place.dict
        db.collection("private").document(uid).setData(["ranks": ranksDoc, "places": placesDoc, "stars": starsDoc], merge: true)
        if let post { db.collection("feed").document(post).updateData(["ratings.\(uid)": Double(n * 2)]) }
    }

    // ---------- saved places ----------
    func isSaved(lat: Double, lng: Double) -> Bool {
        saved.contains { abs($0.lat - lat) < 1e-5 && abs($0.lng - lng) < 1e-5 }
    }

    func toggleSaved(name: String, address: String, lat: Double, lng: Double) {
        guard let uid else { return }
        if isSaved(lat: lat, lng: lng) {
            saved.removeAll { abs($0.lat - lat) < 1e-5 && abs($0.lng - lng) < 1e-5 }
        } else {
            saved.append(SavedPlace(name: name, address: address, lat: lat, lng: lng, at: When.string(.now)))
        }
        let list = saved.suffix(300).map { ["name": $0.name, "address": $0.address, "lat": $0.lat, "lng": $0.lng, "at": $0.at] as [String: Any] }
        db.collection("private").document(uid).setData(["saved": Array(list)], merge: true)
    }

    /// reads private/{uid} (called by the listener in Session.swift)
    func readPrivate(_ data: [String: Any]) {
        let r = data["ranks"] as? [String: Any] ?? [:]
        stars = (data["stars"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
        ranks = Ranks(liked: r["liked"] as? [String] ?? [], fine: r["fine"] as? [String] ?? [], disliked: r["disliked"] as? [String] ?? [])
        rankedPlaces = (data["places"] as? [String: Any] ?? [:]).compactMapValues { v in
            guard let d = v as? [String: Any] else { return nil }
            return RankedPlace(name: d["name"] as? String ?? "", address: d["address"] as? String ?? "",
                               venue: (d["venue"] as? [NSNumber] ?? []).map(\.doubleValue))
        }
        saved = (data["saved"] as? [[String: Any]] ?? []).compactMap { d in
            guard let lat = (d["lat"] as? NSNumber)?.doubleValue, let lng = (d["lng"] as? NSNumber)?.doubleValue else { return nil }
            return SavedPlace(name: d["name"] as? String ?? "Saved place", address: d["address"] as? String ?? "", lat: lat, lng: lng,
                              at: d["at"] as? String ?? "")
        }
        // places rated before stars existed: give them the stars their old spot in the list meant, once, so the
        // list shows what you'd expect and keeps it
        var missing: [String: Any] = [:]
        for key in RankBucket.allCases.flatMap({ ranks[$0] }) where stars[key] == nil {
            if let n = starsFor(key) { missing[key] = n }
        }
        if !missing.isEmpty, let uid {
            for (k, v) in missing { stars[k] = v as? Int }
            db.collection("private").document(uid).setData(["stars": missing], merge: true)
        }
    }

    /// places you've been that aren't on your list yet: past plans, your posts, saved places
    var placesToRate: [RankedPlace] {
        var seen = Set(RankBucket.allCases.flatMap { ranks[$0] }), list: [RankedPlace] = []
        func add(_ name: String, _ address: String, _ venue: [Double]) {
            let key = Self.placeKey(name, address)
            let place = RankedPlace(name: name, address: address, venue: venue)
            guard !name.isEmpty, existingKey(for: place) == nil, seen.insert(key).inserted else { return }
            list.append(place)
        }
        for h in past { add(h.venueName, h.address, h.venue.map { [$0.latitude, $0.longitude] } ?? []) }
        for p in allPosts where p.members.contains(uid ?? "") { add(p.venueName, p.address, p.venue) }
        for s in saved { add(s.name, s.address, [s.lat, s.lng]) }
        return list
    }
}

// ---------- ranking one place ----------
/// "How was it?" then "Which did you like more?" a few times (a binary search through that part of your list)
struct RankSheet: View {
    let place: RankedPlace
    var post: String? = nil
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var bucket: RankBucket?
    @State private var lo = 0
    @State private var hi = 0
    @State private var asked = 0
    @State private var others: [String] = []  // that part of your list, without this place
    @State private var stars = 0

    /// the place's key on your list (the one it's already under, if you rated it before)
    private var key: String { session.existingKey(for: place) ?? Session.placeKey(place.name, place.address) }
    private var before: Int? { session.starsFor(key) }

    var body: some View {
        VStack(spacing: 18) {
            if let bucket, lo < hi {
                let mid = (lo + hi) / 2
                let other = session.rankedPlaces[others[mid]]
                VStack(spacing: 4) {
                    Text("Which did you like more?").font(.title3.weight(.bold))
                    Text("\(asked + 1) of about \(max(1, Int(ceil(log2(Double(others.count + 1))))))").font(.footnote).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    choice(place.name, place.address) { pick(better: true, mid: mid, bucket: bucket) }
                    Text("or").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    choice(other?.name ?? "", other?.address ?? "") { pick(better: false, mid: mid, bucket: bucket) }
                }
                Button("Too close to call") { lo = mid; hi = mid; finish(bucket) }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    Text("How was \(place.name)?").font(.title3.weight(.bold)).multilineTextAlignment(.center)
                    if !place.address.isEmpty { Text(place.address).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                    if let before { Text("You gave it \(before) star\(before == 1 ? "" : "s"). Tap to change it.").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2) }
                }
                // stars: 4–5 liked it, 3 fine, 1–2 didn't (the same three groups as the web app's list)
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(1...5, id: \.self) { n in
                            Button { rate(n) } label: {
                                Image(systemName: n <= stars ? "star.fill" : "star")
                                    .font(.system(size: 38, weight: .semibold))
                                    .foregroundStyle(n <= stars ? Color.sun : Color(.tertiaryLabel))
                                    .scaleEffect(n == stars ? 1.15 : 1)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(n) star\(n == 1 ? "" : "s")")
                        }
                    }
                    Text(["Tap to rate", "Not for me", "Meh", "It was fine", "Good", "Loved it"][stars])
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
        }
        .padding(22)
        .sensoryFeedback(.selection, trigger: asked)
        .sensoryFeedback(.selection, trigger: stars)
        .animation(.snappy(duration: 0.2), value: asked)
        .animation(.snappy(duration: 0.2), value: bucket)
    }

    private func choice(_ name: String, _ address: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(name).font(.headline).multilineTextAlignment(.center).lineLimit(3)
                Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(Color.omwCard, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(Pressable())
        .foregroundStyle(.primary)
    }

    /// a quick beat so you see the stars fill, then on to "which did you like more?"
    private func rate(_ n: Int) {
        withAnimation(.snappy(duration: 0.15)) { stars = n }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            feel(n >= 4 ? .liked : n == 3 ? .fine : .disliked)
        }
    }

    /// compare only with places you gave the same stars, so a 4 never lands above a 5
    private func feel(_ b: RankBucket) {
        others = session.ranks[b].filter { $0 != key && session.starsFor($0) == stars }
        lo = 0; hi = others.count; asked = 0
        bucket = b
        if lo >= hi { finish(b) }
    }

    private func pick(better: Bool, mid: Int, bucket: RankBucket) {
        if better { hi = mid } else { lo = mid + 1 }
        asked += 1
        if lo >= hi { finish(bucket) }
    }

    private func finish(_ b: RankBucket) {
        // where that lands in the whole group: before the place it beat, or after the last one with these stars
        let list = session.ranks[b].filter { $0 != key }
        let index: Int
        if lo < others.count, let i = list.firstIndex(of: others[lo]) { index = i }
        else if let last = others.last, let i = list.firstIndex(of: last) { index = i + 1 }
        else { index = list.firstIndex { (session.starsFor($0) ?? 0) < stars } ?? list.count }
        session.saveRank(place, key: key, stars: stars, bucket: b, index: index, post: post)
        dismiss()
    }
}

// ---------- Rate a place: somewhere you've been, or search ----------
struct RatePlaceSheet: View {
    @Environment(Session.self) private var session
    @Environment(LocationService.self) private var location
    @State private var query = ""
    @State private var hits: [PlaceHit] = []
    @State private var rating: RankedPlace?

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        ForEach(session.placesToRate, id: \.name) { p in row(p.name, p.address) { rating = p } }
                    } header: { Text("Places you've been") }
                } else {
                    ForEach(hits, id: \.key) { h in
                        row(h.name ?? "", h.address ?? "", rated: session.existingKey(for: RankedPlace(name: h.name ?? "", address: h.address ?? "",
                                venue: [h.lat, h.lng].compactMap { $0 })).flatMap { session.starsFor($0) }) {
                            Task {
                                let full = await API.placeDetails(h)
                                rating = RankedPlace(name: full.name ?? "", address: full.address ?? "",
                                                     venue: [full.lat, full.lng].compactMap { $0 })
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search any place")
            .navigationTitle("Rate a place")
            .omwBackground()
            .navigationBarTitleDisplayMode(.inline)
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else { hits = []; return }
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                let near = location.last?.coordinate ?? session.me?.home ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
                hits = await API.suggestPlaces(q, near: (near.latitude, near.longitude))
            }
            .sheet(item: Binding(get: { rating.map(RatingItem.init) }, set: { if $0 == nil { rating = nil } })) { item in
                RankSheet(place: item.place).withOmw().presentationDetents([.height(380)]).presentationDragIndicator(.visible)
            }
        }
    }

    private func row(_ name: String, _ address: String, rated: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if !address.isEmpty { Text(address).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                // already on your list: tapping changes that rating rather than adding it twice
                if let rated { Label("\(rated)", systemImage: "star.fill").font(.footnote.weight(.bold)).foregroundStyle(Color.sun) }
            }
        }
    }
}

struct RatingItem: Identifiable {
    let place: RankedPlace
    var id: String { Session.placeKey(place.name, place.address) }
}

// ---------- your list (the Places tab on your profile) ----------
struct PlacesList: View {
    @Environment(Session.self) private var session
    @State private var rating = false
    @State private var rerank: RankedPlace?

    var body: some View {
        VStack(spacing: 12) {
            Button { rating = true } label: {
                Label("Rate a place", systemImage: "star.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.sun, in: .rect(cornerRadius: 14))
                    .foregroundStyle(.black)
            }
            .buttonStyle(Pressable())
            if session.rankedList.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "star").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Your places").font(.headline)
                    Text("Rate the spots you go to. Your list builds itself, best first.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.top, 30)
            }
            ForEach(Array(session.rankedList.enumerated()), id: \.element.key) { i, item in
                Button { rerank = item.place } label: {
                    HStack(spacing: 12) {
                        Text("\(i + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.place.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if !item.place.address.isEmpty { Text(item.place.address).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        // exactly the stars you gave it
                        HStack(spacing: 1) {
                            ForEach(1...5, id: \.self) { n in
                                Image(systemName: n <= item.stars ? "star.fill" : "star")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(n <= item.stars ? Color.sun : Color(.tertiaryLabel))
                            }
                        }
                        .accessibilityLabel("\(item.stars) stars")
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .sheet(isPresented: $rating) { RatePlaceSheet().withOmw() }
        .sheet(item: Binding(get: { rerank.map(RatingItem.init) }, set: { if $0 == nil { rerank = nil } })) { item in
            RankSheet(place: item.place).withOmw().presentationDetents([.height(380)]).presentationDragIndicator(.visible)
        }
    }
}
