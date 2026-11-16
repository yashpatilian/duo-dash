import SwiftUI
import MapKit

/// The Weather app, in the style of iOS Weather: a full-screen sky that matches the
/// conditions (sunny blue, rain falling, snow, stars at night), the place and a big
/// temperature, then the hourly strip, the 10-day forecast and the detail tiles.
struct WeatherScreen: View {
    @Environment(WeatherModel.self) private var weather
    @Environment(LocationManager.self) private var location
    @State private var placeName: String?

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 700
            ZStack {
                WeatherSky(condition: weather.current?.condition, isDay: weather.current?.isDay ?? true)
                if let forecast = weather.current {
                    ScrollView {
                        if wide {
                            HStack(alignment: .top, spacing: 14) {
                                VStack(spacing: 14) {
                                    WeatherHero(forecast: forecast, placeName: placeName)
                                    WeatherTileGrid(forecast: forecast, columns: 2)
                                }
                                .frame(width: min(400, proxy.size.width * 0.42))
                                VStack(spacing: 14) {
                                    WeatherHourlyCard(forecast: forecast)
                                    WeatherDailyCard(forecast: forecast)
                                    WeatherAttribution().frame(maxWidth: .infinity)
                                }
                            }
                            .padding(14)
                        } else {
                            VStack(spacing: 14) {
                                WeatherHero(forecast: forecast, placeName: placeName)
                                WeatherHourlyCard(forecast: forecast)
                                WeatherDailyCard(forecast: forecast)
                                WeatherTileGrid(forecast: forecast, columns: 2)
                                WeatherAttribution()
                            }
                            .padding(14)
                        }
                    }
                    .scrollIndicators(.hidden)
                } else {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large).tint(.white)
                        Text(weather.errorMessage ?? (weather.isLoading ? "Loading weather…" : "Waiting for your location…"))
                            .font(.dashBody)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("weather.screen")
        .task(id: placeKey) { await lookUpPlace() }
    }

    /// Re-look-up the place name when the forecast moves more than ~1 km.
    private var placeKey: String {
        guard let point = weather.current?.location else { return "" }
        return String(format: "%.2f,%.2f", point.latitude, point.longitude)
    }

    private func lookUpPlace() async {
        guard let point = weather.current?.location,
              let request = MKReverseGeocodingRequest(location: CLLocation(latitude: point.latitude, longitude: point.longitude))
        else { return }
        if let item = try? await request.mapItems.first {
            placeName = item.addressRepresentations?.cityName ?? item.name
        }
    }
}

// MARK: - Hero

private struct WeatherHero: View {
    @Environment(WeatherModel.self) private var weather
    let forecast: WeatherForecast
    let placeName: String?

