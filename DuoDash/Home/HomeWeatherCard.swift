import SwiftUI

/// Home's third card when Duo Dash Pro → Home layout picks Weather: now, today's high and
/// low, and the next few hours. Tapping it opens the Weather app.
struct HomeWeatherCard: View {
    @Environment(WeatherModel.self) private var weather
    let onOpen: () -> Void

    var body: some View {
        Card(padding: 14) {
            Button(action: onOpen) {
                content
                    .frame(maxWidth: .infinity, minHeight: Theme.minTouch, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .weatherFollowsLocation()
        .accessibilityIdentifier("home.weatherCard")
    }

    @ViewBuilder
    private var content: some View {
        if let forecast = weather.current {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    WeatherSymbol(condition: forecast.condition, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(weather.format(forecast.temperatureC)).font(.dashTitle).monospacedDigit()
                        Text(forecast.condition.text).font(.dashCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let high = forecast.todayHighC, let low = forecast.todayLowC {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("H \(weather.format(high))").font(.dashCaption).monospacedDigit()
                            Text("L \(weather.format(low))").font(.dashCaption).monospacedDigit()
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                ViewThatFits(in: .vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        hours(forecast)
                        WeatherAttribution()
                    }
                    WeatherAttribution()
                    EmptyView()
                }
            }
            .accessibilityElement(children: .combine)
        } else if weather.isLoading {
            ProgressView()
        } else {
            Label("Weather unavailable", systemImage: "cloud").font(.dashBody).foregroundStyle(Theme.textSecondary)
        }
    }

    private func hours(_ forecast: WeatherForecast) -> some View {
        HStack(spacing: 14) {
            ForEach(forecast.hourly.filter { $0.time >= .now.addingTimeInterval(-1800) }.prefix(4), id: \.time) { hour in
                VStack(spacing: 2) {
                    Text(hour.time, format: .dateTime.hour()).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(weather.format(hour.temperatureC)).font(.dashCaption).monospacedDigit()
                }
            }
        }
    }
}
