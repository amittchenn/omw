// One plan: where and when, when you leave (with directions), who's going and who's arrived, and "I'm here".
// An invitation shows Going / Can't make it.
import SwiftUI
import MapKit
import FirebaseFirestore
import CoreLocation
#if canImport(LocationEssentials)
import LocationEssentials  // where iOS 26 keeps coordinates and distances
#endif

struct PlanDetailView: View {
    let id: String
    @Environment(Session.self) private var session
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var route: DirectionsTarget?
    @State private var note: String?
    @State private var leaving = false
    @State private var live: [String: (CLLocationCoordinate2D, Date)] = [:]  // hangouts/{id}/where: people on their way
    @State private var liveStop: ListenerRegistration?

    private var h: Hangout? { session.hangout(id) }

    var body: some View {
        Group {
            if let h { content(h) } else { ContentUnavailableView("This plan is gone", systemImage: "calendar.badge.exclamationmark") }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $route) { DirectionsView(target: $0).withOmw() }
        .onAppear {
            liveStop = session.db.collection("hangouts").document(id).collection("where").addSnapshotListener { snap, _ in
                MainActor.assumeIsolated {
                    var next: [String: (CLLocationCoordinate2D, Date)] = [:]
                    for d in snap?.documents ?? [] {
                        let x = d.data()
                        if let lat = (x["lat"] as? NSNumber)?.doubleValue, let lng = (x["lng"] as? NSNumber)?.doubleValue, let at = When.parse(x["at"]) {
                            next[d.documentID] = (CLLocationCoordinate2D(latitude: lat, longitude: lng), at)
                        }
                    }
                    live = next
                }
            }
        }
        .onDisappear { liveStop?.remove(); liveStop = nil }
    }

    /// the others still coming, where they were in the last 10 minutes
    private var onTheWay: [LiveDot] {
        guard let h, !h.isOver else { return [] }
        var dots: [LiveDot] = []
        for (who, v) in live where who != session.uid && h.arrivals[who] == nil && Date.now.timeIntervalSince(v.1) < 600 {
            dots.append(LiveDot(id: who, spot: v.0))
        }
        return dots
    }

