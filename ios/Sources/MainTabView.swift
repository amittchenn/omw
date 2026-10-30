// The tabs: Feed, Map, ＋, Plans, Me. The ＋ in the middle is a yellow button, not a page: it opens the planner over
// whatever you're on (PlanLauncher), and you stay there when it closes.
import SwiftUI

struct MainTabView: View {
    @Environment(Session.self) private var session
    @State private var tab: Tab = .feed
    @State private var planner = PlanLauncher.shared
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
            // the middle slot, under the yellow ＋ (tapping the slot itself plans too)
            Color.clear
                .tabItem { Text(" ") }
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
        .onChange(of: tab) { old, new in
            if new == .plan { tab = old; planner.open = true }
        }
        .overlay(alignment: .bottom) {
            PlanFab().padding(.bottom, 4)  // sits in the middle of the tab bar
                .ignoresSafeArea(.keyboard)  // stays put when typing
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

/// the yellow ＋ in the middle of the tab bar: plan a hangout
struct PlanFab: View {
    var body: some View {
        Button { PlanLauncher.shared.open = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 58, height: 58)
                .background(Color.sun, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
        .buttonStyle(Pressable())
        .accessibilityLabel("Plan a hangout")
    }
}

