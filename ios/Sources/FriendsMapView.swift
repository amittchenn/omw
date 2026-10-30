// The Map tab, like Snap Map, on Apple Maps: your friends where they are (if they share it) as their pictures with a
// ring for what they're up to, and you. Tap a friend for their card.
import SwiftUI
import MapKit
import CoreLocation

struct FriendsMapView: View {
    @Environment(Session.self) private var session
    // leaning back a little, like Snap Map, so buildings stand up in 3D
    @State private var position: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
    @State private var selected: Person?
    @State private var openPost: Post?
    @State private var query = ""
    @State private var hits: [PlaceHit] = []
    @State private var place: MapPlace?
    @FocusState private var searching: Bool
    @Environment(LocationService.self) private var location

    private var live: [LiveFriend] {
        session.friends.compactMap { f in
            guard let spot = session.spots[f.id], spot.isFresh else { return nil }
            return LiveFriend(person: f, spot: spot)
        }
    }

    /// friends' photos where they took them, like Snap Map: the newest at each place, with how many there are
    private var photoSpots: [PhotoSpot] {
        var by: [String: [Post]] = [:]
        for p in session.posts where p.venue.count == 2 && !p.photo.isEmpty {
            by[String(format: "%.4f,%.4f", p.venue[0], p.venue[1]), default: []].append(p)
        }
        return by.values.compactMap { posts in
            let newest = posts.sorted { $0.at > $1.at }
            return newest.first.map { PhotoSpot(post: $0, count: posts.count) }
        }
    }

