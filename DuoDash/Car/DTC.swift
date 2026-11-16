import Foundation

/// A diagnostic trouble code such as P0420.
struct DTC: Hashable, Identifiable {
    let code: String
    var isPending = false

    var id: String { "\(code)\(isPending ? "-pending" : "")" }

    /// The built-in description, or a generic one from the code's family.
    var description: String {
        if let known = DTC.descriptions[code] { return known }
        guard let system = code.first else { return "Unknown code" }
        let manufacturer = code.dropFirst().first.map { $0 != "0" && $0 != "2" } ?? false
        switch system {
        case "P": return manufacturer ? "Manufacturer-specific engine or transmission fault" : "Engine or transmission fault"
        case "C": return "Chassis fault (brakes, suspension or steering)"
        case "B": return "Body fault (airbags, lighting or comfort systems)"
        case "U": return "Network communication fault between modules"
        default: return "Unknown code"
        }
    }

    /// Two bytes to a code: the top two bits pick P/C/B/U, then four hex digits.
    static func decode(_ a: UInt8, _ b: UInt8) -> String {
        let system = ["P", "C", "B", "U"][Int(a >> 6)]
        return system + String(format: "%01X%01X%02X", UInt32((a >> 4) & 0x03), UInt32(a & 0x0F), UInt32(b))
    }

    /// Codes from mode 03 / 07 / 0A payloads (the bytes after 0x43 / 0x47 / 0x4A).
    /// CAN replies start with a count byte (so the payload length is odd); older
    /// protocols send three code pairs per message, padded with zeros.
    static func codes(fromPayloads payloads: [[UInt8]], pending: Bool = false) -> [DTC] {
        var seen = Set<String>()
        var result: [DTC] = []
        for payload in payloads {
            var bytes = payload
            if bytes.count % 2 == 1 {
                let count = Int(bytes[0])
                bytes = Array(bytes.dropFirst().prefix(count * 2))
            }
            var index = 0
            while index + 1 < bytes.count {
                let (a, b) = (bytes[index], bytes[index + 1])
                index += 2
                if a == 0 && b == 0 { continue }
                let code = decode(a, b)
                if seen.insert(code).inserted { result.append(DTC(code: code, isPending: pending)) }
            }
        }
        return result
    }