    var body: some View {
        VStack(spacing: 2) {
            Text("My Location")
                .font(.system(size: 13, weight: .semibold))
                .textCase(.uppercase)
                .opacity(0.8)
            Text(placeName ?? " ")
                .font(.system(size: 30, weight: .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(weather.format(forecast.temperatureC))
                .font(.system(size: 96, weight: .thin))
                .monospacedDigit()
                .padding(.leading, 18)   // the degree sign hangs right, like iOS Weather
                .contentTransition(.numericText())
                .accessibilityIdentifier("weather.temperature")
            Text(forecast.condition.text)
                .font(.system(size: 20, weight: .medium))
                .opacity(0.9)
            if let high = forecast.todayHighC, let low = forecast.todayLowC {
                Text("H:\(weather.format(high))  L:\(weather.format(low))")
                    .font(.system(size: 20, weight: .medium))
            }
        }
        // Readable over white clouds drifting behind it.
        .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Cards

/// The translucent rounded card iOS Weather uses, with a small caption header.
private struct WeatherCard<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .textCase(.uppercase)
                .opacity(0.65)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.85), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct WeatherHourlyCard: View {
    @Environment(WeatherModel.self) private var weather
    let forecast: WeatherForecast

    var body: some View {
        let hours = forecast.nextHours(24, from: .now)
        VStack(alignment: .leading, spacing: 10) {
            Text(summary(hours))
                .font(.system(size: 16, weight: .medium))
                .lineLimit(2)
            Divider().overlay(.white.opacity(0.3))
            ScrollView(.horizontal) {
                HStack(spacing: 18) {
                    ForEach(Array(hours.enumerated()), id: \.offset) { index, hour in
                        VStack(spacing: 8) {
                            Text(index == 0 ? "Now" : hour.time.formatted(.dateTime.hour()))
                                .font(.system(size: 15, weight: .semibold))
                            VStack(spacing: 1) {
                                Image(systemName: hour.condition.symbol)
                                    .symbolRenderingMode(.multicolor)
                                    .font(.system(size: 22))
                                    .frame(height: 26)
                                if let rain = hour.precipitationProbability, rain >= 20 {
                                    Text("\(rain)%")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))
                                }
                            }
                            .frame(height: 42)
                            Text(weather.format(index == 0 ? forecast.temperatureC : hour.temperatureC))
                                .font(.system(size: 19, weight: .medium))
                                .monospacedDigit()
                        }
                        .frame(minWidth: 44)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.85), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("weather.hourly")
    }

    /// One plain sentence, like iOS: when rain is coming, else what the sky is doing.
    private func summary(_ hours: [HourlyForecast]) -> String {
        if let wet = hours.prefix(12).first(where: { ($0.precipitationProbability ?? 0) >= 50 }) {
            let when = wet.time.timeIntervalSinceNow < 45 * 60 ? "soon" : "around \(wet.time.formatted(.dateTime.hour()))"
            return "\(wet.condition.text) expected \(when)."
        }
        var text = "\(forecast.condition.text) conditions"
        if let gust = forecast.details.windGustKmh, gust >= 40 {
            text += ", with wind gusts up to \(WeatherUnits.speed(gust))"
        }
        return text + " for the next few hours."
    }
}

private struct WeatherDailyCard: View {
    @Environment(WeatherModel.self) private var weather
    let forecast: WeatherForecast

    var body: some View {
        let days = forecast.daily
        let weekLow = days.map(\.lowC).min() ?? 0
        let weekHigh = days.map(\.highC).max() ?? 1
        WeatherCard(symbol: "calendar", title: "\(days.count)-day forecast") {
            VStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    if index > 0 { Divider().overlay(.white.opacity(0.25)) }
                    HStack(spacing: 10) {
                        Text(index == 0 ? "Today" : day.date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 64, alignment: .leading)
                        VStack(spacing: 0) {
                            Image(systemName: day.condition.symbol)
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: 20))
                            if let rain = day.precipitationProbability, rain >= 20 {
                                Text("\(rain)%")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))
                            }
                        }
                        .frame(width: 40, height: 40)
                        Text(weather.format(day.lowC))
                            .font(.system(size: 18, weight: .medium))
                            .opacity(0.6)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                        TemperatureRangeBar(low: day.lowC, high: day.highC, weekLow: weekLow, weekHigh: weekHigh,
                                            current: index == 0 ? forecast.temperatureC : nil)
                        Text(weather.format(day.highC))
                            .font(.system(size: 18, weight: .medium))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    .frame(minHeight: 46)
                }
            }
        }
        .accessibilityIdentifier("weather.daily")
    }
}

/// The 10-day bar: the day's range within the week's range, coloured cool to warm, with
/// a dot for the current temperature on today's row.
private struct TemperatureRangeBar: View {
    let low: Double, high: Double, weekLow: Double, weekHigh: Double
    var current: Double?

    var body: some View {
        GeometryReader { proxy in
            let span = max(1, weekHigh - weekLow)
            let x0 = (low - weekLow) / span * proxy.size.width
            let x1 = (high - weekLow) / span * proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.25))
                Capsule()
                    .fill(LinearGradient(colors: [Self.color(low), Self.color(high)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, x1 - x0))
                    .offset(x: x0)
                if let current {
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1.5))
                        .frame(width: 7, height: 7)
                        .offset(x: min(max(0, (current - weekLow) / span * proxy.size.width - 3.5), proxy.size.width - 7))
                }
            }
            .frame(height: 5)
            .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 70, maxWidth: .infinity)
        .frame(height: 20)
    }

    /// Blue when cold, green-teal mild, yellow warm, orange-red hot (iOS Weather's scale).
    static func color(_ celsius: Double) -> Color {
        let stops: [(Double, Color)] = [
            (-5, Color(red: 0.36, green: 0.55, blue: 1.0)),
            (8, Color(red: 0.35, green: 0.80, blue: 0.95)),
            (16, Color(red: 0.55, green: 0.86, blue: 0.55)),
            (23, Color(red: 0.98, green: 0.82, blue: 0.25)),
            (30, Color(red: 1.0, green: 0.55, blue: 0.20)),
            (38, Color(red: 0.96, green: 0.28, blue: 0.22)),
        ]
        return stops.min(by: { abs($0.0 - celsius) < abs($1.0 - celsius) })!.1
    }
}