    @ViewBuilder private func content(_ h: Hangout) -> some View {
        let uid = session.uid ?? ""
        let going = h.attendees.contains(uid)
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(h.title).font(.title2.weight(.bold))
                    Text(h.start.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(h.isOver ? Color.secondary : Color.red)
                    if !h.venueName.isEmpty {
                        Label(h.address.isEmpty ? h.venueName : "\(h.venueName) · \(h.address)", systemImage: "mappin.and.ellipse")
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
                if let venue = h.venue {
                    Map(initialPosition: onTheWay.isEmpty ? .region(MKCoordinateRegion(center: venue, latitudinalMeters: 900, longitudinalMeters: 900)) : .automatic,
                        interactionModes: onTheWay.isEmpty ? [] : [.pan, .zoom]) {
                        Marker(h.venueName, systemImage: "mappin", coordinate: venue).tint(.red)
                        UserAnnotation()
                        // the others on their way, live (only while they're coming)
                        ForEach(onTheWay) { dot in
                            Annotation(session.person(dot.id)?.firstName ?? h.names[dot.id] ?? "", coordinate: dot.spot) {
                                Avatar(session.person(dot.id), fallback: h.names[dot.id] ?? "", size: 30)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                                    .shadow(radius: 3)
                            }
                        }
                    }
                    .frame(height: onTheWay.isEmpty ? 170 : 260)
                    .clipShape(.rect(cornerRadius: 12))
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                }
            }

            if going, !h.isOver { yourTrip(h, uid: uid) }

            if going { GroupPhotoSection(hangout: h) }

            if !going, h.rsvp[uid] == nil, !h.isOver {
                Section {
                    HStack(spacing: 10) {
                        Button { accept(h) } label: { Text("Going").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.borderedProminent).tint(Color.omwBlue)
                        Button { leave(h) } label: { Text("Can't make it").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.bordered)
                    }
                    .disabled(working)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("\(h.names[h.createdBy].map { $0.split(separator: " ").first.map(String.init) ?? $0 } ?? "A friend") invited you")
                }
            }

            Section("Who's going") {
                ForEach(h.invited, id: \.self) { u in personRow(h, u) }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            if going, h.chatOpen {
                ToolbarItem(placement: .topBarTrailing) {
                    // the plan's group chat (the people going), like the web app
                    NavigationLink(value: ChatRef.plan(h.id)) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .overlay(alignment: .topTrailing) {
                                if session.planUnread(h.id) > 0 { Circle().fill(.red).frame(width: 9, height: 9).offset(x: 4, y: -3) }
                            }
                    }
                    .accessibilityLabel("Group chat")
                }
            }
            if going, !h.isOver {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(h.createdBy == uid && h.attendees.count == 1 ? "Cancel plan" : "Can't make it", systemImage: "xmark.circle", role: .destructive) { leaving = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .confirmationDialog(h.createdBy == uid && h.attendees.count == 1 ? "Cancel this plan?" : "Can't make it?", isPresented: $leaving, titleVisibility: .visible) {
            Button(h.createdBy == uid && h.attendees.count == 1 ? "Cancel plan" : "I can't make it", role: .destructive) { leave(h) }
        } message: {
            Text(h.attendees.count > 1 ? "The others keep the plan." : "Nobody else is going yet.")
        }
        .alert(note ?? "", isPresented: .constant(note != nil)) { Button("OK") { note = nil } }
    }

    @ViewBuilder private func yourTrip(_ h: Hangout, uid: String) -> some View {
        Section {
            if let arrived = h.arrivals[uid] {
                Label("You checked in at \(arrived.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.freeGreen).font(.headline)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Leave by").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(h.alerts[uid]?.formatted(date: .omitted, time: .shortened) ?? "–").font(.title.weight(.bold).monospacedDigit())
                        if let minutes = h.travel[uid] {
                            Text("\(Int(minutes.rounded())) min \(Self.modeName(h.modes[uid]))").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { directions(h) } label: { Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill") }
                        .buttonStyle(.borderedProminent).tint(Color.omwBlue)
                }
                if h.checkInOpen {
                    Button { imHere(h) } label: { Label("I'm here", systemImage: "mappin.and.ellipse") }
                }
            }
        }
    }

    private func personRow(_ h: Hangout, _ u: String) -> some View {
        let p = session.person(u)
        let name = u == session.uid ? "You" : p?.firstName ?? (h.names[u].map { $0.split(separator: " ").first.map(String.init) ?? $0 } ?? "Friend")
        let status: (String, Color) = {
            if let at = h.arrivals[u] {
                let late = Int((at.timeIntervalSince(h.start) / 60).rounded())
                return (late < -1 ? "Here · \(-late) min early" : late <= 5 ? "Here · on time" : "Here · \(late) min late", .freeGreen)
            }
            if h.attendees.contains(u) {
                if let leave = h.alerts[u] { return ("Going · leaves \(leave.formatted(date: .omitted, time: .shortened))", .secondary) }
                return ("Going", .secondary)
            }
            if h.rsvp[u] == "declined" { return ("Can't make it", .secondary) }
            return ("Hasn't answered", .orange)
        }()
        return HStack(spacing: 12) {
            Avatar(photo: p?.photo ?? "", name: p?.name ?? h.names[u] ?? "Friend", size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.subheadline.weight(.semibold))
                Text(status.0).font(.footnote).foregroundStyle(status.1)
            }
        }
        .opensProfile(u)
    }

    static func modeName(_ mode: String?) -> String {
        switch mode { case "walking": "walk"; case "cycling": "bike"; case "transit": "by transit"; default: "drive" }
    }

    /// directions right here in the app (Directions.swift), by how you're getting there
    private func directions(_ h: Hangout) {
        guard let venue = h.venue else { return }
        route = DirectionsTarget(name: h.venueName.isEmpty ? h.title : h.venueName, coordinate: venue, mode: h.modes[session.uid ?? ""] ?? "driving",
                                 start: h.start, leaveBy: h.alerts[session.uid ?? ""])
    }

    /// within 300 m of the spot: checked in (the same as arriving with "Always" on)
    private func imHere(_ h: Hangout) {
        guard let venue = h.venue else { return }
        guard let here = location.last, Date.now.timeIntervalSince(here.timestamp) < 120 else {
            note = location.mode == .never ? "Turn on location sharing in Settings to check in." : "Finding you… try again in a moment."
            location.apply()
            return
        }
        let away = here.distance(from: CLLocation(latitude: venue.latitude, longitude: venue.longitude))
        if away > 300 { note = away >= 1000 ? String(format: "You're %.1f km away.", away / 1000) : "You're \(Int(away)) m away."; return }
        location.record(h)
    }

    private func accept(_ h: Hangout) {
        working = true
        let from = location.last.map(\.coordinate) ?? session.me?.home
        Task {
            do { try await session.accept(h, from: from) } catch { note = error.localizedDescription }
            working = false
        }
    }

    private func leave(_ h: Hangout) {
        working = true
        Task {
            do { try await session.cantMakeIt(h); dismiss() } catch { note = error.localizedDescription }
            working = false
        }
    }
}

/// someone on their way, on the plan's map
struct LiveDot: Identifiable {
    let id: String
    let spot: CLLocationCoordinate2D
}