    /// where friends have been: posts with a place, and plans you've been to
    private var heat: [HeatSpot] {
        var seen = Set<String>(), out: [HeatSpot] = []
        func add(_ lat: Double, _ lng: Double) {
            if seen.insert(String(format: "%.3f,%.3f", lat, lng)).inserted { out.append(HeatSpot(lat: lat, lng: lng)) }
        }
        for p in session.posts where p.venue.count == 2 { add(p.venue[0], p.venue[1]) }
        for h in session.hangouts { if let v = h.venue { add(v.latitude, v.longitude) } }
        return Array(out.prefix(60))
    }

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                // a warm glow where your friends hang out (their posts and your plans), like Snap Map's heat
                ForEach(heat) { h in
                    MapCircle(center: h.coordinate, radius: 420).foregroundStyle(Color.orange.opacity(0.10))
                    MapCircle(center: h.coordinate, radius: 220).foregroundStyle(Color.orange.opacity(0.16))
                    MapCircle(center: h.coordinate, radius: 90).foregroundStyle(Color.pink.opacity(0.22))
                }
                // you, as your picture (like Snap Map's "Me")
                UserAnnotation { _ in
                    VStack(spacing: 3) {
                        Avatar(session.me, size: 46)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                        Text("Me").font(.caption.weight(.heavy))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.sun, in: Capsule()).foregroundStyle(.black)
                    }
                }
                ForEach(photoSpots) { spot in
                    Annotation(spot.post.venueName, coordinate: CLLocationCoordinate2D(latitude: spot.post.venue[0], longitude: spot.post.venue[1]), anchor: .bottom) {
                        PhotoPin(spot: spot).onTapGesture { openPost = spot.post }
                    }
                    .annotationTitles(.hidden)
                }
                ForEach(session.saved) { s in
                    Annotation(s.name, coordinate: s.coordinate) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.omwBlue, in: Circle())
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                            .onTapGesture { place = MapPlace(name: s.name, address: s.address, lat: s.lat, lng: s.lng) }
                    }
                    .annotationTitles(.hidden)
                }
                if let place {
                    Marker(place.name, systemImage: "mappin", coordinate: place.coordinate).tint(.red)
                }
                ForEach(live) { item in
                    Annotation(item.person.firstName, coordinate: item.spot.coordinate, anchor: .bottom) {
                        FriendPin(person: item.person, minutesAgo: Int(Date.now.timeIntervalSince(item.spot.at) / 60))
                            .onTapGesture { selected = item.person }
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .including([.cafe, .restaurant, .bakery, .nightlife, .park, .museum, .movieTheater, .stadium, .university])))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .overlay(alignment: .top) { searchBar }
            .overlay(alignment: .bottom) { friendBar }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else { hits = []; return }
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                let near = location.last?.coordinate ?? session.me?.home ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
                hits = await API.suggestPlaces(q, near: (near.latitude, near.longitude))
            }
            .sheet(item: $place) { p in
                PlaceCard(place: p).withOmw()
                    .presentationDetents([.height(250)])
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled)
            }
            .onAppear {
                location.apply()
                // tilted, like Snap Map, once we know where you are
                if let here = location.last?.coordinate {
                    position = .camera(MapCamera(centerCoordinate: here, distance: 2200, heading: 0, pitch: 50))
                }
            }
            .sheet(item: $openPost) { post in
                NavigationStack { PostDetailView(id: post.id).withProfileRoutes() }.withOmw()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $selected) { f in
                FriendCard(person: f).withOmw()
                    .presentationDetents([.height(190)])
                    .presentationDragIndicator(.visible)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

extension FriendsMapView {
    /// search any place, like Google Maps; and who's sharing (or not) under it
    var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search places", text: $query)
                    .focused($searching)
                    .submitLabel(.search)
                    .onSubmit { if let first = hits.first { open(first) } }  // Search: go to the best match
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = ""; searching = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            .padding(.horizontal, 14).frame(height: 46)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)

            if !query.trimmingCharacters(in: .whitespaces).isEmpty && !hits.isEmpty && place == nil {
                VStack(spacing: 0) {
                    ForEach(hits.prefix(6), id: \.key) { h in
                        Button { open(h) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill").font(.title3).foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(h.name ?? "").font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                    Text(h.address ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 48)
                    }
                }
                .background(.regularMaterial, in: .rect(cornerRadius: 18))
            }
        }
        .padding(.horizontal, 12)
        .padding(.trailing, 52)  // clear of the locate button
        .padding(.top, 6)
    }

    func open(_ hit: PlaceHit) {
        searching = false
        hits = []
        Task {
            let full = await API.placeDetails(hit)
            guard let lat = full.lat, let lng = full.lng else { return }
            let p = MapPlace(name: full.name ?? hit.name ?? "Place", address: full.address ?? hit.address ?? "", lat: lat, lng: lng)
            withAnimation(.snappy(duration: 0.4)) {
                position = .region(MKCoordinateRegion(center: p.coordinate, latitudinalMeters: 900, longitudinalMeters: 900))
            }
            place = p
        }
    }
}

extension FriendsMapView {
    /// along the bottom, like Snap Map: you, then your friends (sharing ones first). Tap to fly to them.
    var friendBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                bubble(session.me, label: "Me", lit: true) {
                    if let here = location.last?.coordinate { fly(to: here) }
                }
                ForEach(session.friends.sorted { (session.spots[$0.id]?.isFresh == true ? 0 : 1) < (session.spots[$1.id]?.isFresh == true ? 0 : 1) }) { f in
                    let spot = session.spots[f.id]
                    bubble(f, label: f.firstName, lit: spot?.isFresh == true) {
                        if let spot, spot.isFresh { fly(to: spot.coordinate) } else { selected = f }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 4)
    }

    private func bubble(_ p: Person?, label: String, lit: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                Avatar(p, size: 52, showStatus: true)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.25), radius: 5, y: 3)
                    .opacity(lit ? 1 : 0.6)
                Text(label).font(.caption.weight(.heavy)).lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
            }
            .frame(width: 64)
        }
        .buttonStyle(Pressable())
    }

    func fly(to c: CLLocationCoordinate2D) {
        withAnimation(.snappy(duration: 0.45)) {
            position = .camera(MapCamera(centerCoordinate: c, distance: 1400, heading: 0, pitch: 55))
        }
    }
}