// MARK: - Detail tiles

private struct WeatherTileGrid: View {
    @Environment(WeatherModel.self) private var weather
    let forecast: WeatherForecast
    let columns: Int

    var body: some View {
        let d = forecast.details
        let today = forecast.daily.first
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 14) {
            if let feels = d.apparentC {
                tile("thermometer.medium", "Feels like", weather.format(feels),
                     abs(feels - forecast.temperatureC) < 2 ? "Similar to the actual temperature."
                        : feels < forecast.temperatureC ? "Wind is making it feel cooler." : "Humidity is making it feel warmer.")
            }
            if let uv = d.uvIndex ?? today?.uvIndexMax {
                WeatherCard(symbol: "sun.max.fill", title: "UV index") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(Int(uv.rounded()))").font(.system(size: 34, weight: .medium))
                        Text(Self.uvLevel(uv)).font(.system(size: 18, weight: .semibold))
                        UVBar(value: uv)
                    }
                    .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                }
            }
            if let wind = d.windKmh {
                WeatherCard(symbol: "wind", title: "Wind") {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(WeatherUnits.speed(wind)).font(.system(size: 24, weight: .medium))
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .fixedSize(horizontal: true, vertical: false)
                            if let gust = d.windGustKmh {
                                Text("Gusts \(WeatherUnits.speed(gust))").font(.system(size: 14, weight: .medium)).opacity(0.75)
                            }
                        }
                        Spacer(minLength: 0)
                        if let direction = d.windDirection { Compass(degrees: direction) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
                }
            }
            if let sunrise = today?.sunrise, let sunset = today?.sunset {
                let upcomingSunset = Date.now < sunset && Date.now > sunrise
                tile(upcomingSunset ? "sunset.fill" : "sunrise.fill", upcomingSunset ? "Sunset" : "Sunrise",
                     (upcomingSunset ? sunset : sunrise).formatted(date: .omitted, time: .shortened),
                     upcomingSunset ? "Sunrise: \(sunrise.formatted(date: .omitted, time: .shortened))"
                        : "Sunset: \(sunset.formatted(date: .omitted, time: .shortened))")
            }
            if let humidity = d.humidity {
                tile("humidity.fill", "Humidity", "\(humidity)%",
                     d.dewPointC.map { "The dew point is \(weather.format($0)) right now." } ?? "")
            }
            if let rain = d.precipitationMM {
                tile("drop.fill", "Precipitation", WeatherUnits.rain(rain), "In the last hour.")
            }
            if let visibility = d.visibilityM {
                tile("eye.fill", "Visibility", WeatherUnits.distance(visibility),
                     visibility >= 10_000 ? "Perfectly clear view." : visibility >= 4_000 ? "Light haze." : "Reduced visibility. Take care.")
            }
            if let pressure = d.pressureHPa {
                tile("gauge.with.dots.needle.33percent", "Pressure", "\(Int(pressure.rounded())) hPa", "")
            }
        }
    }

    private func tile(_ symbol: String, _ title: String, _ value: String, _ note: String) -> some View {
        WeatherCard(symbol: symbol, title: title) {
            VStack(alignment: .leading, spacing: 6) {
                Text(value).font(.system(size: 30, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                Text(note).font(.system(size: 14, weight: .medium)).opacity(0.85).lineLimit(3)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        }
    }

    static func uvLevel(_ uv: Double) -> String {
        switch uv {
        case ..<3: "Low"
        case ..<6: "Moderate"
        case ..<8: "High"
        case ..<11: "Very high"
        default: "Extreme"
        }
    }
}

private struct UVBar: View {
    let value: Double
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [.green, .yellow, .orange, .red, .purple],
                                              startPoint: .leading, endPoint: .trailing))
                Circle().fill(.white).overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1.5))
                    .frame(width: 8, height: 8)
                    .offset(x: min(max(0, value / 11 * proxy.size.width - 4), proxy.size.width - 8))
            }
            .frame(height: 5).frame(maxHeight: .infinity)
        }
        .frame(height: 10)
    }
}

