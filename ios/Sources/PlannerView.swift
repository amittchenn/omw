// The + tab: plan a hangout. What, who, where and when; then omw! works out when each person should leave (the
// server's lateness and traffic models, same as the web app) and sends everyone an invite.
import SwiftUI
import CoreLocation
import FirebaseFirestore

/// the kinds of hangout (the same ids the web app and the server use)
struct HangoutType: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String   // SF Symbol here
    let icon: String     // the web app's icon name, saved on the plan so both apps show it

    static let all = [
        HangoutType(id: "food", name: "Food", symbol: "fork.knife", icon: "utensils"),
        HangoutType(id: "coffee", name: "Coffee", symbol: "cup.and.saucer", icon: "coffee"),
        HangoutType(id: "study", name: "Study", symbol: "book", icon: "book-open"),
        HangoutType(id: "party", name: "Party", symbol: "party.popper", icon: "party-popper"),
        HangoutType(id: "sports", name: "Sports", symbol: "figure.volleyball", icon: "volleyball"),
    ]
}

/// what the server needs (snake_case, as it expects)
struct PlanRequest: Encodable {
    let user_ids: [String]
    let start_time: String        // local time, "2026-10-30T19:30"
    let venue: [Double]
    let hangout_type: String
    let guests: [Guest]
    let utc_offset_min: Int
    let group_size: Int

    struct Guest: Encodable {
        let user_id: String
        let name: String
        let travel_mode: String
        let home: [Double]?       // where they'll leave from: where they are now, or home
        let habits: [Double]
    }
}

/// one person's answer: when to leave
struct PlanResult: Decodable, Identifiable {
    let user_id: String
    let alert_time: String        // local time, "2026-10-30T19:04"
    let travel_minutes: Double
    let travel_mode: String?
    let label: String?
    var id: String { user_id }
    var leaveAt: Date? { When.parse(alert_time) }
}

struct PlanSheet: View {
    @Environment(Session.self) private var session
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss

    @State private var type = HangoutType.all[0]
    @State private var who: [String] = []
    @State private var place: PlaceHit?
    @State private var when = PlanSheet.nextHalfHour()
    @State private var results: [PlanResult]?
    @State private var noSpot: [String] = []
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(HangoutType.all) { t in
                                Button { type = t; results = nil } label: {
                                    Label(t.name, systemImage: t.symbol)
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 14).frame(height: 38)
                                        .background(type == t ? Color.primary : Color(.secondarySystemFill), in: Capsule())
                                        .foregroundStyle(type == t ? Color(.systemBackground) : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: { Text("What") }

                Section {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            if let me = session.me { person(me, name: "You", picked: true) }
                            ForEach(session.friends) { f in
                                Button { toggle(f.id) } label: { person(f, name: f.firstName, picked: who.contains(f.id)) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .scrollIndicators(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: { Text("Who") } footer: {
                    if session.friends.isEmpty { Text("Add friends to plan with them.") }
                }

                Section("Where") {
                    NavigationLink { PlacePicker(selection: $place) } label: {
                        HStack {
                            Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(place?.name ?? "Pick a spot").foregroundStyle(place == nil ? .secondary : .primary)
                                if let address = place?.address, !address.isEmpty { Text(address).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                    }
                }

                Section("When") {
                    DatePicker("Starts", selection: $when, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                }

                if let results {
                    Section {
                        ForEach(results) { r in resultRow(r) }
                        ForEach(noSpot, id: \.self) { uid in
                            HStack(spacing: 12) {
                                Avatar(session.person(uid), size: 40)
                                Text("\(session.person(uid)?.firstName ?? "Friend") has no location or home yet, so they'll pick their own time.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    } header: { Text("When everyone leaves") } footer: {
                        Text("Leave times allow for traffic at that hour and how late each person usually runs.")
                    }
                }
            }
            .navigationTitle("Plan a hangout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: results == nil ? plan : send) {
                    Text(working ? (results == nil ? "Working out leave times…" : "Sending…")
                         : results == nil ? "See when everyone leaves" : who.isEmpty ? "Save plan" : "Send invites")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.primary)
                .foregroundStyle(Color(.systemBackground))
                .disabled(place?.lat == nil || working)
                .padding(.horizontal, 16).padding(.bottom, 8)
                .background(.bar)
            }
            .onChange(of: place) { results = nil }
            .onChange(of: when) { results = nil }
            .alert("Couldn't do that", isPresented: .constant(problem != nil)) {
                Button("OK") { problem = nil }
            } message: { Text(problem ?? "") }
        }
    }

    private func person(_ p: Person, name: String, picked: Bool) -> some View {
        VStack(spacing: 5) {
            Avatar(p, size: 52)
                .overlay(alignment: .bottomTrailing) {
                    if picked {
                        Image(systemName: "checkmark.circle.fill").font(.title3)
                            .foregroundStyle(.white, Color.omwBlue)
                            .background(Circle().fill(Color(.systemBackground)).padding(2))
                    }
                }
                .opacity(picked ? 1 : 0.55)
            Text(name).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .frame(width: 62)
    }

    private func resultRow(_ r: PlanResult) -> some View {
        HStack(spacing: 12) {
            Avatar(session.person(r.user_id), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.user_id == session.uid ? "You" : session.person(r.user_id)?.firstName ?? "Friend").font(.subheadline.weight(.semibold))
                Text("\(Int(r.travel_minutes.rounded())) min \(Self.modeName(r.travel_mode))\(r.label.map { " · \($0)" } ?? "")")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("Leave").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(r.leaveAt?.formatted(date: .omitted, time: .shortened) ?? "–").font(.headline.monospacedDigit())
            }
        }
    }

    private static func modeName(_ mode: String?) -> String {
        switch mode { case "walking": "walk"; case "cycling": "bike"; case "transit": "by transit"; default: "drive" }
    }

    static func nextHalfHour() -> Date {
        let t = Date.now.addingTimeInterval(3600).timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / 1800).rounded(.up) * 1800)
    }

    private func toggle(_ id: String) {
        if let i = who.firstIndex(of: id) { who.remove(at: i) } else { who.append(id) }
        results = nil
    }

    /// where someone leaves from: where they are now (if it's fresh), else home
    private func startPoint(_ uid: String) -> CLLocationCoordinate2D? {
        if uid == session.uid {
            if let here = location.last, Date.now.timeIntervalSince(here.timestamp) < 30 * 60 { return here.coordinate }
            return session.me?.home
        }
        if let spot = session.spots[uid], spot.isFresh { return spot.coordinate }
        return session.person(uid)?.home
    }

    private func plan() {
        guard let uid = session.uid, let lat = place?.lat, let lng = place?.lng else { return }
        let everyone = [uid] + who
        let guests: [PlanRequest.Guest] = everyone.compactMap { id in
            guard let p = session.person(id), let from = startPoint(id) else { return nil }
            return .init(user_id: id, name: p.name, travel_mode: p.travelMode, home: [from.latitude, from.longitude], habits: p.habits)
        }
        noSpot = everyone.filter { id in !guests.contains { $0.user_id == id } }
        guard !guests.isEmpty else { problem = "Set your home in the current app (Settings → Home) so omw! knows where you leave from."; return }
        let request = PlanRequest(user_ids: guests.map(\.user_id), start_time: When.local.string(from: when), venue: [lat, lng],
                                  hangout_type: type.id, guests: guests, utc_offset_min: TimeZone.current.secondsFromGMT(for: when) / 60,
                                  group_size: everyone.count)
        working = true
        Task {
            do {
                let answer = try await API.send("/plan", request, as: [PlanResult].self)
                withAnimation(.snappy(duration: 0.25)) { results = answer }
            } catch { problem = error.localizedDescription }
            working = false
        }
    }

    /// the plan, with everyone invited (you're going); same document as the web app's "Send invites"
    private func send() {
        guard let uid = session.uid, let me = session.me, let place, let lat = place.lat, let lng = place.lng else { return }
        let everyone = [uid] + who
        let planned = results ?? []
        var names: [String: String] = [:], modes: [String: String] = [:]
        for id in everyone { if let p = session.person(id) { names[id] = p.name; modes[id] = p.travelMode } }
        var alerts: [String: String] = [:], travel: [String: Double] = [:]
        for r in planned {
            if let leave = r.leaveAt { alerts[r.user_id] = When.string(leave) }
            travel[r.user_id] = (r.travel_minutes * 10).rounded() / 10
            if let m = r.travel_mode { modes[r.user_id] = m }
        }
        let doc: [String: Any] = [
            "title": "\(type.name) at \(place.name ?? "a spot")", "start": When.string(when), "durationMin": 120,
            "venueName": place.name ?? "", "address": place.address ?? "", "venue": [lat, lng], "type": type.id, "emoji": type.icon,
            "invited": everyone, "names": names, "modes": modes, "alerts": alerts, "travel": travel,
            "attendees": [uid], "rsvp": [uid: "going"], "createdBy": uid, "createdByName": me.name,
            "createdAt": FieldValue.serverTimestamp(), "tz": TimeZone.current.identifier,
        ]
        working = true
        session.db.collection("hangouts").addDocument(data: doc) { error in
            MainActor.assumeIsolated {
                working = false
                if let error { problem = error.localizedDescription } else { dismiss() }
            }
        }
    }
}
