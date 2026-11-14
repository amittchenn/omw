// The Map tab, on Apple Maps in omw!'s colors: you with a rippling yellow halo, friends where they are (if they share
// it) with a ring (and a ripple) for what they're up to, a warm yellow-to-coral glow where you all hang out, your saved
// spots as yellow bookmarks, and what's up next flagged by Ticki with everyone's way in drawn as dashed coral lines.
import SwiftUI
import UIKit
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
    @State private var openPlan: PlanRef?
    @State private var query = ""
    @State private var hits: [PlaceHit] = []
    @State private var place: MapPlace?
    @State private var poi: MapFeature?            // the place label you tapped on Apple's map (its own name, exactly)
    @State private var poiAt = Date.distantPast    // when, so the plain tap that came with it doesn't also count
    @State private var pinAt = Date.distantPast    // the same for our own pins (a friend, a memory, a saved place, you)
    @State private var droppedAt = Date.distantPast
    @State private var lookup: Task<Void, Never>?  // the address being looked up for what you tapped (the newest wins)
    @State private var camera: MapCamera?
    @State private var mapSize: CGSize = .zero
    @State private var showSaved = false
    @State private var showMe = false
    @State private var flyTo: FlyTarget?           // where the Mapbox map should fly next
    @State private var mapbox = MapboxSetup.shared
    @FocusState private var searching: Bool
    @Environment(LocationService.self) private var location

    private var live: [LiveFriend] {
        session.friends.compactMap { f in
            guard let spot = session.spots[f.id], spot.isFresh else { return nil }
            return LiveFriend(person: f, spot: spot)
        }
    }

    /// friends' photos where they took them, like Snap Map: the newest at each place, with how many there are
    private func isUpNextSpot(_ spot: PhotoSpot) -> Bool {
        guard let venue = session.upNext?.venue else { return false }
        return abs(spot.post.venue[0] - venue.latitude) < 0.0008 && abs(spot.post.venue[1] - venue.longitude) < 0.0008  // ~80 m
    }

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
            // the map fills the screen; the search bar sits in a fixed place on top of it (it used to ride on the map's
            // safe area, which shifted it around whenever anything on the map changed)
            ZStack(alignment: .top) {
                mapLayer.ignoresSafeArea()
                searchBar.frame(maxWidth: .infinity)
            }
            // the friend bar floats over the map with room underneath, so Apple's "Maps · Legal" mark (which has to stay
            // visible) sits tucked along the bottom edge instead of hovering above the bar
            .overlay(alignment: .bottom) {
                // a tapped place: our own card floating over the bottom of the map (always the same size and margins),
                // in place of the friend bar. Swipe it down or tap ✕ to close.
                if let p = place {
                    PlaceCard(place: p) { closePlace() }
                        .id(p.id)
                        .padding(.horizontal, 10).padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    friendBar.padding(.bottom, 36)  // room underneath for the map's logo and ⓘ, just above the tab bar
                }
            }
            .animation(.snappy(duration: 0.3), value: place?.id)
            .sensoryFeedback(.selection, trigger: place?.id)
            .onChange(of: somethingOpen) { _, open in if open { dropStray() } }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else { hits = []; return }
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                let near = location.last?.coordinate ?? session.me?.home ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
                hits = await API.suggestPlaces(q, near: (near.latitude, near.longitude))
            }
            .task { await mapbox.load() }
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
                    poi = nil
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
            .sheet(item: $openPlan) { ref in
                NavigationStack { PlanDetailView(id: ref.id).withProfileRoutes() }.withOmw()
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
    /// the map itself: Mapbox in omw!'s colors once its token has arrived from the server (and the Mapbox package is
    /// in the project), otherwise Apple Maps with omw!'s pins on top
    @ViewBuilder var mapLayer: some View {
        #if canImport(MapboxMaps)
        if mapbox.token != nil {
            OmwMapbox(fly: flyTo, heat: heat, live: live, photoSpots: photoSpots, saved: session.saved, place: place,
                      next: session.upNext, me: session.me, here: location.last?.coordinate,
                      onTap: { c in
                          searching = false
                          Task { if let p = await MapPlace.at(c) { place = p } }
                      },
                      onPoi: { name, c in
                          searching = false
                          place = MapPlace(name: name, address: "", lat: c.latitude, lng: c.longitude)
                      },
                      onFriend: { selected = $0 }, onPhoto: { openPost = $0 },
                      onSaved: { s in place = MapPlace(name: s.name, address: s.address, lat: s.lat, lng: s.lng) },
                      onMe: { showMe = true })
        } else {
            appleMap
        }
        #else
        appleMap
        #endif
    }

    /// Apple Maps (the backup), with omw!'s pins, glow and plan flag on top
    var appleMap: some View {
          MapReader { proxy in
            Map(position: $position, selection: $poi) {
                // a warm omw! glow where your friends hang out (their memories and your plans): yellow fading into coral
                ForEach(heat) { h in
                    MapCircle(center: h.coordinate, radius: 460).foregroundStyle(Color.sun.opacity(0.10))
                    MapCircle(center: h.coordinate, radius: 240).foregroundStyle(Color.sun.opacity(0.18))
                    MapCircle(center: h.coordinate, radius: 100).foregroundStyle(Color.coral.opacity(0.26))
                }
                // what's up next: everyone heading in, as dashed coral lines from where they are to the spot, and the
                // spot itself flagged with Ticki and how long till it starts
                if let next = session.upNext, let venue = next.venue {
                    ForEach(live.filter { next.attendees.contains($0.person.id) }) { item in
                        MapPolyline(coordinates: [item.spot.coordinate, venue])
                            .stroke(Color.coral.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 7]))
                    }
                    Annotation(next.venueName, coordinate: venue, anchor: .bottom) {
                        HangoutFlag(hangout: next)
                            .onTapGesture { ownPin(); openPlan = PlanRef(id: next.id) }  // the plan itself
                    }
                    .annotationTitles(.hidden)
                }
                // you, as your picture (like Snap Map's "Me")
                UserAnnotation { _ in
                    MePin(person: session.me).onTapGesture { ownPin(); showMe = true }  // you, like anyone else: your profile
                }
                // a memory at the same spot as what's up next would sit on top of its flag: the flag wins there
                ForEach(photoSpots.filter { !isUpNextSpot($0) }) { spot in
                    Annotation(spot.post.venueName, coordinate: CLLocationCoordinate2D(latitude: spot.post.venue[0], longitude: spot.post.venue[1]), anchor: .bottom) {
                        PhotoPin(spot: spot).onTapGesture { ownPin(); openPost = spot.post }
                    }
                    .annotationTitles(.hidden)
                }
                ForEach(session.saved) { s in
                    Annotation(s.name, coordinate: s.coordinate) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 30, height: 30)
                            .background(Color.sun, in: Circle())
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                            .onTapGesture { ownPin(); poi = nil; place = MapPlace(name: s.name, address: s.address, lat: s.lat, lng: s.lng) }
                    }
                    .annotationTitles(.hidden)
                }
                // a label you tapped is already lifted by the map itself; anything else (a dropped pin, a search) gets ours
                if let place, poi == nil {
                    Marker(place.name, systemImage: place.isPin ? "mappin" : "mappin.circle.fill", coordinate: place.coordinate).tint(Color.coral)
                }
                ForEach(live) { item in
                    Annotation(item.person.firstName, coordinate: item.spot.coordinate, anchor: .bottom) {
                        FriendPin(person: item.person, minutesAgo: Int(Date.now.timeIntervalSince(item.spot.at) / 60))
                            .onTapGesture { ownPin(); selected = item.person }
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .including([.cafe, .restaurant, .bakery, .nightlife, .park, .museum, .movieTheater, .stadium, .university])))
            // omw!'s warm edge: the top of the map fades into the app's cream / plum-ink behind the search bar
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color.omwBG, Color.omwBG.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
            // like Apple and Google Maps: a place's label opens exactly that place; a tap on nothing in particular
            // closes the card if one is open, or else drops a pin there with its street address
            .mapFeatureSelectionDisabled { $0.kind == .territory }
            .onChange(of: poi) { _, f in
                guard let f else { return }
                poiAt = .now
                open(f, proxy)
            }
            // alongside the map's own tap (which is what selects a label), not instead of it
            .simultaneousGesture(SpatialTapGesture().onEnded { tapped($0.location, proxy) })
            .onMapCameraChange(frequency: .onEnd) { camera = $0.camera }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { mapSize = $0 }
          }
            .mapControls {
                MapCompass()  // only shows up when the map's turned; our own "find me" sits under Saved
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
                roundButton("bookmark.fill", tint: .sun, label: "Saved places") { showSaved = true }
            }
            // find me: right under Saved, the same size and style, so the corner lines up
            if hits.isEmpty || query.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack {
                    Spacer()
                    roundButton("location.fill", tint: .coral, label: "Show where I am") {
                        if let here = location.last?.coordinate { fly(to: here) }
                        else { withAnimation { position = .userLocation(followsHeading: false, fallback: .automatic) } }
                    }
                }
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

    /// a round map button: the same 46-point circle for Saved and Find me
    private func roundButton(_ symbol: String, tint: Color, label: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 17, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
        .buttonStyle(Pressable())
        .accessibilityLabel(label)
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
            poi = nil
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

    /// one of our own pins was tapped: that's what you meant, so a pin dropped by the same tap goes away
    func ownPin() {
        pinAt = .now
        dropStray()
    }

    /// a pin dropped a moment ago by a tap that was really meant for something else
    func dropStray() {
        if place?.isPin == true, Date.now.timeIntervalSince(droppedAt) < 1.5 { closePlace() }
    }

    /// a plan, a memory, a friend or your profile is open over the map
    var somethingOpen: Bool { openPlan != nil || openPost != nil || selected != nil || showMe }

    func closePlace() {
        lookup?.cancel()
        withAnimation(.snappy(duration: 0.3)) { place = nil; poi = nil }
    }

    /// a plain tap on the map. A tap on a place's label also selects it a moment later (that wins, so wait a beat)
    func tapped(_ point: CGPoint, _ proxy: MapProxy) {
        searching = false
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            if Date.now.timeIntervalSince(poiAt) < 0.8 || Date.now.timeIntervalSince(pinAt) < 0.8 || somethingOpen { return }
            if place != nil { closePlace(); return }  // tapping away closes the card
            guard let c = proxy.convert(point, from: .local) else { return }
            dropPin(at: c, proxy)
        }
    }

    /// a place's label: the card opens at once with its own name; the address follows from Apple
    func open(_ f: MapFeature, _ proxy: MapProxy) {
        lookup?.cancel()
        let p = MapPlace(name: f.title ?? "Place", address: "", lat: f.coordinate.latitude, lng: f.coordinate.longitude)
        place = p
        reveal(p.coordinate, proxy)
        lookup = Task {
            guard let item = try? await MKMapItemRequest(feature: f).mapItem, !Task.isCancelled, place?.id == p.id else { return }
            let pm = item.placemark
            let street = [pm.subThoroughfare, pm.thoroughfare].compactMap { $0 }.joined(separator: " ")
            place?.address = [street.isEmpty ? nil : street, pm.locality].compactMap { $0 }.joined(separator: ", ")
        }
    }

    /// somewhere with no label: a pin right there (straight away), named by its street address once Apple has it,
    /// never snapped to whichever business happens to be nearest
    func dropPin(at c: CLLocationCoordinate2D, _ proxy: MapProxy) {
        lookup?.cancel()
        droppedAt = .now
        let p = MapPlace(name: MapPlace.finding, address: "", lat: c.latitude, lng: c.longitude, isPin: true)
        place = p
        reveal(c, proxy)
        lookup = Task {
            let named = await MapPlace.describe(c)
            guard !Task.isCancelled, place?.id == p.id else { return }
            place?.name = named.name
            place?.address = named.address
        }
    }

    /// keep what you tapped in view: if the card (bottom half) or the search bar would cover it, slide the map
    func reveal(_ c: CLLocationCoordinate2D, _ proxy: MapProxy) {
        guard mapSize.height > 0, let pt = proxy.convert(c, to: .local) else { return }
        let h = mapSize.height
        guard pt.y > h * 0.48 || pt.y < 150 else { return }
        let centre = CGPoint(x: mapSize.width / 2, y: h / 2 + (pt.y - h * 0.32))
        guard let to = proxy.convert(centre, from: .local) else { return }
        let cam = camera
        withAnimation(.snappy(duration: 0.45)) {
            position = .camera(MapCamera(centerCoordinate: to, distance: cam?.distance ?? 1400,
                                         heading: cam?.heading ?? 0, pitch: cam?.pitch ?? 0))
        }
    }

    func fly(to c: CLLocationCoordinate2D) {
        flyTo = FlyTarget(coordinate: c)  // Mapbox
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
        // Google first (through our server): the place right there, by its real name, with its id, so the name, the
        // photos and the rating on the card are all the same place
        struct Here: Decodable { let name: String?; let address: String?; let lat: Double?; let lng: Double?; let kind: String?; let id: String? }
        if let g = try? await API.get("/place-name", ["lat": "\(c.latitude)", "lng": "\(c.longitude)"], as: Here.self),
           g.kind == "place", let name = g.name, !name.isEmpty {
            let short = (g.address ?? "").split(separator: ",").prefix(2).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
            return MapPlace(name: name, address: short, lat: g.lat ?? c.latitude, lng: g.lng ?? c.longitude,
                            googleId: (g.id?.isEmpty == false) ? g.id : nil)
        }
        // nothing named there on Google: Apple's points of interest, then the street address
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
        let named = await describe(c)
        return MapPlace(name: named.name, address: named.address, lat: c.latitude, lng: c.longitude, isPin: true)
    }
}