private struct Compass: View {
    let degrees: Double
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.3), lineWidth: 2)
            ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { index, letter in
                Text(letter).font(.system(size: 10, weight: .bold)).opacity(0.75)
                    .offset(y: -20).rotationEffect(.degrees(Double(index) * 90))
            }
            // Wind blows *from* `degrees`: the arrow points where it's going.
            Image(systemName: "location.north.fill")
                .font(.system(size: 22))
                .rotationEffect(.degrees(degrees + 180))
        }
        .frame(width: 54, height: 54)
    }
}

/// Metric or imperial by region, like the rest of iOS.
enum WeatherUnits {
    static var metric: Bool { Locale.current.measurementSystem != .us }
    static func speed(_ kmh: Double) -> String {
        metric ? "\(Int(kmh.rounded())) km/h" : "\(Int((kmh * 0.621371).rounded())) mph"
    }
    static func distance(_ metres: Double) -> String {
        metric ? "\(Int((metres / 1000).rounded())) km" : "\(Int((metres / 1609.34).rounded())) mi"
    }
    static func rain(_ mm: Double) -> String {
        metric ? String(format: "%.1f mm", mm) : String(format: "%.2f in", mm / 25.4)
    }
}

// MARK: - Sky

/// The animated background: colour by condition and time of day, plus rain, snow,
/// drifting clouds, stars, a sun glow or lightning, drawn with Canvas.
struct WeatherSky: View {
    var condition: WeatherCondition?
    var isDay: Bool

    private enum Kind { case clear, partly, cloudy, rain, storm, snow, fog }

    private var kind: Kind {
        guard let code = condition?.code else { return .partly }
        switch code {
        case 0, 1: return .clear
        case 2: return .partly
        case 3: return .cloudy
        case 45, 48: return .fog
        case 71...77, 85, 86: return .snow
        case 95...99: return .storm
        case 51...67, 80...82: return .rain
        default: return .cloudy
        }
    }

