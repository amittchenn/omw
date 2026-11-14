// Notifications, like the web app's push.js: the server (push.py) sends your leave-now alert, invites and new chat
// messages to this phone's token, kept in private/{uid}.pushTokens (only you can read it). Tapping one opens what it's
// about. Needs the FirebaseMessaging package and the Push Notifications capability (a paid Apple Developer account);
// without the package the app builds and simply doesn't ask.
import SwiftUI
import UserNotifications
import FirebaseFirestore
#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

/// what a tapped notification wants to open
@MainActor @Observable
final class PushRouter {
    static let shared = PushRouter()
    var open: Destination?

    enum Destination: Identifiable, Equatable {
        case chat(String), planChat(String), plan(String)
        var id: String {
            switch self { case .chat(let c): "c:\(c)"; case .planChat(let h): "pc:\(h)"; case .plan(let h): "p:\(h)" }
        }
    }

    func route(_ data: [String: String]) {
        if let chat = data["chat"] { open = .chat(chat) }
        else if let h = data["hangout"] { open = data["kind"] == "chat" ? .planChat(h) : .plan(h) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if canImport(FirebaseMessaging)
        Messaging.messaging().delegate = self  // the token arrives (and changes) through this, whenever it's ready
        #endif
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        #if canImport(FirebaseMessaging)
        Messaging.messaging().apnsToken = deviceToken  // Firebase turns it into the token the server sends to
        #endif
    }

    // a notification while omw! is open: show it anyway
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    // tapped: go there
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let data = response.notification.request.content.userInfo
        let pairs = data.compactMap { k, v -> (String, String)? in
            guard let k = k as? String, let v = v as? String else { return nil }
            return (k, v)
        }
        let strings = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
        await MainActor.run { PushRouter.shared.route(strings) }
    }
}

extension Session {
    /// keep this phone's token on your private profile. `ask` is only true right after you make or join a plan, when
    /// "we'll tell you when to leave" is obvious (asking cold at sign-in is when people say no); otherwise it only
    /// registers if you already said yes
    func setUpPush(ask: Bool = false) {
        #if canImport(FirebaseMessaging)
        guard uid != nil else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                guard ask else { return }
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                status = await center.notificationSettings().authorizationStatus
            }
            guard status == .authorized || status == .provisional else { return }
            UIApplication.shared.registerForRemoteNotifications()
            // the token is saved when Firebase hands it over (MessagingDelegate below), not after a guessed wait;
            // if it's already here (a second sign-in on this phone), save it now
            if let token = Messaging.messaging().fcmToken { savePushToken(token) }
        }
        #endif
    }

    /// this phone's token on your private profile, so the server can reach you here
    func savePushToken(_ token: String) {
        guard let uid else { return }
        db.collection("private").document(uid).setData(["pushTokens": FieldValue.arrayUnion([token])], merge: true)
    }

    /// signing out: this phone stops getting your notifications (otherwise the next person on it would see your chats)
    func removePushToken() async {
        #if canImport(FirebaseMessaging)
        guard let uid, let token = Messaging.messaging().fcmToken else { return }
        try? await db.collection("private").document(uid).updateData(["pushTokens": FieldValue.arrayRemove([token])])
        #endif
    }
}

/// what a notification opens, over whatever tab you're on
struct PushDestinationView: View {
    let destination: PushRouter.Destination
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch destination {
                case .chat(let id): ConversationView(ref: .chat(id))
                case .planChat(let id): ConversationView(ref: .plan(id))
                case .plan(let id): PlanDetailView(id: id)
                }
            }
            .withProfileRoutes()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

#if canImport(FirebaseMessaging)
extension AppDelegate: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        Task { @MainActor in Session.shared?.savePushToken(fcmToken) }  // first token, or a new one after a refresh
    }
}
#endif
