// MARK: - omw! Live Activity (added by mobile/setup-live-activity.sh; keep it below everything else in this file)
import ActivityKit

// Main.storyboard uses this instead of Capacitor's plain view controller, so the app can register its own plugin.
class MainViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(LiveActivityPlugin())
    }
}

// web/island.js talks to this: start, update and end the Live Activity for a hangout.
@objc(LiveActivityPlugin)
public class LiveActivityPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "LiveActivityPlugin"
    public let jsName = "LiveActivity"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isAvailable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "running", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "end", returnType: CAPPluginReturnPromise),
    ]

    override public func load() {
        if #available(iOS 16.2, *) {
            for a in Activity<OmwActivityAttributes>.activities { watchToken(a) }  // still running from before the app was closed
        }
    }

    @objc func isAvailable(_ call: CAPPluginCall) {
        if #available(iOS 16.2, *) {
            call.resolve(["available": ActivityAuthorizationInfo().areActivitiesEnabled])
        } else {
            call.resolve(["available": false])
        }
    }

    @objc func running(_ call: CAPPluginCall) {
        if #available(iOS 16.2, *) {
            call.resolve(["ids": Activity<OmwActivityAttributes>.activities.map { $0.attributes.hangoutId }])
        } else {
            call.resolve(["ids": []])
        }
    }

    // start it, or update it if it's already showing
    @objc func start(_ call: CAPPluginCall) {
        guard #available(iOS 16.2, *) else { return call.resolve(["started": false]) }
        guard let id = call.getString("id") else { return call.reject("id is required") }
        let state = OmwActivityAttributes.ContentState(
            leaveAt: call.getDouble("leaveAt") ?? 0, startAt: call.getDouble("startAt") ?? 0,
            here: call.getInt("here") ?? 0, total: call.getInt("total") ?? 1,
            arrived: call.getBool("arrived") ?? false, note: call.getString("note") ?? "")
        let content = ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: state.startAt + 3 * 3600))
        if let a = Activity<OmwActivityAttributes>.activities.first(where: { $0.attributes.hangoutId == id }) {
            Task {
                await a.update(content)
                call.resolve(["started": true])
            }
            return
        }
        let attributes = OmwActivityAttributes(hangoutId: id, title: call.getString("title") ?? "Hangout", venue: call.getString("venue") ?? "")
        do {
            let a: Activity<OmwActivityAttributes>
            do {  // with a push token, the server can update it while the app is closed (needs the Push Notifications capability)
                a = try Activity.request(attributes: attributes, content: content, pushType: .token)
            } catch {
                a = try Activity.request(attributes: attributes, content: content, pushType: nil)
            }
            watchToken(a)
            call.resolve(["started": true])
        } catch {
            call.reject(error.localizedDescription)
        }
    }

    @objc func end(_ call: CAPPluginCall) {
        guard #available(iOS 16.2, *) else { return call.resolve() }
        let id = call.getString("id")
        Task {
            for a in Activity<OmwActivityAttributes>.activities where id == nil || a.attributes.hangoutId == id {
                await a.end(nil, dismissalPolicy: .immediate)
            }
            call.resolve()
        }
    }

    @available(iOS 16.2, *)
    private func watchToken(_ a: Activity<OmwActivityAttributes>) {
        Task {
            for await data in a.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                self.notifyListeners("token", data: ["id": a.attributes.hangoutId, "token": token])
            }
        }
    }
}
