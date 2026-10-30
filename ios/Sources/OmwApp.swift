// omw! for iPhone, in SwiftUI. It uses the same Firebase project, data and security rules as the web app
// (web/), so both apps see the same friends, posts and plans while this one grows.
import SwiftUI
import FirebaseCore

@main
struct OmwApp: App {
    @State private var session: Session

    init() {
        FirebaseApp.configure()  // reads GoogleService-Info.plist
        _session = State(initialValue: Session())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .tint(Color.primary)
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
        .animation(.easeInOut(duration: 0.25), value: session.user == nil)
    }
}
