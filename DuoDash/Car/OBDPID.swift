import Foundation

/// The mode 01 values Duo Dash shows. Each is shown only if the car says it supports it.
enum OBDPID: UInt8, CaseIterable, Identifiable, Hashable {
    case engineLoad = 0x04
    case coolantTemp = 0x05
    case rpm = 0x0C
    case speed = 0x0D
    case intakeTemp = 0x0F
    case throttle = 0x11
    case fuelLevel = 0x2F
    case moduleVoltage = 0x42
    case oilTemp = 0x5C

    var id: UInt8 { rawValue }

    /// The order tiles appear in.
    static let displayOrder: [OBDPID] = [.speed, .rpm, .coolantTemp, .oilTemp, .intakeTemp,
                                         .throttle, .engineLoad, .fuelLevel, .moduleVoltage]

    var command: String { String(format: "01%02X", UInt32(rawValue)) }

    var title: String {
        switch self {
        case .engineLoad: "Engine load"
        case .coolantTemp: "Coolant"
        case .rpm: "RPM"
        case .speed: "Speed"
        case .intakeTemp: "Intake air"
        case .throttle: "Throttle"
        case .fuelLevel: "Fuel"
        case .moduleVoltage: "ECU voltage"
        case .oilTemp: "Oil"
        }
    }

    var unit: String {
        switch self {
        case .engineLoad, .throttle, .fuelLevel: "%"
        case .coolantTemp, .intakeTemp, .oilTemp: "°C"
        case .rpm: "rpm"
        case .speed: "km/h"
        case .moduleVoltage: "V"
        }
    }

    var symbol: String {
        switch self {
        case .engineLoad: "engine.combustion"
        case .coolantTemp: "thermometer.medium"
        case .rpm: "gauge.with.dots.needle.67percent"
        case .speed: "speedometer"
        case .intakeTemp: "wind"
        case .throttle: "pedal.accelerator"
        case .fuelLevel: "fuelpump"
        case .moduleVoltage: "bolt"
        case .oilTemp: "oilcan"
        }
    }

    /// RPM and speed are polled about four times a second; the rest every few seconds.
    var pollInterval: TimeInterval {
        switch self {
        case .rpm, .speed: 0.25
        case .throttle, .engineLoad: 2
        case .coolantTemp, .oilTemp, .moduleVoltage: 3
        case .intakeTemp, .fuelLevel: 5
        }
    }

    var byteCount: Int {
        switch self {
        case .rpm, .moduleVoltage: 2
        default: 1
        }
    }

    /// SAE J1979 formulas.
    func decode(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= byteCount else { return nil }
        let a = Double(bytes[0])
        let b = bytes.count > 1 ? Double(bytes[1]) : 0
        switch self {
        case .engineLoad, .throttle, .fuelLevel: return a * 100 / 255
        case .coolantTemp, .intakeTemp, .oilTemp: return a - 40
        case .rpm: return (256 * a + b) / 4
        case .speed: return a
        case .moduleVoltage: return (256 * a + b) / 1000
        }
    }

    /// The value as shown on a tile: whole numbers, except voltages.
    func format(_ value: Double) -> String {
        switch self {
        case .moduleVoltage: String(format: "%.1f", value)
        default: String(Int(value.rounded()))
        }
    }
}

/// Supported-PID bitmaps (PIDs 0x00, 0x20, 0x40): four bytes, MSB first, where bit 31
/// means `base + 1` and bit 0 means `base + 32` (which says the next bitmap exists).
enum OBDSupport {
    static func decode(_ bitmap: [UInt8], base: UInt8) -> Set<UInt8> {
        var result = Set<UInt8>()
        for (byteIndex, byte) in bitmap.prefix(4).enumerated() {
            for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                let offset = byteIndex * 8 + bit + 1
                result.insert(UInt8(truncatingIfNeeded: Int(base) + offset))
            }
        }
        return result
    }

    static func encode(_ pids: Set<UInt8>, base: UInt8) -> [UInt8] {
        var bitmap: [UInt8] = [0, 0, 0, 0]
        for pid in pids where Int(pid) > Int(base) && Int(pid) <= Int(base) + 32 {
            let offset = Int(pid) - Int(base) - 1
            bitmap[offset / 8] |= 0x80 >> UInt8(offset % 8)
        }
        return bitmap
    }
}
