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
    @State private var modeFor: [String: String] = [:]  // how someone gets there for this plan (else their usual way)
    @State private var naming = false
    @State private var newType = ""

    /// `start`: a place picked already (Plan here on the map)
    init(start: PlaceHit? = nil) {
        _place = State(initialValue: start)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(greeting).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Plan a hangout").font(.system(size: 32, weight: .black, design: .rounded))
                    }
                    .padding(.bottom, 14)

                    MuseBar(near: location.last?.coordinate, filled: fill)

                    block("What") {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(HangoutType.all + (session.me?.categories ?? [])) { t in
                                    Button { type = t; results = nil } label: {
                                        Label(t.name, systemImage: t.symbol)
                                            .font(.subheadline.weight(.bold))
                                            .padding(.horizontal, 14).frame(height: 40)
                                            .background(type == t ? Color.primary : Color(.secondarySystemFill), in: Capsule())
                                            .foregroundStyle(type == t ? Color(.systemBackground) : Color.primary)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        if t.id.hasPrefix("c_") {
                                            Button("Delete", systemImage: "trash", role: .destructive) {
                                                session.removeCategory(t.id)
                                                if type == t { type = HangoutType.all[0] }
                                            }
                                        }
                                    }
                                }
                                Button { naming = true } label: {
                                    Label("New", systemImage: "plus")
                                        .font(.subheadline.weight(.bold))
                                        .padding(.horizontal, 14).frame(height: 40)
                                        .overlay(Capsule().strokeBorder(Color(.separator), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .scrollIndicators(.hidden)
                    }

                    block(who.isEmpty ? "Who" : "Who · \(who.count + 1) people") {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 14) {
                                if let me = session.me { person(me, name: "You", picked: true) }
                                ForEach(session.friends) { f in
                                    Button { toggle(f.id) } label: { person(f, name: f.firstName, picked: who.contains(f.id)) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .scrollIndicators(.hidden)
                        if session.friends.isEmpty { Text("Add friends to plan with them.").font(.footnote).foregroundStyle(.secondary) }
                    }

                    // only your own way there: friends travel their own way (set on their profile)
                    block("Getting there") {
                        let id = session.uid ?? ""
                        let mode = modeFor[id] ?? session.me?.travelMode ?? "driving"
                        HStack(spacing: 8) {
                            ForEach(Travel.modes, id: \.self) { m in
                                Button { modeFor[id] = m; results = nil } label: {
                                    Label(Travel.name(m), systemImage: Travel.symbol(m))
                                        .labelStyle(.iconOnly)
                                        .font(.system(size: 17, weight: .semibold))
                                        .frame(maxWidth: .infinity, minHeight: 42)
                                        .background(mode == m ? Color.primary : Color(.secondarySystemFill), in: Capsule())
                                        .foregroundStyle(mode == m ? Color(.systemBackground) : Color.primary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Travel.name(m))
                            }
                        }
                    }

                    block("Where") {
                        NavigationLink { PlacePicker(selection: $place) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: place == nil ? "magnifyingglass" : "mappin.circle.fill")
                                    .foregroundStyle(place == nil ? Color.secondary : Color.red)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(place?.name ?? "Search for a spot").foregroundStyle(place == nil ? .secondary : .primary)
                                        .fontWeight(place == nil ? .regular : .semibold)
                                    if let address = place?.address, !address.isEmpty {
                                        Text(address).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if place != nil {
                                    Button { place = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .softField()
                        }
                        .buttonStyle(.plain)
                        FairSpotFinder(people: fairPeople, near: location.last?.coordinate) { place = $0 }
                    }

                    block("When") {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(PlanSheet.quickTimes()) { quick in
                                    let date = quick.date
                                    Button { when = date } label: {
                                        Text(quick.label)
                                            .font(.subheadline.weight(.bold))
                                            .padding(.horizontal, 14).frame(height: 38)
                                            .background(when == date ? Color.primary : Color(.secondarySystemFill), in: Capsule())
                                            .foregroundStyle(when == date ? Color(.systemBackground) : Color.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        DatePicker("Pick a time", selection: $when, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                            .font(.subheadline.weight(.semibold))
                    }

                    block("Weather") {
                        WeatherPanel(spot: weatherSpot, when: when)
                    }

                    if let results {
                        block("When everyone leaves") {
                            ForEach(results) { r in resultRow(r) }
                            ForEach(noSpot, id: \.self) { uid in
                                HStack(spacing: 12) {
                                    Avatar(session.person(uid), size: 40)
                                    Text("\(session.person(uid)?.firstName ?? "Friend") has no location or home yet, so they'll pick their own time.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Text("Includes traffic and how late each person usually runs.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
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
            .alert("New type", isPresented: $naming) {
                TextField("Name it, e.g. Bowling", text: $newType)
                Button("Add") {
                    if let t = session.addCategory(newType) { type = t; results = nil }
                    newType = ""
                }
                Button("Cancel", role: .cancel) { newType = "" }
            }
            .alert("Couldn't do that", isPresented: .constant(problem != nil)) {
                Button("OK") { problem = nil }
            } message: { Text(problem ?? "") }
        }
    }

    /// a section like the web app's planner: a line, a bold label, then what's in it
    private func block<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().padding(.bottom, 4)
            Text(title).font(.system(size: 17, weight: .heavy, design: .rounded))
            content()
        }
        .padding(.top, 18)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 5 ? "Up late" : hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        return "\(part), \(session.me?.firstName ?? "friend")"
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

    /// Muse's answer, into the form: who, what, when, where. Returns what it did, to show under the box.
    private func fill(_ a: MuseAnswer) -> String {
        var done: [String] = []
        let friends = a.who.filter { session.isFriend($0) }
        if !friends.isEmpty {
            who = friends
            done.append("added " + friends.compactMap { session.person($0)?.firstName }.joined(separator: ", "))
        }
        if let id = a.type, let t = (HangoutType.all + (session.me?.categories ?? [])).first(where: { $0.id == id }) {
            type = t
            done.append(t.name.lowercased())
        }
        if let w = a.when, let date = When.local.date(from: w) {
            when = date
            done.append(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        }
        if let p = a.place, p.lat != nil {
            place = p
            done.append(p.name ?? "the spot")
        } else if let q = a.place_query, !q.isEmpty {
            done.append("couldn't find “\(q)”")
        }
        results = nil
        let summary = a.summary.flatMap { $0.isEmpty ? nil : $0 } ?? "Done"
        return done.isEmpty ? summary : "\(summary) (\(done.joined(separator: " · ")))"
    }

    /// everyone in the plan, for the fair-spot finder
    private var fairPeople: [FairRequest.Who] {
        ([session.uid ?? ""] + who).compactMap { id in
            guard let p = session.person(id) else { return nil }
            let from = startPoint(id)
            return FairRequest.Who(id: id, name: id == session.uid ? "You" : p.firstName,
                                   home: from.map { [$0.latitude, $0.longitude] }, mode: modeFor[id] ?? p.travelMode)
        }
    }

    /// the weather's for the spot, or where you are until you pick one
    private var weatherSpot: CLLocationCoordinate2D? {
        if let lat = place?.lat, let lng = place?.lng { return CLLocationCoordinate2D(latitude: lat, longitude: lng) }
        return location.last?.coordinate
    }

    struct QuickTime: Identifiable {
        let label: String
        let date: Date
        var id: String { label }
    }

    /// the usual times people meet: tonight at 7 (if it's not too late), tomorrow lunch and dinner, the weekend afternoon
    static func quickTimes() -> [QuickTime] {
        let cal = Calendar.current, now = Date.now
        func at(_ day: Date, _ hour: Int) -> Date? { cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) }
        var list: [QuickTime] = []
        if let tonight = at(now, 19), tonight > now.addingTimeInterval(45 * 60) { list.append(QuickTime(label: "Tonight 7 PM", date: tonight)) }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now) {
            if let lunch = at(tomorrow, 12) { list.append(QuickTime(label: "Tomorrow noon", date: lunch)) }
            if let dinner = at(tomorrow, 19) { list.append(QuickTime(label: "Tomorrow 7 PM", date: dinner)) }
        }
        if let saturday = cal.nextDate(after: now.addingTimeInterval(36 * 3600), matching: DateComponents(weekday: 7), matchingPolicy: .nextTime),
           let afternoon = at(saturday, 14) {
            list.append(QuickTime(label: "Sat 2 PM", date: afternoon))
        }
        return list
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
    /// (a live spot more than 150 km from the place — another city, or the simulator's pretend location — isn't where
    /// they'll leave from: home is, if they have one)
    private func startPoint(_ uid: String) -> CLLocationCoordinate2D? {
        let home = session.person(uid)?.home
        var live: CLLocationCoordinate2D?
        if uid == session.uid {
            if let here = location.last, Date.now.timeIntervalSince(here.timestamp) < 30 * 60 { live = here.coordinate }
        } else if let spot = session.spots[uid], spot.isFresh {
            live = spot.coordinate
        }
        if let live, let lat = place?.lat, let lng = place?.lng, home != nil,
           CLLocation(latitude: live.latitude, longitude: live.longitude).distance(from: CLLocation(latitude: lat, longitude: lng)) > 150_000 {
            return home
        }
        return live ?? home
    }

    private func plan() {
        guard let uid = session.uid, let lat = place?.lat, let lng = place?.lng else { return }
        let everyone = [uid] + who
        let guests: [PlanRequest.Guest] = everyone.compactMap { id in
            guard let p = session.person(id), let from = startPoint(id) else { return nil }
            return .init(user_id: id, name: p.name, travel_mode: modeFor[id] ?? p.travelMode, home: [from.latitude, from.longitude], habits: p.habits)
        }
        noSpot = everyone.filter { id in !guests.contains { $0.user_id == id } }
        guard !guests.isEmpty else { problem = "Turn on location, or set your home in Edit profile, so omw! knows where you leave from."; return }
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
        for id in everyone { if let p = session.person(id) { names[id] = p.name; modes[id] = modeFor[id] ?? p.travelMode } }
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