struct HeatSpot: Identifiable {
    let lat: Double
    let lng: Double
    var id: String { "\(lat),\(lng)" }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

/// a place on the map you tapped or searched
struct MapPlace: Identifiable, Equatable {
    var name: String
    var address: String
    var lat: Double
    var lng: Double
    var id: String { String(format: "%.5f,%.5f", lat, lng) }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    var hit: PlaceHit { PlaceHit(kind: "place", id: nil, name: name, address: address, lat: lat, lng: lng) }
}

/// The place card: Save, Plan here, Rate, Directions
struct PlaceCard: View {
    let place: MapPlace
    @Environment(Session.self) private var session
    @State private var planning = false
    @State private var rating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(place.name).font(.title3.weight(.bold)).lineLimit(2)
                HStack(spacing: 6) {
                    if let s = session.score(of: Session.placeKey(place.name, place.address)) {
                        Text(String(format: "%.1f", s)).font(.caption.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.freeGreen.opacity(0.2), in: Capsule())
                    }
                    Text(place.address).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                Button { planning = true } label: {
                    Label("Plan here", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.borderedProminent).tint(Color.primary).foregroundStyle(Color(.systemBackground))
                action(session.isSaved(lat: place.lat, lng: place.lng) ? "bookmark.fill" : "bookmark", "Save") {
                    session.toggleSaved(name: place.name, address: place.address, lat: place.lat, lng: place.lng)
                }
                action("star", "Rate") { rating = true }
                action("arrow.triangle.turn.up.right.diamond", "Go") {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
                    item.name = place.name
                    item.openInMaps()
                }
            }
        }
        .padding(20)
        .sensoryFeedback(.selection, trigger: session.saved.count)
        .sheet(isPresented: $planning) {
            PlanSheet(start: place.hit).withOmw().presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $rating) {
            RankSheet(place: RankedPlace(name: place.name, address: place.address, venue: [place.lat, place.lng]))
                .withOmw().presentationDetents([.height(380)]).presentationDragIndicator(.visible)
        }
    }

    private func action(_ symbol: String, _ label: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .frame(width: 46, height: 46)
                .background(Color(.secondarySystemFill), in: Circle())
        }
        .buttonStyle(Pressable())
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }
}

struct PhotoSpot: Identifiable {
    let post: Post
    let count: Int
    var id: String { post.id }
}

/// a friend's photo standing on its spot: a framed picture with a little point, and a count if there are more
struct PhotoPin: View {
    let spot: PhotoSpot

    var body: some View {
        VStack(spacing: -2) {
            RemoteImage(source: spot.post.photo)
                .frame(width: 50, height: 50)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white, lineWidth: 3))
                .overlay(alignment: .topTrailing) {
                    if spot.count > 1 {
                        Text("\(spot.count)").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 22)
                            .background(Color.red, in: Capsule()).overlay(Capsule().strokeBorder(.white, lineWidth: 2))
                            .offset(x: 9, y: -9)
                    }
                }
            Image(systemName: "triangle.fill").font(.system(size: 10)).foregroundStyle(.white).rotationEffect(.degrees(180))
        }
        .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
    }
}

struct LiveFriend: Identifiable {
    let person: Person
    let spot: LiveSpot
    var id: String { person.id }
}

/// A friend on the map: their picture with a status ring, their name, and how long ago if it's been a while
struct FriendPin: View {
    let person: Person
    let minutesAgo: Int

    var body: some View {
        VStack(spacing: 3) {
            Avatar(person, size: 48, showStatus: true)
                .background(Circle().fill(.background).padding(-2))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            HStack(spacing: 4) {
                Text(person.firstName).font(.caption.weight(.bold))
                if minutesAgo >= 5 { Text("\(minutesAgo)m").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
        }
    }
}

struct FriendCard: View {
    let person: Person

    var body: some View {
        HStack(spacing: 14) {
            Avatar(person, size: 60, showStatus: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(person.name).font(.title3.weight(.bold))
                Text(person.status == .none ? "@\(person.handle)" : person.status.label)
                    .foregroundStyle(person.status.color ?? .secondary).font(.subheadline.weight(.semibold))
            }
            Spacer()
        }
        .padding(20)
    }
}
