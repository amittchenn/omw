// The Map tab, like Snap Map, on Apple Maps: your friends where they are (if they share it) as their pictures with a
// ring for what they're up to, and you. Tap a friend for their card.
import SwiftUI
import MapKit
import CoreLocation
#if canImport(LocationEssentials)
import LocationEssentials  // where iOS 26 keeps coordinates and distances
#endif

struct FriendsMapView: View {
    @Environment(Session.self) private var session
    // leaning back a little, like Snap Map, so buildings stand up in 3D
    @State private var position: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
    @State private var selected: Person?
    @State private var openPost: Post?
    @State private var query = ""
    @State private var hits: [PlaceHit] = []
    @State private var place: MapPlace?
    @State private var showSaved = false
    @State private var showMe = false
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
          MapReader { proxy in
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
                    .onTapGesture { showMe = true }  // you, like anyone else: your profile
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
            // tap anywhere: the place there (a cafe, a park…), or the address, with Save / Plan here / Rate / Go
            .onTapGesture { point in
                guard let c = proxy.convert(point, from: .local) else { return }
                searching = false
                Task { if let p = await MapPlace.at(c) { place = p } }
            }
          }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            // in the map's safe area, so Apple's own buttons and labels move out of their way
            .safeAreaInset(edge: .top) { searchBar }
            // the friend bar floats over the map with room underneath, so Apple's "Maps · Legal" mark (which has to stay
            // visible) sits tucked along the bottom edge instead of hovering above the bar
            .overlay(alignment: .bottom) {
                // a tapped place: our own card floating over the bottom of the map (always the same size and margins),
                // in place of the friend bar. Swipe it down or tap ✕ to close.
                if let p = place {
                    PlaceCard(place: p) { withAnimation(.snappy(duration: 0.3)) { place = nil } }
                        .id(p.id)
                        .padding(.horizontal, 10).padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    friendBar.padding(.bottom, 24)
                }
            }
            .animation(.snappy(duration: 0.3), value: place?.id)
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else { hits = []; return }
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                let near = location.last?.coordinate ?? session.me?.home ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
                hits = await API.suggestPlaces(q, near: (near.latitude, near.longitude))
            }
            .onAppear {
                location.apply()
                // tilted, like Snap Map, once we know where you are
                if let here = location.last?.coordinate {
                    position = .camera(MapCamera(centerCoordinate: here, distance: 2200, heading: 0, pitch: 50))
                }
            }
            .sheet(isPresented: $showSaved) {
                SavedList { p in
                    fly(to: p.coordinate)
                    place = p
                }
                .withOmw()
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $openPost) { post in
                NavigationStack { PostDetailView(id: post.id).withProfileRoutes() }.withOmw()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showMe) {
                NavigationStack { ProfileView(uid: session.uid ?? "").withProfileRoutes() }.withOmw()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $selected) { f in
                FriendCard(person: f).withOmw()
                    .presentationDetents([.height(190)])
                    .presentationDragIndicator(.visible)
            }
            .toolbar(.hidden, for: .navigationBar)
            .omwBackground()
        }
    }
}

