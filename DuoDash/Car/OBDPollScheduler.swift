import Foundation

/// Something the poll loop asks the adapter for.
enum CarPollItem: Hashable {
    case pid(OBDPID)
    case battery
    case troubleCodes

    var interval: TimeInterval {
        switch self {
        case .pid(let pid): pid.pollInterval
        case .battery: 3
        case .troubleCodes: 300
        }
    }
}

/// Decides what to ask for next. Each item is due every `interval` seconds; the item
/// that has been due longest goes first (ties: the one served least recently). Fast items can't starve slow ones: once a slow item is due, every fast
/// item that becomes due later queues behind it. Commands go one at a time, so the
/// adapter is never flooded; when it's slower than the schedule everything simply
/// takes turns.
struct OBDPollScheduler {
    private var intervals: [CarPollItem: TimeInterval] = [:]
    private var due: [CarPollItem: TimeInterval] = [:]
    private var lastServed: [CarPollItem: Int] = [:]
    private var order: [CarPollItem] = []
    private var serial = 0

    init(items: [CarPollItem], now: TimeInterval) {
        for item in items where intervals[item] == nil {
            intervals[item] = item.interval
            due[item] = now
            order.append(item)
        }
    }

    var items: [CarPollItem] { order }

    func nextItem(now: TimeInterval) -> CarPollItem? {
        var best: CarPollItem?
        for item in order {
            guard let when = due[item], when <= now else { continue }
            guard let current = best, let currentDue = due[current] else { best = item; continue }
            if when < currentDue || (when == currentDue && lastServed[item, default: -1] < lastServed[current, default: -1]) {
                best = item
            }
        }
        return best
    }

    mutating func didPoll(_ item: CarPollItem, at now: TimeInterval) {
        guard let interval = intervals[item] else { return }
        // Keep the item's cadence (4 Hz stays 4 Hz despite command time), but never
        // schedule into the past: a late item rejoins the queue now rather than
        // piling up a backlog that would crowd others out.
        due[item] = max((due[item] ?? now) + interval, now)
        lastServed[item] = serial
        serial += 1
    }

    mutating func remove(_ item: CarPollItem) {
        intervals[item] = nil
        due[item] = nil
        order.removeAll { $0 == item }
    }

    /// Seconds until something is due (0 if something already is).
    func timeUntilNextDue(now: TimeInterval) -> TimeInterval {
        guard let soonest = due.values.min() else { return 1 }
        return max(0, soonest - now)
    }
}
