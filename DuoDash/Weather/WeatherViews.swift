import SwiftUI
import CoreLocation

/// Current weather as a small capsule: symbol, temperature and, if there's room, a few words.
struct WeatherChip: View {
    @Environment(WeatherModel.self) private var weather
    /// Show the condition text when it fits.
    var showsText = true

    var body: some View {
        if let forecast = weather.current {
            ViewThatFits(in: .horizontal) {
                if showsText { chip(forecast, text: true) }
                chip(forecast, text: false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(forecast.condition.text), \(weather.format(forecast.temperatureC))")
            .accessibilityIdentifier("weather.chip")
        } else if weather.isLoading {
            ProgressView().controlSize(.small)
        }
    }

    private func chip(_ forecast: WeatherForecast, text: Bool) -> some View {
        HStack(spacing: 6) {
            WeatherSymbol(condition: forecast.condition, size: 20)
            Text(weather.format(forecast.temperatureC)).font(.dashBody).monospacedDigit()
            if text {
                Text(forecast.condition.text)
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .fixedSize()
    }
}

/// Weather at a destination on arrival, for the route preview:
/// symbol, temperature and "Rain likely" when the chance is 50% or more.
struct DestinationWeatherBadge: View {
    @Environment(WeatherModel.self) private var weather
    let coordinate: CLLocationCoordinate2D
    /// Arrival time; nil for "now".
    var eta: Date?
    /// Adds the Open-Meteo credit underneath (needed if no other weather view is on screen).
    var showsAttribution = false

    @State private var result: DestinationWeather?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let result {
                HStack(spacing: 6) {
                    WeatherSymbol(condition: result.condition, size: 16)
                    Text(weather.format(result.temperatureC)).font(.dashCaption).monospacedDigit()
                    if result.isRainLikely {
                        Text("Rain likely")
                            .font(.dashCaption)
                            .foregroundStyle(Theme.warning)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surfaceRaised, in: Capsule())
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spoken(result, format: weather.format))
                .accessibilityIdentifier("weather.destination")
                if showsAttribution { WeatherAttribution() }
            }
        }
        .task(id: taskKey) {
            result = await weather.weather(at: coordinate, time: eta)
        }
    }

    /// Re-fetch only when the place moves ~100 m or the ETA shifts by 5 minutes.
    private var taskKey: String {
        let slot = eta.map { Int($0.timeIntervalSince1970 / 300) } ?? 0
        return String(format: "%.3f,%.3f,%d", coordinate.latitude, coordinate.longitude, slot)
    }

    static func spoken(_ weather: DestinationWeather, format: (Double) -> String) -> String {
        var text = "At arrival: \(weather.condition.text), \(format(weather.temperatureC))"
        if weather.isRainLikely { text += ", rain likely" }
        return text
    }
}

/// The CC BY 4.0 credit Open-Meteo requires.
struct WeatherAttribution: View {
    var body: some View {
        Text(WeatherModel.attribution)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("weather.attribution")
    }
}

/// An SF Symbol for a weather condition in its multicolour rendering.
struct WeatherSymbol: View {
    let condition: WeatherCondition
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: condition.symbol)
            .symbolRenderingMode(.multicolor)
            .font(.system(size: size, weight: .semibold))
            .frame(minWidth: size * 1.3)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Keeps `WeatherModel.current` following the user's location, and fresh
    /// (every 15 minutes) while parked. Cheap: the weather cache absorbs repeated calls.
    func weatherFollowsLocation() -> some View {
        modifier(WeatherFollowsLocation())
    }
}

private struct WeatherFollowsLocation: ViewModifier {
    @Environment(WeatherModel.self) private var weather
    @Environment(LocationManager.self) private var location

    func body(content: Content) -> some View {
        content.task(id: key) {
            while !Task.isCancelled {
                await weather.updateCurrent(at: location.location?.coordinate)
                try? await Task.sleep(for: .seconds(weather.cacheLifetime + 5))
            }
        }
    }

    /// ~1 km steps, so a moving car refreshes now and then rather than on every fix.
    private var key: String {
        guard let c = location.location?.coordinate else { return "none" }
        return String(format: "%.2f,%.2f", c.latitude, c.longitude)
    }
}
