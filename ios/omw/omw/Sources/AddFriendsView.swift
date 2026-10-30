// Add friends, like Snapchat: search usernames as you type, accept people who added you, Quick Add (friends of
// your friends), and invite people who aren't on omw! yet.
import SwiftUI

struct AddFriendsView: View {
    @Environment(Session.self) private var session
    @State private var query = ""
    @State private var results: [Card] = []
    @State private var searching = false
    @State private var quick: [QuickAdd]?

    var body: some View {
        List {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    if results.isEmpty {
                        if searching { ForEach(0..<2, id: \.self) { _ in PlaceholderRow() } }
                        else { Text("No one found").foregroundStyle(.secondary) }
                    }
                    ForEach(results) { card in
                        PersonRow(card: card, detail: card.id == session.uid ? "\(card.name) · You" : card.name)
                    }
                }
            } else {
                if !session.incoming.isEmpty {
                    Section("Added me") {
                        ForEach(session.incoming) { r in
                            HStack(spacing: 12) {
                                Avatar(photo: r.fromPhoto, name: r.fromName, size: 46)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.fromName).font(.subheadline.weight(.semibold))
                                    Text("wants to be friends").font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Accept") { session.accept(r) }
                                    .buttonStyle(.borderedProminent).tint(Color.omwBlue).controlSize(.small)
                                Button { session.decline(r) } label: { Image(systemName: "xmark").foregroundStyle(.secondary) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section("Quick Add") {
                    if let quick {
                        if quick.isEmpty {
                            Text("Friends of your friends show up here.").foregroundStyle(.secondary)
                        }
                        ForEach(quick) { q in
                            PersonRow(card: q.card, detail: "\(q.card.name) · \(q.mutual) mutual \(q.mutual == 1 ? "friend" : "friends")")
                        }
                    } else {
                        ForEach(0..<3, id: \.self) { _ in PlaceholderRow() }
                    }
                }
                Section {
                    ShareLink(item: "Come plan hangouts with me on omw! Add me: \(session.me?.code ?? "")") {
                        Label("Invite friends to omw!", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search names or usernames")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { results = []; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            session.searchUsers(text) { found in
                if query.trimmingCharacters(in: .whitespaces) == text { results = found; searching = false }
            }
        }
        .task { session.quickAdd { quick = $0 } }
        .navigationTitle("Add friends")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// someone in a list: picture, username, a line about them, and the right button (Add, Requested, Accept, Friends)
struct PersonRow: View {
    let card: Card
    let detail: String
    @Environment(Session.self) private var session

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: ProfileRoute(uid: card.id)) {
                HStack(spacing: 12) {
                    Avatar(photo: card.photo, name: card.name, size: 46)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.handle).font(.subheadline.weight(.semibold))
                        Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if card.id != session.uid { FriendButton(uid: card.id, card: card) }
        }
    }
}

/// Add / Requested / Accept / Friends, depending on where you two are
struct FriendButton: View {
    let uid: String
    let card: Card?
    @Environment(Session.self) private var session

    var body: some View {
        if uid == session.uid {
            EmptyView()
        } else if session.isFriend(uid) {
            label("Friends").foregroundStyle(.secondary)
        } else if let request = session.incoming.first(where: { $0.from == uid }) {
            Button("Accept") { session.accept(request) }
                .buttonStyle(.borderedProminent).tint(Color.omwBlue).controlSize(.small)
        } else if session.outgoing.contains(uid) {
            label("Requested").foregroundStyle(.secondary)
        } else if let card {
            Button("Add") { session.sendRequest(to: card) }
                .buttonStyle(.borderedProminent).tint(Color.omwBlue).controlSize(.small)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(.secondarySystemFill), in: Capsule())
    }
}
