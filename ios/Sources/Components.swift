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
            Circle().fill(Color.sun.opacity(0.35))
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            if !photo.isEmpty { RemoteImage(source: photo) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
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

/// Where tapping someone goes: their profile
struct ProfileRoute: Hashable { let uid: String }
struct PostRoute: Hashable { let id: String }
