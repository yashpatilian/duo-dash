import SwiftUI

/// Current weather, today's high/low and the next six hours.
struct WeatherHeader: View {
    @Environment(WeatherModel.self) private var weather

    var body: some View {
        Card {
            if let forecast = weather.current {
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 20) {
                            now(forecast)
                            hours(forecast, count: 6)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            now(forecast)
                            hours(forecast, count: 6)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            now(forecast)
                            hours(forecast, count: 4)
                        }
                        now(forecast)
                    }
                    HStack { Spacer(); WeatherAttribution() }
                }
            } else if let error = weather.errorMessage {
                Label(error, systemImage: "cloud.fill")
                    .font(.dashCaption).foregroundStyle(Theme.textSecondary)
                    .frame(minHeight: Theme.minTouch)
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(weather.isLoading ? "Loading weather…" : "Waiting for location…")
                        .font(.dashCaption).foregroundStyle(Theme.textSecondary)
                }
                .frame(minHeight: Theme.minTouch)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("calendar.weather")
    }

    private func now(_ forecast: WeatherForecast) -> some View {
        HStack(spacing: 12) {
            WeatherSymbol(condition: forecast.condition, size: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text(weather.format(forecast.temperatureC)).font(.dashHero).monospacedDigit()
                Text(forecast.condition.text).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                if let high = forecast.todayHighC, let low = forecast.todayLowC {
                    Text("H \(weather.format(high))  L \(weather.format(low))")
                        .font(.dashCaption).monospacedDigit()
                }
            }
        }
        .fixedSize()
    }

    private func hours(_ forecast: WeatherForecast, count: Int) -> some View {
        HStack(spacing: 18) {
            ForEach(forecast.nextHours(count, from: .now), id: \.time) { hour in
                VStack(spacing: 4) {
                    Text(hour.time, format: .dateTime.hour())
                        .font(.dashCaption).foregroundStyle(Theme.textSecondary)
                    WeatherSymbol(condition: hour.condition, size: 20)
                        .frame(height: 26)
                    Text(weather.format(hour.temperatureC)).font(.dashBody).monospacedDigit()
                    Text(hour.precipitationProbability.map { "\($0)%" } ?? " ")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle((hour.precipitationProbability ?? 0) >= 50 ? Theme.accent : Theme.textSecondary)
                }
                .fixedSize()
            }
        }
    }
}
