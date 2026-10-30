// The Live Activity (Dynamic Island + lock screen), like the web app's island.js: from 30 minutes before your leave time
// until everyone's there, a countdown to when to leave (then to the start) and who's arrived. The widget that draws it is
// in ios/Widget (its own target, see ios/README.md). While omw! is closed the server keeps it up to date (push.py), using
// the token saved on private/{uid}.live[hangout id]. Tapping it opens omw://hangout/<id>.
import Foundation
import ActivityKit
import FirebaseFirestore

/// the same as ios/Widget/OmwActivityAttributes.swift (the widget has its own copy; keep them the same)
struct OmwActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var leaveAt: Double   // your leave-now time (seconds since 1970)
        var startAt: Double   // when the hangout starts
        var here: Int         // how many have arrived
        var total: Int        // how many are going
        var arrived: Bool     // you're there
        var note: String      // "Sam is here"
    }
    var hangoutId: String
    var title: String
    var venue: String
}

@MainActor
final class LiveActivities {
    static let shared = LiveActivities()
    private var shown: [String: OmwActivityAttributes.ContentState] = [:]
    private var watching: Set<String> = []

    /// the same numbers push.py sends (keep them in step)
    private func state(_ h: Hangout, _ uid: String) -> OmwActivityAttributes.ContentState {
        let leave = h.alerts[uid] ?? h.start.addingTimeInterval(-30 * 60)
        let latest = h.attendees.filter { $0 != uid && h.arrivals[$0] != nil }.max { (h.arrivals[$0] ?? .distantPast) < (h.arrivals[$1] ?? .distantPast) }
        let note = latest.map { "\((h.names[$0] ?? "Friend").split(separator: " ").first.map(String.init) ?? "Friend") is here" } ?? ""
        return .init(leaveAt: leave.timeIntervalSince1970, startAt: h.start.timeIntervalSince1970,
                     here: h.attendees.filter { h.arrivals[$0] != nil }.count, total: h.attendees.count,
                     arrived: h.arrivals[uid] != nil, note: note)
    }

    /// which plan to show now, if any
    private func current(_ session: Session, _ uid: String) -> Hangout? {
        let now = Date.now
        return session.hangouts.filter { h in
            let s = state(h, uid)
            let allHere = s.here == s.total && s.total > 0
            let lastIn = h.allHereAt ?? .distantFuture
            return now.timeIntervalSince1970 >= s.leaveAt - 30 * 60 && now < h.end && !(allHere && now > lastIn.addingTimeInterval(5 * 60))
        }.min { $0.start < $1.start }
    }

    func sync(_ session: Session) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let running = Activity<OmwActivityAttributes>.activities
        guard let uid = session.uid else {
            Task { for a in running { await a.end(nil, dismissalPolicy: .immediate) } }
            return
        }
        let h = current(session, uid)
        for a in running where a.attributes.hangoutId != h?.id {
            shown[a.attributes.hangoutId] = nil
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
        guard let h else { return }
        let s = state(h, uid)
        let content = ActivityContent(state: s, staleDate: h.start.addingTimeInterval(3 * 3600))
        if let a = running.first(where: { $0.attributes.hangoutId == h.id }) {
            if shown[h.id] != s { shown[h.id] = s; Task { await a.update(content) } }
            watch(a, session)
            return
        }
        // you swiped it away: don't bring it back for this plan
        let key = "live.\(uid).\(h.id)"
        if UserDefaults.standard.bool(forKey: key) { return }
        let attributes = OmwActivityAttributes(hangoutId: h.id, title: h.title, venue: h.venueName)
        let started = (try? Activity.request(attributes: attributes, content: content, pushType: .token))
            ?? (try? Activity.request(attributes: attributes, content: content, pushType: nil))
        if let started {
            shown[h.id] = s
            UserDefaults.standard.set(true, forKey: key)
            watch(started, session)
        }
    }

    /// the server needs this token to update it while omw! is closed
    private func watch(_ a: Activity<OmwActivityAttributes>, _ session: Session) {
        guard watching.insert(a.id).inserted else { return }
        let id = a.attributes.hangoutId
        Task {
            for await data in a.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                guard let uid = session.uid else { continue }
                try? await session.db.collection("private").document(uid).setData(["live": [id: ["token": token]]], merge: true)
            }
        }
    }
}
