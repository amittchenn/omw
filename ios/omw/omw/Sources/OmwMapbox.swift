// The Map tab on Mapbox, in omw!'s own colors: the streets themselves are warm (cream roads and yellow highways by
// day, plum and coral at night), lit for the time of day, with 3D buildings, and omw!'s pins on top (you, friends,
// photos, saved spots, the plan that's up next with everyone's way in). Apple Maps can't be recolored, so this is how
// the map gets omw!'s look. It needs the Mapbox package in Xcode (File > Add Package Dependencies >
// https://github.com/mapbox/mapbox-maps-ios) and MAPBOX_TOKEN on the server; until both are there, the Map tab uses
// Apple Maps (FriendsMapView.appleMap).
import SwiftUI
import CoreLocation
#if canImport(LocationEssentials)
import LocationEssentials  // where iOS 26 keeps coordinates and distances
#endif
#if canImport(MapboxMaps)
import MapboxMaps
#endif

/// Mapbox's public token, from the server's /config (the same one the web app's map uses), remembered on the phone
@MainActor @Observable
final class MapboxSetup {
    static let shared = MapboxSetup()
    private(set) var token: String?

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "mapboxToken"), saved.hasPrefix("pk.") { use(saved) }
    }

    func load() async {
        struct Config: Decodable { let mapbox_token: String? }
        guard let t = (try? await API.get("/config", as: Config.self))?.mapbox_token, t.hasPrefix("pk.") else { return }
        UserDefaults.standard.set(t, forKey: "mapboxToken")
        if t != token { use(t) }
    }

    private func use(_ t: String) {
        #if canImport(MapboxMaps)
        MapboxOptions.accessToken = t
        token = t
        #endif
    }
}

#if canImport(MapboxMaps)
/// a place's spot on its own: a small, tilted 3D look at it in omw!'s colors, with a coral pin (the place card's
/// picture when there are no photos)
struct OmwMiniMap: View {
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        MapboxMaps.Map(initialViewport: .camera(center: coordinate, zoom: 16.6, bearing: 0, pitch: 62)) {
            MapViewAnnotation(coordinate: coordinate) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(.white, Color.coral)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }
            .allowOverlap(true)
            .variableAnchors([ViewAnnotationAnchorConfig(anchor: .bottom)])
        }
        .mapStyle(OmwMapbox.style())
        .ornamentOptions(OrnamentOptions(scaleBar: ScaleBarViewOptions(visibility: .hidden)))
        .allowsHitTesting(false)
    }
}

/// directions on omw!'s map: the route as a thick coral line (with a light edge so it reads on any street), the
/// spot's pin, and you as the blue dot. Before you start it shows the whole way; once you start, it follows you,
/// turned the way you're facing.
struct OmwRouteMap: View {
    let line: [CLLocationCoordinate2D]
    let target: CLLocationCoordinate2D
    let name: String
    let following: Bool
    @State private var viewport: Viewport = .followPuck(zoom: 15)

    var body: some View {
        MapboxMaps.Map(viewport: $viewport) {
            Puck2D(bearing: .heading)
            if line.count > 1 {
                // the route as a real map line (a style layer, like Mapbox's own navigation), on top of everything
                // (3D buildings included, or they hide it when the map's tilted): a light edge, then the coral line
                GeoJSONSource(id: "omw-route")
                    .data(.geometry(.lineString(LineString(line))))
                LineLayer(id: "omw-route-edge", source: "omw-route")
                    .lineColor(StyleColor(UIColor.white))
                    .lineWidth(12)
                    .lineOpacity(0.9)
                    .lineCap(.round)
                    .lineJoin(.round)
                    .slot(Slot.top)
                LineLayer(id: "omw-route-line", source: "omw-route")
                    .lineColor(StyleColor(UIColor(Color.coral)))
                    .lineWidth(7)
                    .lineCap(.round)
                    .lineJoin(.round)
                    .slot(Slot.top)
            }
            MapViewAnnotation(coordinate: target) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 34)).foregroundStyle(.white, Color.coral)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }
            .allowOverlap(true)
            .variableAnchors([ViewAnnotationAnchorConfig(anchor: .bottom)])
        }
        .mapStyle(OmwMapbox.style())
        .ornamentOptions(OrnamentOptions(scaleBar: ScaleBarViewOptions(visibility: .hidden)))
        .onAppear { frame() }
        .onChange(of: line.count) { frame() }
        .onChange(of: following) { frame() }
    }

    /// the whole route with room for the cards over the map, or following you once you've started
    private func frame() {
        withViewportAnimation(.default(maxDuration: 0.8)) {
            if following {
                viewport = .followPuck(zoom: 16.5, bearing: .heading, pitch: 35)  // tilted a little, so the way ahead shows
            } else if line.count > 1 {
                viewport = .overview(geometry: LineString(line), geometryPadding: EdgeInsets(top: 150, leading: 40, bottom: 260, trailing: 40))
            }
        }
    }
}

struct OmwMapbox: View {
    let fly: FlyTarget?
    let heat: [HeatSpot]
    let live: [LiveFriend]
    let photoSpots: [PhotoSpot]
    let saved: [SavedPlace]
    let place: MapPlace?
    let next: Hangout?
    let me: Person?
    let here: CLLocationCoordinate2D?
    var onTap: (CLLocationCoordinate2D) -> Void
    var onFriend: (Person) -> Void
    var onPhoto: (Post) -> Void
    var onSaved: (SavedPlace) -> Void
    var onMe: () -> Void

    @State private var viewport: Viewport = .idle
    @State private var started = false

    private struct Way: Identifiable {
        let id: String
        let line: [CLLocationCoordinate2D]
    }

