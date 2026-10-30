// Small pieces used everywhere: colors, pictures (posts keep their photos as data, profiles may link them), avatars.
import SwiftUI
import UIKit

extension Color {
    static let sun = Color(red: 1, green: 0.902, blue: 0)          // omw! yellow, #FFE600
    static let omwBlue = Color(red: 0.118, green: 0.533, blue: 1)  // #1E88FF
    static let freeGreen = Color(red: 0.2, green: 0.78, blue: 0.47)
}

extension Person.Status {
    var color: Color? {
        switch self { case .out: .sun; case .onTheWay: .omwBlue; case .free: .freeGreen; case .none: nil }
    }
    var label: String {
        switch self { case .out: "Out now"; case .onTheWay: "On the way"; case .free: "Free"; case .none: "" }
    }
}

/// Turns a picture (data:image/…;base64 or an https link) into an image off the main thread, and remembers it,
/// so scrolling the feed never stutters on decoding.
enum ImageLoader {
    nonisolated(unsafe) static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 120 * 1024 * 1024
        return c
    }()

    static func load(_ source: String) async -> UIImage? {
        guard !source.isEmpty else { return nil }
        let key = NSString(string: "\(source.count):\(source.hashValue)")
        if let hit = cache.object(forKey: key) { return hit }
        let image: UIImage?
        if source.hasPrefix("data:") {
            image = await Task.detached(priority: .userInitiated) { decode(source) }.value
        } else if let url = URL(string: source), url.scheme == "https",
                  let data = try? await URLSession.shared.data(from: url).0 {
            image = await Task.detached(priority: .userInitiated) { UIImage(data: data)?.preparingForDisplay() }.value
        } else {
            image = nil
        }
        if let image { cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4)) }
        return image
    }

    nonisolated static func decode(_ dataURL: String) -> UIImage? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let base64 = String(dataURL[dataURL.index(after: comma)...])
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: data)?.preparingForDisplay()
    }
}

/// A picture that fills its frame (crop to fit), fading in once it's ready.
struct RemoteImage: View {
    let source: String
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipped()
            .task(id: source.count ^ source.hashValue) {
                let loaded = await ImageLoader.load(source)
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            }
    }
}

/// A round profile picture, with their first letter until (or if) the picture loads, and a ring for their status.
struct Avatar: View {
    var photo: String
    var name: String
    var size: CGFloat = 40
    var ring: Color? = nil

    var body: some View {
        ZStack {
            Circle().fill(photo.isEmpty ? Color.sun.opacity(0.35) : Color(.secondarySystemFill))
            if photo.isEmpty {
                // no picture: their first letter (never drawn under a picture, so it can't show through)
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            } else {
                RemoteImage(source: photo)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .compositingGroup()  // fading a picture fades it as one image (no letter showing through)
        .padding(ring == nil ? 0 : 3)
        .overlay {
            if let ring { Circle().strokeBorder(ring, lineWidth: 2.5) }
        }
    }
}

extension Avatar {
    init(_ person: Person?, fallback: String = "", size: CGFloat = 40, showStatus: Bool = false) {
        self.init(photo: person?.photo ?? "", name: person?.name ?? fallback, size: size,
                  ring: showStatus ? person?.status.color : nil)
    }
}

/// While something loads: the shape of what's coming (a picture and two lines), never a spinner
struct PlaceholderRow: View {
    var size: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Color(.secondarySystemFill)).frame(width: size, height: size)
            VStack(alignment: .leading, spacing: 7) {
                Capsule().fill(Color(.secondarySystemFill)).frame(width: 120, height: 11)
                Capsule().fill(Color(.tertiarySystemFill)).frame(width: 76, height: 9)
            }
            Spacer(minLength: 0)
        }
        .shimmer()
        .accessibilityHidden(true)
    }
}

/// a soft light sweeping across, over and over, so a placeholder looks alive (and the wait feels short)
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    @ViewBuilder func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(g.size.width * 0.5, 80))
                        .offset(x: phase * (g.size.width + 80))
                }
                .mask { content }
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }

    /// a soft rounded box, like the web app's search fields and rows
    func softField() -> some View {
        padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 16))
    }
}

/// Where tapping someone goes: their profile
struct ProfileRoute: Hashable { let uid: String }
struct PostRoute: Hashable { let id: String }
struct PlanRoute: Hashable { let id: String }

// ---------- tap anyone to see their profile ----------
extension EnvironmentValues {
    /// inside a navigation stack that knows ProfileRoute (withProfileRoutes): push profiles; otherwise show them in a sheet
    @Entry var pushesProfiles = false
}

extension View {
    /// tapping this (a face, a name, a row) opens that person's profile, wherever it is in the app
    func opensProfile(_ uid: String?) -> some View { modifier(OpensProfile(uid: uid ?? "")) }
}

struct OpensProfile: ViewModifier {
    let uid: String
    @Environment(\.pushesProfiles) private var pushes
    @State private var open = false

    @ViewBuilder func body(content: Content) -> some View {
        if uid.isEmpty {
            content
        } else if pushes {
            NavigationLink(value: ProfileRoute(uid: uid)) { content.contentShape(.rect) }.buttonStyle(.plain)
        } else {
            Button { open = true } label: { content.contentShape(.rect) }
                .buttonStyle(.plain)
                .sheet(isPresented: $open) {
                    NavigationStack { ProfileView(uid: uid).withProfileRoutes() }.withOmw()
                        .presentationDragIndicator(.visible)
                }
        }
    }
}
