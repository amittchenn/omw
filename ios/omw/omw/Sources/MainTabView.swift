// The five tabs, like Instagram: Feed, Map, + (plan a hangout), Plans, Me.
import SwiftUI

struct MainTabView: View {
    @Environment(Session.self) private var session
    @State private var tab: Tab = .feed
    @State private var planning = false
    @State private var router = PushRouter.shared  // a tapped notification (Push.swift)

    enum Tab: Hashable { case feed, map, plan, plans, me }

    var body: some View {
        TabView(selection: $tab) {
            FeedView()
                .tabItem { Label("Feed", systemImage: "house") }
                .tag(Tab.feed)
            FriendsMapView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(Tab.map)
            Color.clear
                .tabItem { Label("Plan", systemImage: "plus.app") }
                .tag(Tab.plan)
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
        // + doesn't switch tabs: it brings up the planner over whatever you were looking at
        .onChange(of: tab) { old, new in
            if new == .plan { tab = old; planning = true }
        }
        .sheet(isPresented: $planning) {
            PlanSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sensoryFeedback(.selection, trigger: tab)
        .sheet(item: Bindable(router).open) { PushDestinationView(destination: $0) }
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
