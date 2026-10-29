import ActivityKit
import Foundation

// omw!'s Live Activity (Dynamic Island + lock screen) while you head to a hangout.
// The app (AppDelegate.swift) and the widget (OmwLive) each have a copy of this; keep them the same.
// The server (push.py) and web/island.js send ContentState as JSON with these exact names. Times are seconds since 1970.
@available(iOS 16.1, *)
struct OmwActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var leaveAt: Double   // your leave-now time
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
