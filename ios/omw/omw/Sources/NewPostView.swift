// Posting, like Instagram: pick up to 4 photos from your camera roll (AlbumPicker.swift), then a caption, a place
// and who's in it, and Share.
import SwiftUI
import PhotosUI
import CoreLocation
#if canImport(LocationEssentials)
import LocationEssentials  // where iOS 26 keeps coordinates and distances
#endif

/// Put on a screen to give it a "new post" flow: set `picking` to true to start.
struct NewPostFlow: ViewModifier {
    @Binding var picking: Bool
    @State private var pending: Draft?
    @State private var draft: Draft?

    func body(content: Content) -> some View {
        content
            // the camera roll first; the caption sheet opens once it's gone
            .fullScreenCover(isPresented: $picking, onDismiss: {
                if let pending { draft = pending; self.pending = nil }
            }) {
                AlbumPicker { images in pending = Draft(images: images) }.withOmw()
            }
            .sheet(item: $draft) { draft in
                ComposeView(draft: draft).withOmw()
                    .interactiveDismissDisabled()
            }
    }
}

extension View {
    func newPostFlow(_ picking: Binding<Bool>) -> some View { modifier(NewPostFlow(picking: picking)) }
}

struct Draft: Identifiable {
    let id = UUID()
    var images: [UIImage]
}

struct ComposeView: View {
    let draft: Draft
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var caption = ""
    @State private var place: PlaceHit?
    @State private var tagged: [String] = []
    @State private var sharing = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TabView {
                        ForEach(draft.images.indices, id: \.self) { i in
                            Image(uiImage: draft.images[i]).resizable().scaledToFill()
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: draft.images.count > 1 ? .always : .never))
                    .aspectRatio(4 / 5, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 16))

                    TextField("Write a caption…", text: $caption, axis: .vertical)
                        .lineLimit(2...8)
                        .font(.body)

                    Divider()
                    NavigationLink { PlacePicker(selection: $place) } label: {
                        row("mappin.and.ellipse", "Add location", place?.name ?? "")
                    }
                    Divider()
                    NavigationLink { TagPicker(tagged: $tagged) } label: {
                        row("person.crop.circle.badge.plus", "Tag people", tagged.compactMap { session.person($0)?.handle }.joined(separator: ", "))
                    }
                    Divider()
                    Text(session.isPublic ? "Public" : "Friends only")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(sharing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sharing ? "Sharing…" : "Share", action: share).fontWeight(.semibold).disabled(sharing)
                }
            }
            .alert("Couldn't share it", isPresented: .constant(problem != nil)) {
                Button("OK") { problem = nil }
            } message: { Text(problem ?? "") }
        }
    }

    private func row(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 24)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }

    private func share() {
        sharing = true
        Task {
            do {
                try await session.share(photos: draft.images, caption: caption, place: place, tagged: tagged)
                dismiss()
            } catch {
                problem = error.localizedDescription
                sharing = false
            }
        }
    }
}

/// Add location: places your friends have posted from, or search any place (as you type)
struct PlacePicker: View {
    @Binding var selection: PlaceHit?
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [PlaceHit] = []
    @State private var picking = false

    /// friends' spots from the feed, as suggestions before you type
    private var suggested: [PlaceHit] {
        var seen = Set<String>()
        return session.allPosts.compactMap { p in
            guard !p.venueName.isEmpty, seen.insert(p.venueName).inserted else { return nil }
            return PlaceHit(kind: "place", id: nil, name: p.venueName, address: p.address,
                            lat: p.venue.count == 2 ? p.venue[0] : nil, lng: p.venue.count == 2 ? p.venue[1] : nil)
        }
    }

    var body: some View {
        List {
            if selection != nil {
                Button("Remove location", role: .destructive) { selection = nil; dismiss() }
            }
            ForEach(query.isEmpty ? suggested : hits, id: \.key) { hit in
                Button { pick(hit) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.name ?? "").foregroundStyle(.primary)
                        if let address = hit.address, !address.isEmpty { Text(address).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search places")
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else { hits = []; return }
            try? await Task.sleep(for: .milliseconds(180))  // wait for a pause in typing
            guard !Task.isCancelled else { return }
            let here = CLLocationManager().location?.coordinate
            hits = await API.suggestPlaces(text, near: (here?.latitude ?? 37.7749, here?.longitude ?? -122.4194))
        }
        .navigationTitle("Add location")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pick(_ hit: PlaceHit) {
        picking = true
        Task {
            selection = await API.placeDetails(hit)
            picking = false
            dismiss()
        }
    }
}

/// Tag people: your friends, tap to tag (up to 20)
struct TagPicker: View {
    @Binding var tagged: [String]
    @Environment(Session.self) private var session
    @State private var query = ""

    private var shown: [Person] {
        query.isEmpty ? session.friends
            : session.friends.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.handle.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(shown) { f in
            Button {
                if let i = tagged.firstIndex(of: f.id) { tagged.remove(at: i) } else if tagged.count < 20 { tagged.append(f.id) }
            } label: {
                HStack(spacing: 12) {
                    Avatar(f, size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.handle).font(.subheadline.weight(.semibold))
                        Text(f.name).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: tagged.contains(f.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(tagged.contains(f.id) ? Color.omwBlue : Color.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .overlay { if session.friends.isEmpty { ContentUnavailableView("No friends yet", systemImage: "person.2", description: Text("Add friends to tag them.")) } }
        .searchable(text: $query, prompt: "Search friends")
        .navigationTitle("Tag people")
        .navigationBarTitleDisplayMode(.inline)
    }
}
