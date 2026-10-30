// Plans: what's coming up and what you've done (the hangouts you're going to), and the + planner.
import SwiftUI

struct PlansView: View {
    @Environment(Session.self) private var session

    var body: some View {
        NavigationStack {
            List {
                if session.hangouts.isEmpty {
                    ContentUnavailableView("Nothing planned yet", systemImage: "calendar",
                                           description: Text("Tap + to plan a hangout with your friends."))
                        .listRowBackground(Color.clear)
                }
                if !session.upcoming.isEmpty {
                    Section("Coming up") { ForEach(session.upcoming) { PlanRow(hangout: $0) } }
                }
                if !session.past.isEmpty {
                    Section("Past") { ForEach(session.past) { PlanRow(hangout: $0) } }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Plans")
        }
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

/// The + tab. The planner (who, where, when, leave-on-time alerts) moves over from the web app next.
struct PlanSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Plan a hangout", systemImage: "plus.app")
            } description: {
                Text("The planner is coming to the new app next. Plan in the current omw! app for now. Your plans show up here either way.")
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
