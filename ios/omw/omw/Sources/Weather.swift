// The forecast at the spot for the hour you picked, like the web app's planner: the hour itself big, and the hours
// around it. Straight from Open-Meteo (free, no key), °F in the US and °C everywhere else.
import SwiftUI
import CoreLocation
#if canImport(LocationEssentials)
import LocationEssentials  // where iOS 26 keeps coordinates and distances
#endif

struct Forecast: Equatable {
    struct Hour: Equatable, Identifiable {
        let time: Date
        let tempC: Double
        let rain: Int
        let code: Int
        var id: Date { time }
    }
    let hours: [Hour]        // two before to three after the hangout
    let atHangout: Hour?

    static func load(at spot: CLLocationCoordinate2D, for when: Date) async -> Forecast? {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", spot.latitude)),
            .init(name: "longitude", value: String(format: "%.2f", spot.longitude)),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "16"),
            .init(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
        ]
        guard let url = parts.url, let got = try? await URLSession.shared.data(from: url),
              let raw = try? JSONDecoder().decode(Raw.self, from: got.0) else { return nil }
        let key = DateFormatter()
        key.locale = Locale(identifier: "en_US_POSIX")
        key.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let hour = Calendar.current.dateInterval(of: .hour, for: when)?.start ?? when
        var hours: [Hour] = []
        var center: Hour?
        for k in -2...3 {
            let t = hour.addingTimeInterval(Double(k) * 3600)
            guard let i = raw.hourly.time.firstIndex(of: key.string(from: t)), let temp = raw.hourly.temperature_2m[i] else { continue }
            let h = Hour(time: t, tempC: temp, rain: raw.hourly.precipitation_probability[i] ?? 0, code: raw.hourly.weather_code[i] ?? 0)
            hours.append(h)
            if k == 0 { center = h }
        }
        return Forecast(hours: hours, atHangout: center)
    }

    private struct Raw: Decodable {
        let hourly: Hourly
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double?]
            let precipitation_probability: [Int?]
            let weather_code: [Int?]
        }
    }

    static let fahrenheit = Locale.current.measurementSystem == .us
    static func degrees(_ c: Double) -> String { "\(Int((fahrenheit ? c * 9 / 5 + 32 : c).rounded()))°" }

    /// WMO weather codes → an SF Symbol and words
    static func look(_ code: Int) -> (symbol: String, label: String) {
        switch code {
        case 0: ("sun.max.fill", "Clear")
        case 1, 2: ("cloud.sun.fill", "Mostly sunny")
        case 3: ("cloud.fill", "Cloudy")
        case 45, 48: ("cloud.fog.fill", "Foggy")
        case 51...67: ("cloud.rain.fill", "Rain")
        case 71...77: ("snowflake", "Snow")
        case 80...82: ("cloud.drizzle.fill", "Showers")
        case 85, 86: ("cloud.snow.fill", "Snow showers")
        case 95...99: ("cloud.bolt.rain.fill", "Storms")
        default: ("thermometer.medium", "Weather")
        }
    }
}

/// the planner's weather panel
struct WeatherPanel: View {
    let spot: CLLocationCoordinate2D?
    let when: Date
    @State private var forecast: Forecast?
    @State private var tried = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let h = forecast?.atHangout {
                let look = Forecast.look(h.code)
                HStack(spacing: 12) {
                    Image(systemName: look.symbol).symbolRenderingMode(.multicolor).font(.system(size: 30))
                    Text(Forecast.degrees(h.tempC)).font(.system(size: 34, weight: .bold, design: .rounded))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(look.label).font(.headline)
                        Text("\(when.formatted(.dateTime.weekday(.wide).hour()))\(h.rain > 0 ? " · \(h.rain)% rain" : "")")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 0) {
                    ForEach(forecast?.hours ?? []) { x in
                        let on = x.time == h.time
                        VStack(spacing: 5) {
                            Text(x.time.formatted(.dateTime.hour())).font(.caption2.weight(.semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
                            Image(systemName: Forecast.look(x.code).symbol).symbolRenderingMode(.multicolor).font(.system(size: 17))
                            Text(Forecast.degrees(x.tempC)).font(.footnote.weight(.semibold))
                            Text(x.rain >= 20 ? "\(x.rain)%" : " ").font(.caption2).foregroundStyle(Color.omwBlue)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(on ? Color.omwCard2 : .clear, in: .rect(cornerRadius: 12))
                    }
                }
                if h.rain >= 50 {
                    Label("Rain's likely. Maybe somewhere indoors.", systemImage: "umbrella.fill")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Color.omwBlue)
                }
            } else if tried {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spot == nil ? "Pick a spot for the forecast" : "No forecast yet").font(.subheadline.weight(.semibold))
                    Text(spot == nil ? "" : "Shows up about two weeks out.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                // the shape of the forecast while it comes in
                HStack(spacing: 12) {
                    Circle().fill(Color.omwCard2).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(Color.omwCard2).frame(width: 90, height: 12)
                        Capsule().fill(Color.omwCard2).frame(width: 140, height: 9)
                    }
                }
                .shimmer()
                .accessibilityHidden(true)
            }
        }
        .task(id: "\(spot?.latitude ?? 0),\(spot?.longitude ?? 0),\(when.timeIntervalSince1970)") {
            guard let spot else { forecast = nil; tried = true; return }
            try? await Task.sleep(for: .milliseconds(250))  // the time wheel spins through hours: wait till it stops
            if Task.isCancelled { return }
            let f = await Forecast.load(at: spot, for: when)
            if Task.isCancelled { return }
            forecast = f
            tried = true
        }
    }
}
