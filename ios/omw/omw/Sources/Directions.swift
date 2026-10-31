// Directions inside omw!: the route on the map, how long it takes, and turn-by-turn steps that follow you as you go
// (spoken, if you want). Apple's MapKit routes: driving and walking draw a route; cycling follows the walking route at
// bike speed; transit gives the time only (Apple doesn't hand apps transit routes), so it shows the walk alongside.
import SwiftUI
import MapKit
import AVFoundation
import CoreLocation
#if canImport(LocationEssentials)
import LocationEssentials  // where iOS 26 keeps coordinates and distances
#endif

struct DirectionsTarget: Identifiable {
    let name: String
    let coordinate: CLLocationCoordinate2D
    var mode: String = "driving"   // driving, walking, cycling or transit
    var start: Date? = nil         // the plan's start, when these are directions to a hangout
    var leaveBy: Date? = nil       // the plan's "leave by" for you (traffic + how late you usually run)
    var id: String { "\(coordinate.latitude),\(coordinate.longitude)" }
}

struct DirectionsView: View {
    let target: DirectionsTarget
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "driving"
    @State private var route: MKRoute?
    @State private var transitMinutes: Double?
    @State private var trafficMinutes: Double?   // the server's trip time (Google, with live traffic), like the plan uses
    @State private var failed = false
    @State private var position: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
    @State private var step = 0
    @State private var going = false
    @State private var voice = true
    @State private var showSteps = false
    @State private var speaker = AVSpeechSynthesizer()

    private struct Way: Identifiable { let id: String, symbol: String }
    private static let modes = [Way(id: "driving", symbol: "car.fill"), Way(id: "walking", symbol: "figure.walk"),
                                Way(id: "cycling", symbol: "bicycle"), Way(id: "transit", symbol: "tram.fill")]

    var body: some View {
        // the map fills the screen; the top card and the bottom panel float over it with even margins
        ZStack {
            mapLayer.ignoresSafeArea()
            VStack(spacing: 0) {
                if going { nextTurn } else { header }
                Spacer(minLength: 0)
                footer
            }
            .frame(maxWidth: .infinity)
        }
        .task(id: mode) { await load() }
        .onAppear { mode = target.mode }
        .onChange(of: location.last?.coordinate.latitude) { follow() }
        .sheet(isPresented: $showSteps) { stepList.presentationDetents([.medium, .large]) }
        .sensoryFeedback(.impact, trigger: step)
    }

    /// the route's points, for the Mapbox map
    private var line: [CLLocationCoordinate2D] {
        guard let p = route?.polyline, p.pointCount > 1 else { return [] }
        let pts = p.points()
        return (0..<p.pointCount).map { pts[$0].coordinate }
    }

    /// omw!'s Mapbox map when it's set up (the same warm map as the Map tab), else Apple Maps
    @ViewBuilder private var mapLayer: some View {
        #if canImport(MapboxMaps)
        if MapboxSetup.shared.token != nil {
            OmwRouteMap(line: line, target: target.coordinate, name: target.name, following: going)
        } else {
            appleMap
        }
        #else
        appleMap
        #endif
    }

