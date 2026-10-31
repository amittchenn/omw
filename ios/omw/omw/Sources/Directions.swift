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
    var id: String { "\(coordinate.latitude),\(coordinate.longitude)" }
}

struct DirectionsView: View {
    let target: DirectionsTarget
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "driving"
    @State private var route: MKRoute?
    @State private var transitMinutes: Double?
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
        Map(position: $position) {
            UserAnnotation()
            if let route {
                MapPolyline(route.polyline).stroke(Color.omwBlue, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }
            Marker(target.name, systemImage: "mappin", coordinate: target.coordinate).tint(.red)
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass(); MapUserLocationButton() }
        .safeAreaInset(edge: .top) { if going { nextTurn } else { header } }
        .safeAreaInset(edge: .bottom) { footer }
        .task(id: mode) { await load() }
        .onAppear { mode = target.mode }
        .onChange(of: location.last?.coordinate.latitude) { follow() }
        .sheet(isPresented: $showSteps) { stepList.presentationDetents([.medium, .large]) }
        .sensoryFeedback(.impact, trigger: step)
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text(arrival).font(.title3.weight(.bold))
                        Text(summary).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Steps") { showSteps = true }.buttonStyle(.bordered)
                    Button("End") { withAnimation { going = false }; speaker.stopSpeaking(at: .immediate) }
                        .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button("Steps") { showSteps = true }.buttonStyle(.bordered).controlSize(.large).disabled(steps.isEmpty)
                    Button {
                        withAnimation { going = true }
                        step = 0
                        position = .userLocation(followsHeading: true, fallback: .automatic)
                        say(steps.first?.instructions)
                    } label: {
                        Text(failed ? "No route found" : "Start").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
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
            .navigationTitle("Steps")
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
        return "\(Self.minutes(seconds(route) / 60)) · \(Self.distance(route.distance))"
    }

    /// how long the route takes (by bike: the walking route at about 15 km/h)
    private func seconds(_ route: MKRoute) -> TimeInterval { mode == "cycling" ? route.distance / 4.2 : route.expectedTravelTime }

    private var arrival: String {
        let secs = mode == "transit" ? (transitMinutes ?? 0) * 60 : route.map(seconds) ?? 0
        return "Arrive \(Date.now.addingTimeInterval(secs).formatted(date: .omitted, time: .shortened))"
    }

    private func load() async {
        route = nil; transitMinutes = nil; failed = false; step = 0
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