    private var colors: [Color] {
        if !isDay {
            switch kind {
            case .clear, .partly: return [Color(red: 0.03, green: 0.06, blue: 0.18), Color(red: 0.14, green: 0.21, blue: 0.40)]
            default: return [Color(red: 0.10, green: 0.13, blue: 0.20), Color(red: 0.22, green: 0.26, blue: 0.33)]
            }
        }
        switch kind {
        case .clear: return [Color(red: 0.13, green: 0.47, blue: 0.86), Color(red: 0.45, green: 0.72, blue: 0.95)]
        case .partly: return [Color(red: 0.24, green: 0.50, blue: 0.80), Color(red: 0.56, green: 0.72, blue: 0.88)]
        case .cloudy: return [Color(red: 0.36, green: 0.43, blue: 0.52), Color(red: 0.56, green: 0.62, blue: 0.69)]
        case .rain: return [Color(red: 0.24, green: 0.30, blue: 0.38), Color(red: 0.40, green: 0.47, blue: 0.55)]
        case .storm: return [Color(red: 0.14, green: 0.17, blue: 0.24), Color(red: 0.30, green: 0.33, blue: 0.40)]
        case .snow: return [Color(red: 0.43, green: 0.51, blue: 0.60), Color(red: 0.68, green: 0.74, blue: 0.80)]
        case .fog: return [Color(red: 0.48, green: 0.52, blue: 0.57), Color(red: 0.66, green: 0.69, blue: 0.72)]
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                let rect = CGRect(origin: .zero, size: size)
                gc.fill(Path(rect), with: .linearGradient(Gradient(colors: colors), startPoint: .zero,
                                                          endPoint: CGPoint(x: 0, y: size.height)))
                switch kind {
                case .clear:
                    if isDay { sun(&gc, size, t) } else { stars(&gc, size, t) }
                case .partly:
                    if isDay { sun(&gc, size, t) } else { stars(&gc, size, t) }
                    clouds(&gc, size, t, count: 3, opacity: 0.55)
                case .cloudy:
                    clouds(&gc, size, t, count: 5, opacity: 0.45)
                case .rain:
                    clouds(&gc, size, t, count: 4, opacity: 0.30)
                    rain(&gc, size, t, drops: 120)
                case .storm:
                    clouds(&gc, size, t, count: 5, opacity: 0.30)
                    rain(&gc, size, t, drops: 180)
                    lightning(&gc, size, t)
                case .snow:
                    clouds(&gc, size, t, count: 3, opacity: 0.30)
                    snow(&gc, size, t)
                case .fog:
                    fog(&gc, size, t)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // Deterministic pseudo-random numbers so particles keep their place between frames.
    private func r(_ i: Int, _ salt: Int) -> Double {
        let x = sin(Double(i * 127 + salt * 311) * 12.9898) * 43758.5453
        return x - floor(x)
    }

    private func sun(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let center = CGPoint(x: size.width * 0.82, y: size.height * 0.06)
        let pulse = 1 + 0.04 * sin(t * 0.8)
        for (radius, alpha) in [(size.width * 0.55, 0.10), (size.width * 0.32, 0.16), (size.width * 0.14, 0.30)] {
            let r = radius * pulse
            gc.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                    with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.96, blue: 0.8).opacity(alpha), .clear]),
                                          center: center, startRadius: 0, endRadius: r))
        }
    }

    private func stars(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        for i in 0..<90 {
            let x = r(i, 1) * size.width, y = r(i, 2) * size.height * 0.75
            let twinkle = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * (0.6 + r(i, 3)) + r(i, 4) * 6))
            let s = 0.8 + r(i, 5) * 1.6
            gc.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s, height: s)), with: .color(.white.opacity(twinkle * 0.9)))
        }
    }

    private func clouds(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double, count: Int, opacity: Double) {
        for i in 0..<count {
            let w = size.width * (0.45 + r(i, 6) * 0.4)
            let speed = 6 + r(i, 7) * 10
            let x = (r(i, 8) * (size.width + w) + t * speed).truncatingRemainder(dividingBy: size.width + w) - w
            let y = size.height * (0.02 + r(i, 9) * 0.35)
            var cloud = gc
            cloud.addFilter(.blur(radius: 18))
            for puff in 0..<4 {
                let pw = w * (0.35 + r(i * 7 + puff, 10) * 0.35)
                let px = x + Double(puff) * w * 0.2
                let py = y + (r(i * 7 + puff, 11) - 0.5) * 30
                cloud.fill(Path(ellipseIn: CGRect(x: px, y: py, width: pw, height: pw * 0.55)),
                           with: .color(.white.opacity(opacity)))
            }
        }
    }

    private func rain(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double, drops: Int) {
        for i in 0..<drops {
            let speed = 520 + r(i, 12) * 380
            let length = 14 + r(i, 13) * 16
            let x0 = r(i, 14) * (size.width + 80)
            let y = (r(i, 15) * (size.height + length) + t * speed).truncatingRemainder(dividingBy: size.height + length) - length
            let x = x0 - y * 0.12
            var path = Path()
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x - length * 0.12, y: y + length))
            gc.stroke(path, with: .color(.white.opacity(0.18 + r(i, 16) * 0.25)), lineWidth: 1.1)
        }
    }

    private func snow(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        for i in 0..<110 {
            let speed = 30 + r(i, 17) * 45
            let s = 2 + r(i, 18) * 4
            let y = (r(i, 19) * (size.height + s) + t * speed).truncatingRemainder(dividingBy: size.height + s) - s
            let x = r(i, 20) * size.width + sin(t * 0.8 + r(i, 21) * 6) * 14
            gc.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s, height: s)), with: .color(.white.opacity(0.55 + r(i, 22) * 0.4)))
        }
    }

    private func fog(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        var haze = gc
        haze.addFilter(.blur(radius: 30))
        for i in 0..<6 {
            let y = size.height * (0.1 + Double(i) * 0.15)
            let x = sin(t * 0.1 + Double(i)) * 60 - 60
            haze.fill(Path(roundedRect: CGRect(x: x, y: y, width: size.width + 120, height: 60), cornerRadius: 30),
                      with: .color(.white.opacity(0.16)))
        }
    }

    private func lightning(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        // A brief double flash every ~7 s.
        let phase = t.truncatingRemainder(dividingBy: 7)
        let flash = phase < 0.08 || (phase > 0.18 && phase < 0.24)
        if flash { gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.22))) }
    }
}