    private var appleMap: some View {
        Map(position: $position) {
            UserAnnotation()
            if let route {
                MapPolyline(route.polyline).stroke(Color.coral, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }
            Marker(target.name, systemImage: "mappin", coordinate: target.coordinate).tint(Color.coral)
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass() }
    }

    // ---------- top ----------
    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40).background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.name).font(.headline).lineLimit(1)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                // the first thing to do, so it's clear before you even tap Start
                if let first = steps.first {
                    // tap to see every turn
                    Button { showSteps = true } label: {
                        HStack(spacing: 4) {
                            Label(first.instructions, systemImage: Self.symbol(for: first.instructions)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.coral)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 12)
    }

    /// on the way: the next turn, big
    private var nextTurn: some View {
        let s = steps.indices.contains(step) ? steps[step] : nil
        return HStack(spacing: 14) {
            Image(systemName: Self.symbol(for: s?.instructions ?? "")).font(.system(size: 30, weight: .bold)).frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                if let s, let d = distanceToStep(s) { Text(Self.distance(d)).font(.title2.weight(.heavy).monospacedDigit()) }
                Text(s?.instructions ?? "You're here").font(.headline).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { voice.toggle() } label: {
                Image(systemName: voice ? "speaker.wave.2.fill" : "speaker.slash.fill").font(.headline)
                    .frame(width: 40, height: 40).background(.white.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(Color(red: 0.11, green: 0.42, blue: 0.29), in: .rect(cornerRadius: 22))
        .contentShape(.rect)
        .onTapGesture { showSteps = true }  // tap the banner for every turn
        .padding(.horizontal, 12)
    }

    // ---------- bottom ----------
    private var footer: some View {
        VStack(spacing: 12) {
            if !going {
                HStack(spacing: 8) {
                    ForEach(Self.modes) { m in
                        Button { mode = m.id } label: {
                            Image(systemName: m.symbol).font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(mode == m.id ? Color.sun : Color.omwCard2, in: Capsule())
                                .foregroundStyle(mode == m.id ? Color.black : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 10) {
                if going {
                    arrivalLine
                    Spacer()
                    Button("End") { withAnimation { going = false }; speaker.stopSpeaking(at: .immediate) }
                        .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    arrivalLine
                    Spacer(minLength: 8)
                    Button {
                        withAnimation { going = true }
                        step = 0
                        position = .userLocation(followsHeading: true, fallback: .automatic)
                        say(steps.first?.instructions)
                    } label: {
                        Text(failed ? "No route found" : "Start").font(.headline).frame(minWidth: 96, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).tint(.freeGreen).controlSize(.large)
                    .disabled(route == nil)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 12).padding(.bottom, 4)
    }

    private var stepList: some View {
        NavigationStack {
            List(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 12) {
                    Image(systemName: Self.symbol(for: s.instructions)).frame(width: 28).foregroundStyle(i == step && going ? Color.omwBlue : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.instructions).font(.subheadline.weight(i == step && going ? .bold : .regular))
                        if s.distance > 0 { Text(Self.distance(s.distance)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Turns")
            .omwBackground()
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // ---------- the route ----------
    private var steps: [MKRoute.Step] { (route?.steps ?? []).filter { !$0.instructions.isEmpty } }

    private var summary: String {
        if mode == "transit" {
            guard let transitMinutes else { return failed ? "No transit time here" : "Finding the way…" }
            return "\(Self.minutes(transitMinutes)) by transit" + (route.map { " · walking route shown, \(Self.minutes($0.expectedTravelTime / 60))" } ?? "")
        }
        guard let route else { return failed ? "No route found" : "Finding the way…" }
        return "\(Self.minutes(tripMinutes ?? seconds(route) / 60)) · \(Self.distance(route.distance))"
    }

    /// how long the route takes (by bike: the walking route at about 15 km/h)
    private func seconds(_ route: MKRoute) -> TimeInterval { mode == "cycling" ? route.distance / 4.2 : route.expectedTravelTime }

    /// the trip, in minutes: the server's (live traffic, the same numbers your plan's leave time comes from), else
    /// Apple's estimate
    private var tripMinutes: Double? {
        if let trafficMinutes { return trafficMinutes }
        if mode == "transit" { return transitMinutes }
        return route.map { seconds($0) / 60 }
    }

    /// when you'd get there leaving now
    private var arriveAt: Date? { tripMinutes.map { Date.now.addingTimeInterval($0 * 60) } }

    /// "There at 6:52 · 3 min early" (against the plan's start), and before you go, the plan's "Leave by"
    private var arrivalLine: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let arriveAt {
                Text("There at \(arriveAt.formatted(date: .omitted, time: .shortened))").font(.title3.weight(.bold))
                if let start = target.start {
                    let late = Int((arriveAt.timeIntervalSince(start) / 60).rounded())
                    Text(late <= 0 ? (late < -1 ? "\(-late) min early" : "On time") : "\(late) min late")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(late <= Int(Session.lateAfterMinutes) ? Color.freeGreen : Color.orange)
                }
                if !going, let leave = target.leaveBy, leave > .now {
                    Text("Your leave-by: \(leave.formatted(date: .omitted, time: .shortened))")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            } else {
                Text(failed ? "No route found" : "Finding the way…").font(.headline).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        route = nil; transitMinutes = nil; trafficMinutes = nil; failed = false; step = 0
        Task { await loadTraffic() }
        let request = MKDirections.Request()
        request.source = .forCurrentLocation()
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: target.coordinate))
        switch mode {
        case "walking", "cycling", "transit": request.transportType = .walking
        default: request.transportType = .automobile
        }
        if mode == "transit" {
            let eta = MKDirections.Request()
            eta.source = request.source
            eta.destination = request.destination
            eta.transportType = .transit
            transitMinutes = (try? await MKDirections(request: eta).calculateETA()).map { $0.expectedTravelTime / 60 }
        }
        do {
            let found = try await MKDirections(request: request).calculate()
            if Task.isCancelled { return }
            route = found.routes.first
            if let route, !going {
                let box = route.polyline.boundingMapRect
                withAnimation { position = .rect(box.insetBy(dx: -box.width * 0.2, dy: -box.height * 0.45)) }
            }
        } catch {
            failed = transitMinutes == nil
        }
    }

    /// the trip time from our server, with live traffic (Google), the same way the plan's leave times are worked out
    private func loadTraffic() async {
        guard let here = location.last?.coordinate else { return }
        struct Req: Encodable {
            let origin: [Double], venue: [Double], mode: String
            let start_time: String?, utc_offset_min: Int?
        }
        struct Resp: Decodable { let minutes: Double? }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let req = Req(origin: [here.latitude, here.longitude], venue: [target.coordinate.latitude, target.coordinate.longitude], mode: mode,
                      start_time: target.start.map(local.string), utc_offset_min: TimeZone.current.secondsFromGMT() / 60)
        let asked = mode
        if let got = try? await API.send("/directions", req, as: Resp.self), asked == mode { trafficMinutes = got.minutes }
    }

    /// moves on to the next step once you're close to where it starts
    private func follow() {
        guard going, let here = location.last else { return }
        while steps.indices.contains(step + 1), let d = distanceToStep(steps[step + 1]), d < 60 { step += 1; say(steps[step].instructions) }
        if CLLocation(latitude: target.coordinate.latitude, longitude: target.coordinate.longitude).distance(from: here) < 40 {
            say("You've arrived at \(target.name)")
            going = false
        }
    }

    private func distanceToStep(_ s: MKRoute.Step) -> CLLocationDistance? {
        guard let here = location.last, s.polyline.pointCount > 0 else { return nil }
        let start = s.polyline.points()[0].coordinate
        return CLLocation(latitude: start.latitude, longitude: start.longitude).distance(from: here)
    }

    private func say(_ text: String?) {
        guard voice, let text, !text.isEmpty else { return }
        speaker.stopSpeaking(at: .word)
        speaker.speak(AVSpeechUtterance(string: text))
    }

    // ---------- words ----------
    static func minutes(_ m: Double) -> String {
        let m = Int(m.rounded())
        return m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) hr" : "\(m / 60) hr \(m % 60) min"
    }

    static func distance(_ meters: CLLocationDistance) -> String {
        Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    static func symbol(for instruction: String) -> String {
        let s = instruction.lowercased()
        if s.contains("u-turn") { return "arrow.uturn.left" }
        if s.contains("slight left") || s.contains("keep left") { return "arrow.up.left" }
        if s.contains("slight right") || s.contains("keep right") { return "arrow.up.right" }
        if s.contains("left") { return "arrow.turn.up.left" }
        if s.contains("right") { return "arrow.turn.up.right" }
        if s.contains("arrive") || s.contains("destination") { return "mappin.circle.fill" }
        if s.contains("roundabout") { return "arrow.triangle.2.circlepath" }
        return "arrow.up"
    }
}
