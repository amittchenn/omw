// The tabs: Feed, Map, ＋, Plans, Me. The ＋ in the middle is a yellow button, not a page: it opens the planner over
// whatever you're on (PlanLauncher), and you stay there when it closes.
import SwiftUI
import UIKit

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
            // the middle slot is the yellow ＋ itself: drawn as the tab's own icon, so it sits exactly in the bar
            Color.clear
                .tabItem { Image(uiImage: PlanFab.icon).renderingMode(.original).accessibilityLabel("Plan a hangout") }
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
        environment(\.pushesProfiles, true)
            .navigationDestination(for: ProfileRoute.self) { ProfileView(uid: $0.uid) }
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
enum PlanFab {
    /// a yellow circle with a black ＋, as a full-color tab icon
    static let icon: UIImage = {
        let side: CGFloat = 40
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIColor(Color.sun).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
            let plus = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold))?
                .withTintColor(.black, renderingMode: .alwaysOriginal)
            if let plus { plus.draw(in: CGRect(x: (side - plus.size.width) / 2, y: (side - plus.size.height) / 2, width: plus.size.width, height: plus.size.height)) }
        }.withRenderingMode(.alwaysOriginal)
    }()
}
