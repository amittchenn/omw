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

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                UserAnnotation()
                ForEach(photoSpots) { spot in
                    Annotation(spot.post.venueName, coordinate: CLLocationCoordinate2D(latitude: spot.post.venue[0], longitude: spot.post.venue[1]), anchor: .bottom) {
                        PhotoPin(spot: spot).onTapGesture { openPost = spot.post }
                    }
                    .annotationTitles(.hidden)
                }
                ForEach(live) { item in
                    Annotation(item.person.firstName, coordinate: item.spot.coordinate, anchor: .bottom) {
                        FriendPin(person: item.person, minutesAgo: Int(Date.now.timeIntervalSince(item.spot.at) / 60))
                            .onTapGesture { selected = item.person }
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .including([.cafe, .restaurant, .park, .bakery, .museum, .movieTheater, .nightlife])))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .overlay(alignment: .top) {
                if live.isEmpty {
                    Text(session.friends.isEmpty ? "Add friends to see them here" : "No friends sharing their location right now")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
            .onAppear { location.apply() }
            .sheet(item: $openPost) { post in
                NavigationStack { PostDetailView(id: post.id).withProfileRoutes() }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $selected) { f in
                FriendCard(person: f)
                    .presentationDetents([.height(190)])
                    .presentationDragIndicator(.visible)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
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
