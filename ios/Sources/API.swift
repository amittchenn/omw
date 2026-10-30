// The omw! server (the same one the web app uses): place search now, the planner next.
// It wants your sign-in on most calls, so every request carries your Firebase ID token.
import Foundation
import FirebaseAuth

enum API {
    /// Change this if the server moves (it's the same address the current app uses as OMW_SERVER)
    static let base = URL(string: "https://omw-bzq4.onrender.com")!

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], as: T.Type = T.self) async throws -> T {
        var parts = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 20
        if let token = try? await Auth.auth().currentUser?.getIDToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure(message: "The server didn't answer. Try again in a moment.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension API {
    /// POST with your sign-in; fails with the server's own message
    static func post(_ path: String) async throws {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        if let token = try? await Auth.auth().currentUser?.getIDToken(forcingRefresh: true) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw Failure(message: detail ?? "Something went wrong. Try again.")
        }
    }
}

/// A place from the server's search (Google Places, or Mapbox when Google isn't set up)
struct PlaceHit: Decodable, Hashable {
    var kind: String?
    var id: String?
    var name: String?
    var address: String?
    var lat: Double?
    var lng: Double?

    var key: String { id ?? "\(name ?? "")|\(address ?? "")" }
}

extension API {
    /// places matching what you typed, closest to `near` first (no suggestions for plain searches)
    static func suggestPlaces(_ text: String, near: (lat: Double, lng: Double)) async -> [PlaceHit] {
        let hits = (try? await get("/places/suggest", ["q": text, "lat": "\(near.lat)", "lng": "\(near.lng)"], as: [PlaceHit].self)) ?? []
        return hits.filter { $0.kind != "query" && $0.name != nil }
    }

    /// a suggestion's exact spot (suggestions from Google come without one)
    static func placeDetails(_ hit: PlaceHit) async -> PlaceHit {
        guard hit.lat == nil, let id = hit.id else { return hit }
        return (try? await get("/places/details", ["id": id], as: PlaceHit.self)) ?? hit
    }
}
