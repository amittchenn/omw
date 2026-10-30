// The four tabs: Feed, Map, Plans, Me. Planning opens over whatever you're on (PlanLauncher), from the ＋ buttons.
import SwiftUI

struct MainTabView: View {
    @Environment(Session.self) private var session
    @State private var tab: Tab = .feed
    @State private var planner = PlanLauncher.shared
    @State private var router = PushRouter.shared  // a tapped notification (Push.swift)

    enum Tab: Hashable { case feed, map, plans, me }

    var body: some View {
        TabView(selection: $tab) {
            FeedView()
                .tabItem { Label("Feed", systemImage: "house") }
                .tag(Tab.feed)
            FriendsMapView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(Tab.map)
            PlansView()
                .tabItem { Label("Plans", systemImage: "calendar") }
                .badge(session.invites.count)
                .tag(Tab.plans)
            NavigationStack {
                ProfileView(uid: session.uid ?? "")
                    .withProfileRoutes()
            }
            .tabItem { Label("Me", systemImage: "person.crop.circle") }
            .tag(Tab.me)
        }
        .sheet(isPresented: Bindable(planner).open) {
            PlanSheet().withOmw()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sensoryFeedback(.selection, trigger: tab)
        .sheet(item: Bindable(router).open) { PushDestinationView(destination: $0).withOmw() }
        .onAppear { session.setUpPush() }
    }
}

extension View {
    /// tapping a person or a post anywhere opens their profile / the post
    func withProfileRoutes() -> some View {
        navigationDestination(for: ProfileRoute.self) { ProfileView(uid: $0.uid) }
            .navigationDestination(for: PostRoute.self) { PostDetailView(id: $0.id) }
            .navigationDestination(for: ChatRef.self) { ConversationView(ref: $0) }
            .navigationDestination(for: PlanRoute.self) { PlanDetailView(id: $0.id) }
    }
}

/// "Plan a hangout", from anywhere: the ＋ on Plans, the Feed's ＋ menu
@MainActor @Observable
final class PlanLauncher {
    static let shared = PlanLauncher()
    var open = false
}
