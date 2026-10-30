// omw! for iPhone, in SwiftUI. It uses the same Firebase project, data and security rules as the web app
// (web/), so both apps see the same friends, posts and plans while this one grows.
import SwiftUI
import FirebaseCore
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@main
struct OmwApp: App {
    @State private var session: Session
    @State private var location: LocationService
    @Environment(\.scenePhase) private var phase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate  // notifications (Push.swift)

    init() {
        FirebaseApp.configure()  // reads GoogleService-Info.plist
        let session = Session()
        let location = LocationService(session: session)
        _session = State(initialValue: session)
        _location = State(initialValue: location)
        Session.shared = session
        LocationService.shared = location
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(location)
                .tint(Color.primary)
                .onOpenURL { url in
                    // the Live Activity: omw://hangout/<id>
                    if url.scheme == "omw", url.host == "hangout", let id = url.pathComponents.dropFirst().first {
                        PushRouter.shared.open = .plan(id)
                        return
                    }
                    #if canImport(GoogleSignIn)
                    _ = GIDSignIn.sharedInstance.handle(url)  // coming back from Google's sign-in
                    #endif
                }
                // sharing follows your choice, whether omw! is open, and which plans are coming up
                .onChange(of: phase) { location.foreground(phase == .active) }
                .onChange(of: session.uid) { location.apply(); session.setUpPush() }
                .onChange(of: session.me?.shareMode) { location.apply() }
                .onChange(of: session.hangouts) { location.updateGeofences(); LiveActivities.shared.sync(session) }
                .onChange(of: phase) { if phase == .active { API.wake() } }  // wake the server before you need it
                .task {  // a plan's Live Activity starts (and counts down) on its own schedule
                    API.wake()
                    while !Task.isCancelled {
                        LiveActivities.shared.sync(session)
                        try? await Task.sleep(for: .seconds(30))
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(Session.self) private var session

    var body: some View {
        Group {
            if session.user == nil {
                SignInView()
                    .transition(.opacity)
            } else {
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.22), value: session.user == nil)
        .fontDesign(.rounded)  // omw!'s friendly rounded type everywhere, like the web app's Nunito
    }
}

extension View {
    /// The app's shared state, handed to a sheet or full-screen page explicitly (iOS doesn't always pass it along to
    /// everything that's presented, and a screen without it would crash)
    func withOmw() -> some View {
        environment(Session.shared).environment(LocationService.shared)
            .environment(\.pushesProfiles, false)  // a sheet starts outside any navigation stack
    }
}
