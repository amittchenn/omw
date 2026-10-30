// Places, like Beli: rank the spots you've been (how was it, then a few "which did you like more?"), your list best
// first with a score, and the places you saved from the map. All private to you, in private/{uid} (the web app's
// web/feed.js ranking and web/maptab.js saved places):
//   ranks  = { liked: [key], fine: [key], disliked: [key] }   best first
//   places = { key: { name, address, venue: [lat, lng] } }
//   saved  = [{ name, address, lat, lng, at }]
// A place's score comes from where it sits: liked 6.7 to 10, fine 3.4 to 6.6, didn't like 0 to 3.3.
import SwiftUI
import CoreLocation
import FirebaseFirestore

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
    let score: Double
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

    func score(of key: String) -> Double? {
        for b in RankBucket.allCases {
            if let i = ranks[b].firstIndex(of: key) { return Self.score(b, i, ranks[b].count) }
        }
        return nil
    }

    static func score(_ b: RankBucket, _ i: Int, _ n: Int) -> Double {
        let (lo, hi) = b.range
        return ((hi - (Double(i) + 0.5) / Double(max(n, 1)) * (hi - lo)) * 10).rounded() / 10
    }

    /// your list, best first
    var rankedList: [RankedItem] {
        var list: [RankedItem] = []
        for b in RankBucket.allCases {
            let keys = ranks[b]
            for (i, key) in keys.enumerated() {
                if let place = rankedPlaces[key] { list.append(RankedItem(key: key, place: place, score: Self.score(b, i, keys.count))) }
            }
        }
        return list
    }

    /// puts a place in your list at `index` of `bucket` (taking it out of wherever it was), and on the post you rated it from
    func saveRank(_ place: RankedPlace, key: String, bucket: RankBucket, index: Int, post: String?) {
        guard let uid else { return }
        for b in RankBucket.allCases { ranks[b].removeAll { $0 == key } }
        ranks[bucket].insert(key, at: min(index, ranks[bucket].count))
        rankedPlaces[key] = place
        let ranksDoc: [String: Any] = ["liked": ranks.liked, "fine": ranks.fine, "disliked": ranks.disliked]
        db.collection("private").document(uid).setData(["ranks": ranksDoc, "places": [key: place.dict]], merge: true)
        if let post, let s = score(of: key) {
            db.collection("feed").document(post).updateData(["ratings.\(uid)": s])
        }
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
    }

    /// places you've been that aren't on your list yet: past plans, your posts, saved places
    var placesToRate: [RankedPlace] {
        var seen = Set(RankBucket.allCases.flatMap { ranks[$0] }), list: [RankedPlace] = []
        func add(_ name: String, _ address: String, _ venue: [Double]) {
            let key = Self.placeKey(name, address)
            guard !name.isEmpty, seen.insert(key).inserted else { return }
            list.append(RankedPlace(name: name, address: address, venue: venue))
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

    private var key: String { Session.placeKey(place.name, place.address) }

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
                }
                VStack(spacing: 10) {
                    ForEach(RankBucket.allCases) { b in
                        Button { feel(b) } label: {
                            Label(b.label, systemImage: b.symbol)
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(b.color.opacity(0.15), in: .rect(cornerRadius: 14))
                                .foregroundStyle(b.color)
                        }
                        .buttonStyle(Pressable())
                    }
                }
            }
        }
        .padding(22)
        .sensoryFeedback(.selection, trigger: asked)
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
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(Pressable())
        .foregroundStyle(.primary)
    }

    private func feel(_ b: RankBucket) {
        others = session.ranks[b].filter { $0 != key }
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
        session.saveRank(place, key: key, bucket: b, index: lo, post: post)
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
                    } header: { Text("Places you've been") } footer: {
                        if session.placesToRate.isEmpty { Text("Places from your plans and posts show up here. Or search above.") }
                    }
                } else {
                    ForEach(hits, id: \.key) { h in
                        row(h.name ?? "", h.address ?? "") {
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
                RankSheet(place: item.place).presentationDetents([.height(380)]).presentationDragIndicator(.visible)
            }
        }
    }

    private func row(_ name: String, _ address: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if !address.isEmpty { Text(address).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
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
                        Text(String(format: "%.1f", item.score))
                            .font(.subheadline.weight(.bold))
                            .frame(width: 42, height: 42)
                            .overlay(Circle().strokeBorder(item.score >= 6.7 ? Color.freeGreen : item.score >= 3.4 ? Color.orange : Color.red, lineWidth: 2))
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
        .sheet(isPresented: $rating) { RatePlaceSheet() }
        .sheet(item: Binding(get: { rerank.map(RatingItem.init) }, set: { if $0 == nil { rerank = nil } })) { item in
            RankSheet(place: item.place).presentationDetents([.height(380)]).presentationDragIndicator(.visible)
        }
    }
}