extension FriendsMapView {
    /// search any place, like Google Maps; and who's sharing (or not) under it
    var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
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
                .frame(maxWidth: .infinity)
                // your saved places (favourites), next to search like Google Maps' Saved
                Button { showSaved = true } label: {
                    Image(systemName: "bookmark.fill").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.omwBlue)
                        .frame(width: 46, height: 46)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }
                .buttonStyle(Pressable())
                .accessibilityLabel("Saved places")
            }

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
    /// along the bottom, like Snap Map: you, your saved places, then your friends (sharing ones first)
    var friendBar: some View {
        // floating faces, no panel: centered when they fit, scrolling once there are more
        ViewThatFits(in: .horizontal) {
            people.frame(maxWidth: .infinity)
            ScrollView(.horizontal) { people }.scrollIndicators(.hidden)
        }
        .padding(.bottom, 10)
    }

    private var people: some View {
        HStack(spacing: 12) {
            bubble(label: "Me", lit: true, tap: { if let here = location.last?.coordinate { fly(to: here) } }) {
                Avatar(session.me, size: 50)
            }
            ForEach(session.friends.sorted { (session.spots[$0.id]?.isFresh == true ? 0 : 1) < (session.spots[$1.id]?.isFresh == true ? 0 : 1) }) { f in
                let spot = session.spots[f.id]
                bubble(label: f.firstName, lit: spot?.isFresh == true, tap: {
                    if let spot, spot.isFresh { fly(to: spot.coordinate) } else { selected = f }
                }) {
                    Avatar(f, size: 50)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func bubble<Face: View>(label: String, lit: Bool, tap: @escaping () -> Void, @ViewBuilder face: () -> Face) -> some View {
        Button(action: tap) {
            VStack(spacing: 5) {
                face()
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    .overlay(alignment: .bottomTrailing) {
                        // sharing where they are right now
                        if lit && label != "Me" { Circle().fill(Color.freeGreen).frame(width: 13, height: 13).overlay(Circle().strokeBorder(.white, lineWidth: 2)) }
                    }
                Text(label).font(.caption2.weight(.heavy)).lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(label == "Me" ? AnyShapeStyle(Color.sun) : AnyShapeStyle(.regularMaterial), in: Capsule())
                    .foregroundStyle(label == "Me" ? Color.black : Color.primary)
            }
            .frame(width: 60)
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

extension MapPlace {
    /// what's at a spot you tapped: the nearest place within ~60 m, else the street address
    static func at(_ c: CLLocationCoordinate2D) async -> MapPlace? {
        let request = MKLocalPointsOfInterestRequest(center: c, radius: 60)
        if let items = try? await MKLocalSearch(request: request).start().mapItems, !items.isEmpty {
            let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
            let best = items.min { here.distance(from: $0.placemark.location ?? here) < here.distance(from: $1.placemark.location ?? here) }
            if let best, let name = best.name {
                let p = best.placemark
                return MapPlace(name: name, address: [p.thoroughfare, p.locality].compactMap { $0 }.joined(separator: ", "),
                                lat: p.coordinate.latitude, lng: p.coordinate.longitude)
            }
        }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)).first
        let street = [placemark?.subThoroughfare, placemark?.thoroughfare].compactMap { $0 }.joined(separator: " ")
        return MapPlace(name: street.isEmpty ? "Dropped pin" : street, address: placemark?.locality ?? "", lat: c.latitude, lng: c.longitude)
    }
}

/// your saved places, like a favourites list: tap one to go there, swipe to remove
struct SavedList: View {
    var open: (MapPlace) -> Void
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(session.saved) { s in
                    Button {
                        dismiss()
                        open(MapPlace(name: s.name, address: s.address, lat: s.lat, lng: s.lng))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bookmark.fill").foregroundStyle(Color.omwBlue)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                if !s.address.isEmpty { Text(s.address).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                    }
                }
                .onDelete { rows in
                    for i in rows { let s = session.saved[i]; session.toggleSaved(name: s.name, address: s.address, lat: s.lat, lng: s.lng) }
                }
            }
            .overlay { if session.saved.isEmpty { ContentUnavailableView("Nothing saved yet", systemImage: "bookmark", description: Text("Tap a place on the map, then Save.")) } }
            .navigationTitle("Saved")
            .omwBackground()
            .navigationBarTitleDisplayMode(.inline)
        }
    }
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

/// what Google knows about a place (the server's /places/info)
struct PlaceInfo: Decodable {
    var rating: Double?
    var reviews: Int?
    var price: String?
    var open: Bool?
    var type: String?
    var photos: [String]?
}

/// The place card, like Google Maps': photos, rating and hours, then Plan here, Save, Rate, Go
struct PlaceCard: View {
    let place: MapPlace
    var close: () -> Void = {}
    @State private var drag: CGFloat = 0
    @Environment(Session.self) private var session
    @State private var planning = false
    @State private var rating = false
    @State private var going: DirectionsTarget?
    @State private var info: PlaceInfo?
    @State private var lookAround: MKLookAroundScene?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            photos
            VStack(alignment: .leading, spacing: 4) {
                Text(place.name).font(.title3.weight(.bold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                facts
                if !place.address.isEmpty {
                    Text(place.address).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                Button { planning = true } label: {
                    Label("Plan here", systemImage: "calendar.badge.plus").font(.headline).frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.borderedProminent).tint(Color.sun).foregroundStyle(.black)
                action(session.isSaved(lat: place.lat, lng: place.lng) ? "bookmark.fill" : "bookmark", "Save") {
                    session.toggleSaved(name: place.name, address: place.address, lat: place.lat, lng: place.lng)
                }
                action("star", "Rate") { rating = true }
                action("arrow.triangle.turn.up.right.diamond", "Go") {
                    going = DirectionsTarget(name: place.name, coordinate: place.coordinate, mode: session.me?.travelMode ?? "driving")
                }
            }
        }
        .padding(14)
        // every place card the same: as wide as the screen allows, just as tall as it needs, solid (not glass over a
        // busy map), with a ✕ and a swipe down to close
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.omwBG, in: .rect(cornerRadius: 26))
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark").font(.footnote.weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(20)
            .accessibilityLabel("Close")
        }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .offset(y: max(0, drag))
        .gesture(DragGesture(minimumDistance: 8)
            .onChanged { drag = $0.translation.height }
            .onEnded { v in
                if v.translation.height > 90 || v.predictedEndTranslation.height > 220 { close() }
                withAnimation(.snappy) { drag = 0 }
            })
        .sensoryFeedback(.selection, trigger: session.saved.count)
        .fullScreenCover(item: $going) { DirectionsView(target: $0).withOmw() }
        .task(id: place.id) {
            loaded = false; info = nil; lookAround = nil  // a new place: start clean
            info = try? await API.get("/places/info", ["name": place.name, "lat": "\(place.lat)", "lng": "\(place.lng)"], as: PlaceInfo.self)
            if info?.photos?.isEmpty != false {
                lookAround = try? await MKLookAroundSceneRequest(coordinate: place.coordinate).scene  // Apple's street view instead
            }
            loaded = true
        }
        .sheet(isPresented: $planning) {
            PlanSheet(start: place.hit).withOmw().presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $rating) {
            RankSheet(place: RankedPlace(name: place.name, address: place.address, venue: [place.lat, place.lng]))
                .withOmw().presentationDetents([.height(380)]).presentationDragIndicator(.visible)
        }
    }

    /// its photos side by side (Google's), or Apple's Look Around of the street, or nothing
    /// the picture at the top, always the same size: its photos side by side (Google's), Apple's Look Around of the
    /// street, or a little map of the spot. Whatever's inside sits in an overlay of a fixed box, so it can never push
    /// the card wider or taller.
    private var photos: some View {
        Color.omwCard2
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .overlay {
                if let refs = info?.photos, !refs.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(refs, id: \.self) { ref in
                                RemoteImage(source: "\(API.base.absoluteString)/place-photo?ref=\(ref)&w=600")
                                    .frame(width: refs.count == 1 ? 340 : 200, height: 140)
                                    .clipShape(.rect(cornerRadius: 14))
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                } else if let lookAround {
                    LookAroundPreview(initialScene: lookAround, allowsNavigation: false, badgePosition: .bottomTrailing)
                } else if loaded {
                    Map(initialPosition: .camera(MapCamera(centerCoordinate: place.coordinate, distance: 600, heading: 0, pitch: 45))) {
                        Marker(place.name, coordinate: place.coordinate).tint(.red)
                    }
                    .allowsHitTesting(false)
                } else {
                    Color.clear.shimmer()
                }
            }
            .clipShape(.rect(cornerRadius: 14))
    }

    /// ★ 4.5 (1,203) · $$ · Café · Open now
    @ViewBuilder private var facts: some View {
        let mine = session.existingKey(for: RankedPlace(name: place.name, address: place.address, venue: [place.lat, place.lng])).flatMap { session.score(of: $0) }
        let parts: [String] = [
            info?.rating.map { r in String(format: "★ %.1f", r) + (info?.reviews.map { " (\($0.formatted()))" } ?? "") },
            info?.price, info?.type,
        ].compactMap { $0 }.filter { !$0.isEmpty }
        if mine != nil || !parts.isEmpty || info?.open != nil {
            HStack(spacing: 6) {
                if let mine {
                    Label("\(Int(mine))", systemImage: "star.fill").font(.caption.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.freeGreen.opacity(0.2), in: Capsule())
                }
                if !parts.isEmpty { Text(parts.joined(separator: " · ")).foregroundStyle(.secondary) }
                if let open = info?.open {
                    Text(open ? "Open" : "Closed").fontWeight(.semibold).foregroundStyle(open ? Color.freeGreen : Color.red)
                }
            }
            .font(.subheadline)
            .lineLimit(1)
        }
    }

    private func action(_ symbol: String, _ label: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .frame(width: 46, height: 46)
                .background(Color.omwCard2, in: Circle())
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
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
        }
        .opensProfile(person.id)
        .padding(20)
    }
}
