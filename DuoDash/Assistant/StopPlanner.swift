import MapKit

/// Pure geometry and ranking for "stop for petrol on the way". MapKit calls live in
/// AssistantModel; everything here is deterministic and unit-tested.
enum StopPlanner {
    struct Candidate: Equatable {
        var id: String
        var coordinate: CLLocationCoordinate2D

        static func == (a: Candidate, b: Candidate) -> Bool {
            a.id == b.id && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
        }
    }

    /// Drive times for one candidate: start → stop and stop → destination. nil when
    /// MapKit couldn't give an ETA for that part.
    struct Option: Equatable {
        var id: String
        var toStop: TimeInterval?
        var toDestination: TimeInterval?
    }

    struct Ranked: Equatable {
        var id: String
        var total: TimeInterval
        /// Extra time compared with driving straight there (nil if the direct time is unknown).
        var added: TimeInterval?
    }

    /// Evenly spaced points along a polyline, roughly every `spacing` metres, at most
    /// `maxCount`. The first and last sample sit half a gap in from the ends, so the
    /// search doesn't waste a sample on where the car already is.
    static func samplePoints(along points: [CLLocationCoordinate2D], spacing: CLLocationDistance,
                             maxCount: Int) -> [CLLocationCoordinate2D] {
        guard points.count > 1, maxCount > 0, spacing > 0 else { return points.prefix(1).map { $0 } }
        var cumulative: [CLLocationDistance] = [0]
        for k in 1..<points.count {
            cumulative.append(cumulative[k - 1] + MKMapPoint(points[k - 1]).distance(to: MKMapPoint(points[k])))
        }
        let total = cumulative.last ?? 0
        guard total > 0 else { return [points[0]] }
        let count = min(maxCount, max(1, Int((total / spacing).rounded())))
        let gap = total / Double(count)
        var samples: [CLLocationCoordinate2D] = []
        var segment = 1
        for i in 0..<count {
            let target = gap * (Double(i) + 0.5)
            while segment < points.count - 1 && cumulative[segment] < target { segment += 1 }
            let start = cumulative[segment - 1], end = cumulative[segment]
            let t = end > start ? (target - start) / (end - start) : 0
            let a = MKMapPoint(points[segment - 1]), b = MKMapPoint(points[segment])
            samples.append(MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t).coordinate)
        }
        return samples
    }

    /// Shortest distance from a coordinate to a polyline, in metres.
    static func distance(from coordinate: CLLocationCoordinate2D, to points: [CLLocationCoordinate2D]) -> CLLocationDistance {
        let target = MKMapPoint(coordinate)
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return MKMapPoint(first).distance(to: target) }
        var best = CLLocationDistance.infinity
        for k in 0..<(points.count - 1) {
            let a = MKMapPoint(points[k]), b = MKMapPoint(points[k + 1])
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            var t = lengthSquared > 0 ? ((target.x - a.x) * dx + (target.y - a.y) * dy) / lengthSquared : 0
            t = min(max(t, 0), 1)
            best = min(best, MKMapPoint(x: a.x + t * dx, y: a.y + t * dy).distance(to: target))
        }
        return best
    }

    /// The candidates closest to the route (duplicates by id removed), nearest first.
    /// These are the few worth asking MapKit for real drive times.
    static func shortlist(_ candidates: [Candidate], route points: [CLLocationCoordinate2D],
                          limit: Int = 5, maxOffset: CLLocationDistance = 5_000) -> [Candidate] {
        var seen = Set<String>()
        return candidates
            .filter { seen.insert($0.id).inserted }
            .map { ($0, distance(from: $0.coordinate, to: points)) }
            .filter { $0.1 <= maxOffset }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Orders candidates by total trip time (start → stop → destination), quickest
    /// first. Candidates missing either ETA are dropped. Ties go to the one reached sooner.
    static func rank(_ options: [Option], direct: TimeInterval?) -> [Ranked] {
        options
            .compactMap { option -> (Ranked, TimeInterval)? in
                guard let a = option.toStop, let b = option.toDestination, a >= 0, b >= 0 else { return nil }
                let total = a + b
                return (Ranked(id: option.id, total: total, added: direct.map { max(0, total - $0) }), a)
            }
            .sorted { $0.0.total != $1.0.total ? $0.0.total < $1.0.total : $0.1 < $1.1 }
            .map(\.0)
    }

    /// The single best stop, if any candidate had both ETAs.
    static func best(_ options: [Option], direct: TimeInterval?) -> Ranked? {
        rank(options, direct: direct).first
    }
}
