import UIKit
import Capacitor

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    // push notifications (@capacitor-firebase/messaging)
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NotificationCenter.default.post(name: Notification.Name.init("didReceiveRemoteNotification"), object: completionHandler, userInfo: userInfo)
    }
}

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
