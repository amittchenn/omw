// Sharing where you are, the way you chose (Settings → Location): never, while using the app, or always.
//   While using: your spot updates as you move while omw! is open.
//   Always: iOS wakes omw! when you've moved a fair way (significant-change monitoring, light on battery) and when you
//   reach a hangout's spot (a geofence), so friends see roughly where you are and you're checked in when you arrive.
// Your spot goes to locations/{uid} (friends can read it); a check-in goes on the hangout, same as the web app.
import Foundation
import CoreLocation
import UIKit
import FirebaseFirestore

@MainActor @Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    var authorization: CLAuthorizationStatus
    var last: CLLocation?

    private let manager = CLLocationManager()
    private unowned let session: Session
    @ObservationIgnored private var inForeground = true
    @ObservationIgnored private var sent: (at: Date, spot: CLLocation)?
    @ObservationIgnored private var checkingIn: Set<String> = []

    init(session: Session) {
        self.session = session
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = true
        manager.activityType = .other
    }

    var mode: ShareMode { session.me?.shareMode ?? .whileUsing }

    /// what iOS lets omw! do falls short of what you picked (e.g. "Always" chosen, but iOS says "While Using")
    var needsSettings: Bool {
        switch mode {
        case .never: false
        case .whileUsing: authorization == .denied || authorization == .restricted
        case .always: authorization != .authorizedAlways && authorization != .notDetermined
        }
    }

    func choose(_ mode: ShareMode) {
        guard let uid = session.uid else { return }
        session.db.collection("users").document(uid).setData(["shareMode": mode.rawValue, "shareLive": mode != .never], merge: true)
        session.me?.shareMode = mode  // feels instant; the listener confirms it
        if mode == .never { session.db.collection("locations").document(uid).delete(); sent = nil }
        apply()
    }

    func foreground(_ active: Bool) {
        inForeground = active
        apply()
    }

    /// start or stop the right kind of updates for your choice, what iOS allows, and whether omw! is open
    func apply() {
        guard session.uid != nil else { stopAll(); return }
        switch mode {
        case .never:
            stopAll()
        case .whileUsing:
            manager.stopMonitoringSignificantLocationChanges()
            clearGeofences()
            if authorization == .notDetermined { manager.requestWhenInUseAuthorization(); return }
            if inForeground && allowed { manager.startUpdatingLocation() } else { manager.stopUpdatingLocation() }
        case .always:
            if authorization == .notDetermined { manager.requestWhenInUseAuthorization(); return }  // iOS asks in two steps
            if authorization == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
            if inForeground && allowed { manager.startUpdatingLocation() } else { manager.stopUpdatingLocation() }
            if authorization == .authorizedAlways {
                manager.startMonitoringSignificantLocationChanges()
                updateGeofences()
            }
        }
    }

    private var allowed: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }

    private func stopAll() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        clearGeofences()
    }

    // ---------- hangouts: geofences around the spots that are coming up, so arriving checks you in ----------
    func updateGeofences() {
        guard mode == .always, authorization == .authorizedAlways, let uid = session.uid else { return }
        let soon = session.hangouts.filter { h in
            h.venue != nil && h.arrivals[uid] == nil && h.start > Date.now.addingTimeInterval(-2 * 3600) && h.start < Date.now.addingTimeInterval(24 * 3600)
        }.prefix(15)  // iOS allows 20 per app
        let wanted = Set(soon.map(\.id))
        for region in manager.monitoredRegions where !wanted.contains(region.identifier) { manager.stopMonitoring(for: region) }
        let have = Set(manager.monitoredRegions.map(\.identifier))
        for h in soon where !have.contains(h.id) {
            guard let venue = h.venue else { continue }
            let region = CLCircularRegion(center: venue, radius: 150, identifier: h.id)
            region.notifyOnEntry = true
            region.notifyOnExit = false
            manager.startMonitoring(for: region)
        }
    }

    private func clearGeofences() {
        for region in manager.monitoredRegions { manager.stopMonitoring(for: region) }
    }

    // ---------- what to do with a new spot ----------
    private func handle(_ location: CLLocation) {
        guard mode != .never, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 500 else { return }
        last = location
        publish(location)
        checkIn(at: location)
    }

    /// friends' maps: at most once a minute, or sooner if you've moved 100 m
    private func publish(_ location: CLLocation) {
        guard let uid = session.uid else { return }
        if let sent, Date.now.timeIntervalSince(sent.at) < 60, location.distance(from: sent.spot) < 100 { return }
        sent = (.now, location)
        let task = UIApplication.shared.beginBackgroundTask()  // finish the write even if iOS put omw! away
        session.db.collection("locations").document(uid).setData([
            "lat": location.coordinate.latitude, "lng": location.coordinate.longitude, "at": When.string(.now),
        ]) { _ in UIApplication.shared.endBackgroundTask(task) }
    }

    /// within 150 m of a hangout that's on: you're there
    private func checkIn(at location: CLLocation) {
        guard let uid = session.uid else { return }
        for h in session.hangouts where h.checkInOpen && h.arrivals[uid] == nil && h.attendees.contains(uid) {
            guard let venue = h.venue, location.distance(from: CLLocation(latitude: venue.latitude, longitude: venue.longitude)) <= 150 else { continue }
            record(h)
        }
    }

    /// saves your arrival, and teaches the lateness model how long after your alert you really left (like the web app)
    func record(_ h: Hangout) {
        guard let uid = session.uid, !checkingIn.contains(h.id), h.arrivals[uid] == nil else { return }
        checkingIn.insert(h.id)
        let now = Date.now
        let task = UIApplication.shared.beginBackgroundTask()
        session.db.collection("hangouts").document(h.id).updateData(["arrivals.\(uid)": When.string(now)]) { [weak self] error in
            MainActor.assumeIsolated {
                defer { UIApplication.shared.endBackgroundTask(task) }
                guard let self else { return }
                if error != nil { self.checkingIn.remove(h.id); return }
                let late = (now.timeIntervalSince(h.start) / 60 * 10).rounded() / 10
                var habit: [String: Any] = ["id": h.id, "late": late]
                if let alert = h.alerts[uid], let travel = h.travel[uid] {
                    let delay = now.timeIntervalSince(alert) / 60 - travel
                    // only believable ones: within half an hour of the start, not absurdly early or late
                    if late <= 30, delay >= -30, delay <= 60 { habit["delay"] = (delay * 10).rounded() / 10 }
                }
                self.session.db.collection("users").document(uid).setData(["habits": FieldValue.arrayUnion([habit])], merge: true)
            }
        }
    }

    // ---------- iOS calls these (on the main thread, where the manager was made) ----------
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            authorization = manager.authorizationStatus
            apply()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            if let location = locations.last { handle(location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        MainActor.assumeIsolated {
            if let h = session.hangouts.first(where: { $0.id == region.identifier }), h.checkInOpen { record(h) }
            manager.requestLocation()  // and a fresh spot for friends
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