extension MapPlace {
    /// a name for a spot with no label, like Apple Maps gives a dropped pin: its street address; else the park or
    /// landmark it's in ("Golden Gate Park"); else the street, the neighbourhood or the city; and only if Apple can't
    /// say anything at all (or keeps refusing), its coordinates. Never just "Dropped pin".
    static func describe(_ c: CLLocationCoordinate2D) async -> (name: String, address: String) {
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        var pm = try? await CLGeocoder().reverseGeocodeLocation(here).first
        if pm == nil, !Task.isCancelled {  // Apple throttles a burst of lookups: one more try a moment later
            try? await Task.sleep(for: .seconds(1.2))
            pm = try? await CLGeocoder().reverseGeocodeLocation(here).first
        }
        let city = [pm?.locality, pm?.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        if let pm {
            let street = [pm.subThoroughfare, pm.thoroughfare].compactMap { $0 }.joined(separator: " ")
            if pm.subThoroughfare != nil, !street.isEmpty { return (street, city) }
            if let area = pm.areasOfInterest?.first, !area.isEmpty { return (area, [pm.subLocality, pm.locality].compactMap { $0 }.joined(separator: ", ")) }
            if let road = pm.thoroughfare { return (road, [pm.subLocality, pm.locality].compactMap { $0 }.joined(separator: ", ")) }
            if let hood = pm.subLocality { return (hood, city) }
            if let name = pm.name, !name.isEmpty { return (name, city) }
            if let town = pm.locality { return (town, pm.administrativeArea ?? "") }
        }
        let lat = String(format: "%.4f° %@", abs(c.latitude), c.latitude >= 0 ? "N" : "S")
        let lng = String(format: "%.4f° %@", abs(c.longitude), c.longitude >= 0 ? "E" : "W")
        return ("Pinned spot", "\(lat), \(lng)")
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
                            Image(systemName: "bookmark.fill").foregroundStyle(Color.sunText)  // same as the map's Saved button
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
    var googleId: String? = nil  // Google's id for it, so the card's photos and rating are that exact place
    var isPin = false            // a spot dropped on the map, not a named place: no Google details or ratings
    static let finding = "Finding address…"
    var resolving: Bool { isPin && name == Self.finding }  // a pin whose address is still on its way
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
    @State private var loaded = false
    @State private var street: String?
    @State private var photoRefs: [String]?   // Google's photos, once the first one has really loaded
    @State private var gallery: GalleryStart?
    @State private var streetImage: UIImage?  // Apple's street view as a plain picture, when Google has none
    @State private var buzz: Int?  // places to eat and drink within a 5-minute walk

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            photos
            VStack(alignment: .leading, spacing: 4) {
                Text(place.name).font(.title3.weight(.bold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(place.resolving ? Color.secondary : Color.primary)
                facts
                if !place.address.isEmpty {
                    Text(place.address).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                // how lively it is around here (Google's count of places to eat and drink within a 5-minute walk)
                if let buzz, buzz > 0 {
                    Label(buzz >= 25 ? "Lively area · \(buzz) spots to eat & drink nearby" : buzz >= 8 ? "\(buzz) spots to eat & drink nearby" : "Quiet area",
                          systemImage: buzz >= 25 ? "flame.fill" : "fork.knife")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(buzz >= 25 ? Color.coral : Color.secondary)
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
                if !place.isPin { action("star", "Rate") { rating = true } }
                action("arrow.triangle.turn.up.right.diamond", "Go") {
                    going = DirectionsTarget(name: place.name, coordinate: place.coordinate, mode: session.me?.travelMode ?? "driving")
                }
            }
            .disabled(place.resolving)  // a moment, so nothing gets saved or planned as "Finding address…"
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
        .fullScreenCover(item: $gallery) { g in
            PhotoGallery(title: place.name, photos: (photoRefs ?? []).map { Self.photoURL($0, 1600) }, start: g.index)
        }
        .task(id: place.id) {
            loaded = false; info = nil; street = nil; streetImage = nil; photoRefs = nil; buzz = nil  // a new place: start clean
            var ask = ["name": place.name, "lat": "\(place.lat)", "lng": "\(place.lng)"]
            if let id = place.googleId { ask["id"] = id }
            // a dropped pin isn't a business: asking Google by name would match a random one nearby
            if !place.isPin { info = try? await API.get("/places/info", ask, as: PlaceInfo.self) }
            // Google's photos only if the first one actually comes through (else the street view, below)
            if let refs = info?.photos, let first = refs.first,
               await ImageLoader.load("\(API.base.absoluteString)/place-photo?ref=\(first)&w=600") != nil {
                photoRefs = refs
            }
            if photoRefs == nil {
                // is there Street View here? (the server answers 404 if not; phones cache the picture for a day)
                let url = "\(API.base.absoluteString)/street-view?lat=\(place.lat)&lng=\(place.lng)"
                if let u = URL(string: url), let (_, r) = try? await URLSession.shared.data(from: u),
                   (r as? HTTPURLResponse)?.statusCode == 200 { street = url }
            }
            if photoRefs == nil, street == nil,
               let scene = try? await MKLookAroundSceneRequest(coordinate: place.coordinate).scene {
                let options = MKLookAroundSnapshotter.Options()
                options.size = CGSize(width: 640, height: 280)
                streetImage = try? await MKLookAroundSnapshotter(scene: scene, options: options).snapshot.image
            }
            loaded = true
            buzz = (try? await API.get("/buzz", ["lat": "\(place.lat)", "lng": "\(place.lng)"], as: Buzz.self))?.count
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
                if let refs = photoRefs, !refs.isEmpty {
                    // swipe along them; tap one to see them all full screen
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(Array(refs.enumerated()), id: \.element) { i, ref in
                                Button { gallery = GalleryStart(index: i) } label: {
                                    RemoteImage(source: Self.photoURL(ref, 600))
                                        .frame(width: refs.count == 1 ? 340 : 200, height: 140)
                                        .clipShape(.rect(cornerRadius: 14))
                                }
                                .buttonStyle(Pressable())
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .overlay(alignment: .bottomTrailing) {
                        if refs.count > 1 {
                            Label("\(refs.count)", systemImage: "photo.on.rectangle")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
                } else if let street {
                    // no photos: the real street outside it (Google Street View, like the photos, so it's always the
                    // same kind of picture)
                    RemoteImage(source: street)
                } else if let streetImage {
                    // Google has nothing here: Apple's street view, taken as a plain picture (no badges, no buttons)
                    Image(uiImage: streetImage).resizable().scaledToFill()
                } else if loaded && usesMapbox {
                    miniMap  // nowhere to see it: the spot on omw!'s map
                } else if loaded {
                    Map(initialPosition: .camera(MapCamera(centerCoordinate: place.coordinate, distance: 600, heading: 0, pitch: 45))) {
                        Marker(place.name, coordinate: place.coordinate).tint(Color.coral)  // the same pin as on the big map
                    }
                    .allowsHitTesting(false)
                } else {
                    Color.clear.shimmer()
                }
            }
            .clipShape(.rect(cornerRadius: 14))
    }

    static func photoURL(_ ref: String, _ width: Int) -> String { "\(API.base.absoluteString)/place-photo?ref=\(ref)&w=\(width)" }

    /// the map tab is on Mapbox (so the card should be too)
    private var usesMapbox: Bool {
        #if canImport(MapboxMaps)
        MapboxSetup.shared.token != nil
        #else
        false
        #endif
    }

    @ViewBuilder private var miniMap: some View {
        #if canImport(MapboxMaps)
        OmwMiniMap(coordinate: place.coordinate)
        #else
        EmptyView()
        #endif
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

/// how many places to eat and drink are around a spot (/buzz)
struct Buzz: Decodable { let count: Int? }

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
                .background { if let c = person.status.color { Pulse(color: c).frame(width: 48, height: 48) } }
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
    @Environment(Session.self) private var session

    var body: some View {
        HStack(spacing: 14) {
            Avatar(person, size: 60, showStatus: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(person.name).font(.title3.weight(.bold))
                Text(person.status == .none ? "@\(person.handle)" : session.statusLabel(person))
                    .foregroundStyle(session.statusColor(person) ?? .secondary).font(.subheadline.weight(.semibold))
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
        }
        .opensProfile(person.id)
        .padding(20)
    }
}

/// a soft ring that keeps rippling out from a pin, so the map feels alive (you, and friends who are out or on their way)
struct Pulse: View {
    var color: Color

    // driven by the clock, not a forever-repeating animation: those leak into whatever is laid out at the same
    // moment and made the map's search bar bob up and down
    var body: some View {
        TimelineView(.animation) { t in
            let p = (t.date.timeIntervalSinceReferenceDate / 1.8).truncatingRemainder(dividingBy: 1)
            let eased = 1 - pow(1 - p, 2)
            Circle()
                .fill(color.opacity(0.45))
                .scaleEffect(1 + 1.1 * eased)
                .opacity(0.9 * (1 - p))
        }
        .allowsHitTesting(false)
    }
}

/// the spot of the plan that's up next: Ticki on a little yellow flag with what it is and how long till it starts
struct HangoutFlag: View {
    let hangout: Hangout

    var body: some View {
        VStack(spacing: -4) {
            HStack(spacing: 6) {
                Ticki(mood: hangout.start.timeIntervalSinceNow < 30 * 60 ? .run : .idle).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(hangout.venueName.isEmpty ? hangout.title : hangout.venueName).font(.caption.weight(.heavy)).lineLimit(1)
                    // a live countdown once it's close; before that, the day and time read better than "19 hr, 22 min"
                    Group {
                        if hangout.start.timeIntervalSinceNow < 2 * 3600 {
                            Text(hangout.start, style: .relative)
                        } else {
                            Text(Calendar.current.isDateInToday(hangout.start) ? "Today · \(hangout.start.formatted(date: .omitted, time: .shortened))"
                                 : Calendar.current.isDateInTomorrow(hangout.start) ? "Tomorrow · \(hangout.start.formatted(date: .omitted, time: .shortened))"
                                 : hangout.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        }
                    }
                    .font(.caption2.weight(.bold)).monospacedDigit()
                }
                .foregroundStyle(.black)
            }
            .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
            .background(Color.sun, in: Capsule())
            .overlay(Capsule().strokeBorder(.white, lineWidth: 2))
            .frame(maxWidth: 180)
            Image(systemName: "triangle.fill").font(.system(size: 12)).foregroundStyle(Color.sun).rotationEffect(.degrees(180))
        }
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }
}

/// you on the map: your picture in a yellow ring with a yellow ripple, and "Me"
struct MePin: View {
    let person: Person?

    var body: some View {
        VStack(spacing: 3) {
            Avatar(person, size: 46)
                .overlay(Circle().strokeBorder(Color.sun, lineWidth: 3))
                .background(Pulse(color: .sun).frame(width: 46, height: 46))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            Text("Me").font(.caption.weight(.heavy))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color.sun, in: Capsule()).foregroundStyle(.black)
        }
    }
}

/// a place for the map to fly to (each one new, even to the same spot)
struct FlyTarget: Equatable {
    let coordinate: CLLocationCoordinate2D
    let id = UUID()
    static func == (a: FlyTarget, b: FlyTarget) -> Bool { a.id == b.id }
}

struct GalleryStart: Identifiable {
    let index: Int
    var id: Int { index }
}

/// a place's photos full screen: swipe between them, pinch or double-tap to zoom, swipe down or ✕ to close
struct PhotoGallery: View {
    let title: String
    let photos: [String]
    @State var page: Int
    @Environment(\.dismiss) private var dismiss
    @State private var drop: CGFloat = 0

    init(title: String, photos: [String], start: Int) {
        self.title = title
        self.photos = photos
        _page = State(initialValue: start)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(abs(drop) / 400, 0.6)).ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Array(photos.enumerated()), id: \.offset) { i, url in
                    ZoomablePhoto(source: url).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: drop)
            .simultaneousGesture(DragGesture(minimumDistance: 20)
                .onChanged { v in if abs(v.translation.height) > abs(v.translation.width) { drop = v.translation.height } }
                .onEnded { v in
                    if abs(v.translation.height) > 140 { dismiss() } else { withAnimation(.snappy) { drop = 0 } }
                })
        }
        .overlay(alignment: .top) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    Text("\(page + 1) of \(photos.count)").font(.caption.weight(.semibold)).opacity(0.7)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline)
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Close")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .opacity(drop == 0 ? 1 : 0.4)
        }
        .statusBarHidden()
        .sensoryFeedback(.selection, trigger: page)
    }
}

/// one photo you can pinch or double-tap to zoom into
struct ZoomablePhoto: View {
    let source: String
    @State private var scale: CGFloat = 1
    @State private var settled: CGFloat = 1

    var body: some View {
        RemoteImageFit(source: source)
            .scaleEffect(scale)
            .gesture(MagnifyGesture()
                .onChanged { scale = max(1, min(settled * $0.magnification, 4)) }
                .onEnded { _ in settled = scale; if scale < 1.05 { withAnimation(.snappy) { scale = 1; settled = 1 } } })
            .onTapGesture(count: 2) {
                withAnimation(.snappy) { scale = scale > 1 ? 1 : 2.2; settled = scale }
            }
    }
}

/// a photo shown whole (fit, not cropped), with a shimmer while it loads
struct RemoteImageFit: View {
    let source: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)).frame(height: 260).shimmer().padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: source) {
            let loaded = await ImageLoader.load(source)
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }
}

/// a plan opened from its flag on the map
struct PlanRef: Identifiable { let id: String }