    var body: some View {
        MapboxMaps.Map(viewport: $viewport) {
            // a warm glow where your friends hang out
            ForEvery(heat) { h in
                MapViewAnnotation(coordinate: h.coordinate) {
                    Circle()
                        .fill(RadialGradient(colors: [Color.coral.opacity(0.5), Color.sun.opacity(0.28), .clear],
                                             center: .center, startRadius: 0, endRadius: 70))
                        .frame(width: 140, height: 140)
                        .allowsHitTesting(false)
                }
                .allowOverlap(true)
            }
            // what's up next: everyone's way in, and the spot flagged by Ticki
            if let next, let venue = next.venue {
                // everyone's way in: coral lines (a style layer, so they draw above the streets)
                GeoJSONSource(id: "omw-ways")
                    .data(.featureCollection(FeatureCollection(features: ways(next, venue).map { Feature(geometry: .lineString(LineString($0.line))) })))
                LineLayer(id: "omw-ways-line", source: "omw-ways")
                    .lineColor(StyleColor(UIColor(Color.coral)))
                    .lineWidth(4)
                    .lineOpacity(0.9)
                    .lineCap(.round)
                    .slot(Slot.middle)
                MapViewAnnotation(coordinate: venue) { HangoutFlag(hangout: next) }
                    .allowOverlap(true)
                    .variableAnchors([ViewAnnotationAnchorConfig(anchor: .bottom)])
            }
            ForEvery(photoSpots) { spot in
                MapViewAnnotation(coordinate: CLLocationCoordinate2D(latitude: spot.post.venue[0], longitude: spot.post.venue[1])) {
                    PhotoPin(spot: spot).onTapGesture { onPhoto(spot.post) }
                }
                .variableAnchors([ViewAnnotationAnchorConfig(anchor: .bottom)])
            }
            ForEvery(saved) { s in
                MapViewAnnotation(coordinate: s.coordinate) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 30, height: 30)
                        .background(Color.sun, in: Circle())
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        .onTapGesture { onSaved(s) }
                }
            }
            if let place {
                MapViewAnnotation(coordinate: place.coordinate) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 34)).foregroundStyle(.white, Color.coral)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                }
                .allowOverlap(true)
                .variableAnchors([ViewAnnotationAnchorConfig(anchor: .bottom)])
            }
            ForEvery(live) { item in
                MapViewAnnotation(coordinate: item.spot.coordinate) {
                    FriendPin(person: item.person, minutesAgo: Int(Date.now.timeIntervalSince(item.spot.at) / 60))
                        .onTapGesture { onFriend(item.person) }
                }
                .allowOverlap(true)
                .variableAnchors([ViewAnnotationAnchorConfig(anchor: .bottom)])
            }
            if let here {
                MapViewAnnotation(coordinate: here) {
                    MePin(person: me).onTapGesture(perform: onMe)
                }
                .allowOverlap(true)
            }
        }
        .mapStyle(Self.style())
        // the map runs edge to edge, under the tab bar too, so Mapbox's logo and ⓘ (which have to stay visible) are
        // lifted above the tab bar
        .ornamentOptions(OrnamentOptions(scaleBar: ScaleBarViewOptions(visibility: .hidden),
                                         logo: LogoViewOptions(margins: CGPoint(x: 12, y: 6)),
                                         attributionButton: AttributionButtonOptions(margins: CGPoint(x: 12, y: 6))))
        .onMapTapGesture { context in onTap(context.coordinate) }
        // fades into omw!'s warm top edge behind the search bar
        .overlay(alignment: .top) {
            LinearGradient(colors: [Color.omwBG, Color.omwBG.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
        .onAppear { start() }
        .onChange(of: here?.latitude) { start() }
        .onChange(of: fly) {
            guard let fly else { return }
            withViewportAnimation(.fly) {
                viewport = .camera(center: fly.coordinate, zoom: 16, bearing: 0, pitch: 58)
            }
        }
    }

    /// once we know where you are: tilted over you, so the buildings stand up in 3D
    private func start() {
        guard !started, let here else { return }
        started = true
        viewport = .camera(center: here, zoom: 14.5, bearing: 0, pitch: 55)
    }

    private func ways(_ next: Hangout, _ venue: CLLocationCoordinate2D) -> [Way] {
        live.filter { next.attendees.contains($0.person.id) }.map { Way(id: $0.person.id, line: [$0.spot.coordinate, venue]) }
    }

    /// Mapbox Standard, tuned to omw!: lit for the time of day, warm roads (cream and yellow by day, coral at night),
    /// soft greens, plum-tinted labels at night
    static func style() -> MapStyle {
        let hour = Calendar.current.component(.hour, from: .now)
        let night = hour >= 20 || hour < 5
        let light = night ? "night" : hour < 7 ? "dawn" : hour >= 17 ? "dusk" : "day"
        return MapStyle(uri: .standard, configuration: [
            "lightPreset": .string(light),
            "show3dObjects": .boolean(true),
            "showPointOfInterestLabels": .boolean(true),
            "colorMotorways": .string(night ? "#F2694A" : "#FFD23F"),
            "colorTrunks": .string(night ? "#C9472F" : "#FFE27A"),
            "colorRoads": .string(night ? "#4A3A5E" : "#FFF4E0"),
            "colorGreenspace": .string(night ? "#2E3B33" : "#CDEBB5"),
            "colorWater": .string(night ? "#1D1A33" : "#9FD3F2"),
            "colorPlaceLabels": .string(night ? "#FFE8C2" : "#3A2A1E"),
            "colorPointOfInterestLabels": .string(night ? "#FFB49E" : "#C9472F"),
        ])
    }
}
#endif
