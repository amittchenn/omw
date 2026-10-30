// Plans: what's coming up and what you've done (the hangouts you're going to), and the + planner.
import SwiftUI
import CoreLocation
#if canImport(LocationEssentials)
import LocationEssentials  // where iOS 26 keeps coordinates and distances
#endif

struct PlansView: View {
    @Environment(Session.self) private var session
    @Environment(LocationService.self) private var location
    @State private var answering: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Plans").font(.system(size: 34, weight: .black, design: .rounded))

                    if !session.invites.isEmpty {
                        group("Invites") {
                            ForEach(session.invites) { h in invite(h) }
                        }
                    }

                    if session.upcoming.isEmpty && session.invites.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "calendar.badge.plus").font(.system(size: 40)).foregroundStyle(.secondary)
                            Text("Nothing planned").font(.headline)
                            Button("Make a plan") { PlanLauncher.shared.open = true }
                                .font(.subheadline.weight(.bold))
                                .buttonStyle(.borderedProminent).tint(Color.sun).foregroundStyle(.black)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }

                    if !session.upcoming.isEmpty {
                        group("Coming up") {
                            ForEach(session.upcoming) { h in
                                NavigationLink(value: PlanRoute(id: h.id)) { UpcomingCard(hangout: h) }.buttonStyle(Pressable())
                            }
                        }
                    }

                    if !session.past.isEmpty {
                        group("Been there") {
                            ForEach(session.past) { h in
                                NavigationLink(value: PlanRoute(id: h.id)) { PlanRow(hangout: h) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .planButton()
            .toolbar(.hidden, for: .navigationBar)
            .withProfileRoutes()
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 17, weight: .heavy, design: .rounded))
            content()
        }
    }

    /// an invite: who asked, what and when, and Going / Can't right there
    private func invite(_ h: Hangout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: PlanRoute(id: h.id)) {
                HStack(spacing: 12) {
                    Avatar(session.person(h.createdBy), fallback: h.names[h.createdBy] ?? "", size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.title).font(.headline).lineLimit(1)
                        Text("\(h.names[h.createdBy]?.split(separator: " ").first.map(String.init) ?? "A friend") · \(h.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 10) {
                Button { answer(h, going: true) } label: { Text("Going").frame(maxWidth: .infinity, minHeight: 42) }
                    .buttonStyle(.borderedProminent).tint(Color.primary).foregroundStyle(Color(.systemBackground))
                Button { answer(h, going: false) } label: { Text("Can't").frame(maxWidth: .infinity, minHeight: 42) }
                    .buttonStyle(.bordered).tint(Color.primary)
            }
            .font(.subheadline.weight(.bold))
            .disabled(answering == h.id)
        }
        .padding(14)
        .background(Color.sun.opacity(0.14), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.sun.opacity(0.5), lineWidth: 1))
    }

    private func answer(_ h: Hangout, going: Bool) {
        answering = h.id
        Task {
            if going { try? await session.accept(h, from: location.last?.coordinate ?? session.me?.home) }
            else { try? await session.cantMakeIt(h) }
            answering = nil
        }
    }
}

/// a plan that's coming up: a big date, what, where, who, and when you leave
struct UpcomingCard: View {
    let hangout: Hangout
    @Environment(Session.self) private var session

    var body: some View {
        let uid = session.uid ?? ""
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(hangout.start.formatted(.dateTime.weekday(.abbreviated))).font(.caption.weight(.heavy)).textCase(.uppercase)
                Text(hangout.start.formatted(.dateTime.day())).font(.system(size: 28, weight: .black, design: .rounded))
            }
            .frame(width: 58, height: 64)
            .background(Color.sun, in: .rect(cornerRadius: 16))
            .foregroundStyle(.black)
            VStack(alignment: .leading, spacing: 4) {
                Text(hangout.title).font(.headline).lineLimit(1)
                Text([hangout.start.formatted(date: .omitted, time: .shortened), hangout.venueName].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    HStack(spacing: -8) {
                        ForEach(hangout.attendees.prefix(4), id: \.self) { u in
                            Avatar(session.person(u), fallback: hangout.names[u] ?? "", size: 24)
                                .overlay(Circle().stroke(Color(.secondarySystemBackground), lineWidth: 2))
                        }
                    }
                    if let leave = hangout.alerts[uid], hangout.arrivals[uid] == nil {
                        Text("Leave \(leave.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
    }
}

struct PlanRow: View {
    let hangout: Hangout
    @Environment(Session.self) private var session

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(hangout.start.formatted(.dateTime.month(.abbreviated))).font(.caption2.weight(.bold)).textCase(.uppercase)
                    .foregroundStyle(hangout.isOver ? Color.secondary : Color.red)
                Text(hangout.start.formatted(.dateTime.day())).font(.title3.weight(.bold))
            }
            .frame(width: 46, height: 50)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(hangout.title).font(.headline).lineLimit(1)
                Text([hangout.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()), hangout.venueName]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: -10) {
                ForEach(hangout.attendees.prefix(3), id: \.self) { uid in
                    Avatar(session.person(uid), size: 26).overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
            }
        }
        .padding(.vertical, 2)
    }
}
