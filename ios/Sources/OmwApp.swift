// omw! for iPhone, in SwiftUI. It uses the same Firebase project, data and security rules as the web app
// (web/), so both apps see the same friends, posts and plans while this one grows.
import SwiftUI
import FirebaseCore

@main
struct OmwApp: App {
    @State private var session: Session
    @State private var location: LocationService
    @Environment(\.scenePhase) private var phase

    init() {
        FirebaseApp.configure()  // reads GoogleService-Info.plist
        let session = Session()
        _session = State(initialValue: session)
        _location = State(initialValue: LocationService(session: session))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(location)
                .tint(Color.primary)
                // sharing follows your choice, whether omw! is open, and which plans are coming up
                .onChange(of: phase) { location.foreground(phase == .active) }
                .onChange(of: session.uid) { location.apply() }
                .onChange(of: session.me?.shareMode) { location.apply() }
                .onChange(of: session.hangouts) { location.updateGeofences() }
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
    }
}
