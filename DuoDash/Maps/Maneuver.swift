import MapKit

/// MKRoute.Step only gives an instruction string, so the arrow is picked from its wording.
enum Maneuver {
    static func symbol(for instruction: String) -> String {
        let text = instruction.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }

        if has("arrive", "destination", "you have arrived") { return "flag.checkered" }
        if has("u-turn", "make a u turn") {
            return has("right") ? "arrow.uturn.right" : "arrow.uturn.left"
        }
        if has("roundabout", "traffic circle", "rotary") { return "arrow.clockwise" }
        if has("merge") { return "arrow.merge" }
        if has("slight left", "bear left", "keep left") { return "arrow.up.left" }
        if has("slight right", "bear right", "keep right") { return "arrow.up.right" }
        if has("exit", "off-ramp", "ramp") {
            return has("left") ? "arrow.up.left" : "arrow.up.right"
        }
        if has("sharp left", "turn left", " left onto", "left at", "left on") { return "arrow.turn.up.left" }
        if has("sharp right", "turn right", " right onto", "right at", "right on") { return "arrow.turn.up.right" }
        if has("ferry") { return "ferry.fill" }
        return "arrow.up"
    }
}

enum DistanceText {
    private static let short: MKDistanceFormatter = {
        let f = MKDistanceFormatter()
        f.unitStyle = .abbreviated
        return f
    }()

    private static let spoken: MKDistanceFormatter = {
        let f = MKDistanceFormatter()
        f.unitStyle = .full
        return f
    }()

    /// Rounded the way a driver wants to hear it: 10 m steps up close, 50 m below a kilometre.
    static func rounded(_ metres: CLLocationDistance) -> CLLocationDistance {
        switch metres {
        case ..<100: return max(10, (metres / 10).rounded() * 10)
        case ..<1000: return (metres / 50).rounded() * 50
        default: return metres
        }
    }

    static func display(_ metres: CLLocationDistance) -> String { short.string(fromDistance: rounded(metres)) }
    static func speech(_ metres: CLLocationDistance) -> String { spoken.string(fromDistance: rounded(metres)) }
}

extension MKMultiPoint {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

extension MKMapItem {
    /// One-line address for display (replaces the deprecated `placemark.title`).
    var addressLine: String? {
        addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
            ?? address?.shortAddress
            ?? address?.fullAddress
    }
}