    /// The most common generic powertrain codes. Anything else gets a family description.
    static let descriptions: [String: String] = [
        "P0010": "Camshaft position actuator circuit (bank 1)",
        "P0011": "Camshaft timing over-advanced (bank 1)",
        "P0012": "Camshaft timing over-retarded (bank 1)",
        "P0016": "Crankshaft and camshaft position don't agree (bank 1)",
        "P0030": "Oxygen sensor heater circuit (bank 1, sensor 1)",
        "P0036": "Oxygen sensor heater circuit (bank 1, sensor 2)",
        "P0068": "Manifold pressure / throttle position don't agree",
        "P0087": "Fuel rail pressure too low",
        "P0100": "Mass air flow sensor circuit",
        "P0101": "Mass air flow sensor range/performance",
        "P0102": "Mass air flow sensor low input",
        "P0103": "Mass air flow sensor high input",
        "P0106": "Manifold pressure sensor range/performance",
        "P0107": "Manifold pressure sensor low input",
        "P0108": "Manifold pressure sensor high input",
        "P0110": "Intake air temperature sensor circuit",
        "P0112": "Intake air temperature sensor low input",
        "P0113": "Intake air temperature sensor high input",
        "P0115": "Coolant temperature sensor circuit",
        "P0116": "Coolant temperature sensor range/performance",
        "P0117": "Coolant temperature sensor low input",
        "P0118": "Coolant temperature sensor high input",
        "P0120": "Throttle position sensor circuit",
        "P0121": "Throttle position sensor range/performance",
        "P0122": "Throttle position sensor low input",
        "P0123": "Throttle position sensor high input",
        "P0125": "Engine takes too long to warm up for closed-loop fuel control",
        "P0128": "Coolant below thermostat temperature (thermostat stuck open?)",
        "P0130": "Oxygen sensor circuit (bank 1, sensor 1)",
        "P0131": "Oxygen sensor low voltage (bank 1, sensor 1)",
        "P0132": "Oxygen sensor high voltage (bank 1, sensor 1)",
        "P0133": "Oxygen sensor slow response (bank 1, sensor 1)",
        "P0134": "Oxygen sensor no activity (bank 1, sensor 1)",
        "P0135": "Oxygen sensor heater circuit (bank 1, sensor 1)",
        "P0136": "Oxygen sensor circuit (bank 1, sensor 2)",
        "P0137": "Oxygen sensor low voltage (bank 1, sensor 2)",
        "P0138": "Oxygen sensor high voltage (bank 1, sensor 2)",
        "P0139": "Oxygen sensor slow response (bank 1, sensor 2)",
        "P0141": "Oxygen sensor heater circuit (bank 1, sensor 2)",
        "P0171": "Running lean (bank 1)",
        "P0172": "Running rich (bank 1)",
        "P0174": "Running lean (bank 2)",
        "P0175": "Running rich (bank 2)",
        "P0181": "Fuel temperature sensor range/performance",
        "P0201": "Injector circuit, cylinder 1",
        "P0202": "Injector circuit, cylinder 2",
        "P0203": "Injector circuit, cylinder 3",
        "P0204": "Injector circuit, cylinder 4",
        "P0217": "Engine overheating",
        "P0230": "Fuel pump primary circuit",
        "P0300": "Random or multiple cylinder misfire",
        "P0301": "Cylinder 1 misfire",
        "P0302": "Cylinder 2 misfire",
        "P0303": "Cylinder 3 misfire",
        "P0304": "Cylinder 4 misfire",
        "P0325": "Knock sensor circuit (sensor 1)",
        "P0327": "Knock sensor low input (sensor 1)",
        "P0328": "Knock sensor high input (sensor 1)",
        "P0335": "Crankshaft position sensor circuit",
        "P0336": "Crankshaft position sensor range/performance",
        "P0340": "Camshaft position sensor circuit",
        "P0341": "Camshaft position sensor range/performance",
        "P0351": "Ignition coil A circuit",
        "P0352": "Ignition coil B circuit",
        "P0353": "Ignition coil C circuit",
        "P0354": "Ignition coil D circuit",
        "P0400": "Exhaust gas recirculation (EGR) flow",
        "P0401": "EGR flow insufficient",
        "P0402": "EGR flow excessive",
        "P0420": "Catalytic converter efficiency below threshold (bank 1)",
        "P0430": "Catalytic converter efficiency below threshold (bank 2)",
        "P0440": "Evaporative emission (EVAP) system",
        "P0441": "EVAP system incorrect purge flow",
        "P0442": "EVAP system small leak (check the fuel cap)",
        "P0443": "EVAP purge valve circuit",
        "P0446": "EVAP vent control circuit",
        "P0455": "EVAP system large leak (check the fuel cap)",
        "P0456": "EVAP system very small leak",
        "P0496": "EVAP system high purge flow",
        "P0500": "Vehicle speed sensor",
        "P0505": "Idle air control system",
        "P0506": "Idle speed lower than expected",
        "P0507": "Idle speed higher than expected",
        "P0562": "System voltage low",
        "P0563": "System voltage high",
        "P0600": "Serial communication link",
        "P0603": "Engine computer keep-alive memory error",
        "P0606": "Engine computer processor fault",
        "P0700": "Transmission control system (has its own codes)",
        "P0715": "Transmission input speed sensor",
        "P0720": "Transmission output speed sensor",
        "P0740": "Torque converter clutch circuit",
        "P0750": "Shift solenoid A",
    ]
}
