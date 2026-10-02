import CoreBluetooth
import Foundation

/// Herkenning van fabrikanten (Bluetooth SIG company identifiers), Apple Continuity-berichten
/// en bekende 16-bit service-UUID's.
enum BLEInfo {
    static let companies: [UInt16: String] = [
        0x0000: "Ericsson",
        0x0001: "Nokia",
        0x0002: "Intel",
        0x0003: "IBM",
        0x0006: "Microsoft",
        0x000A: "Qualcomm (CSR)",
        0x000D: "Texas Instruments",
        0x000F: "Broadcom",
        0x001D: "Qualcomm",
        0x004C: "Apple",
        0x0059: "Nordic Semiconductor",
        0x005D: "Realtek",
        0x006B: "Polar",
        0x0075: "Samsung",
        0x0087: "Garmin",
        0x009E: "Bose",
        0x00C4: "LG Electronics",
        0x00E0: "Google",
        0x012D: "Sony",
        0x0171: "Amazon",
        0x01DA: "Logitech",
        0x027D: "Huawei",
        0x02E5: "Espressif",
        0x038F: "Xiaomi",
    ]

    static let services: [String: String] = [
        "1800": "Generic Access",
        "1801": "Generic Attribute",
        "180A": "Device Information",
        "180D": "Heart Rate",
        "180F": "Battery",
        "1812": "HID (toetsenbord/muis)",
        "1816": "Cycling Speed & Cadence",
        "1818": "Cycling Power",
        "181C": "User Data",
        "FD6F": "Exposure Notification",
        "FD5A": "Samsung SmartTag",
        "FE2C": "Google Fast Pair",
        "FE9F": "Google",
        "FEAA": "Eddystone-beacon",
        "FEEC": "Tile",
        "FEED": "Tile",
        "FE03": "Amazon",
        "FE07": "Sonos",
        "FE95": "Xiaomi",
    ]

    static func companyID(_ data: Data?) -> UInt16? {
        guard let data, data.count >= 2 else { return nil }
        let b = [UInt8](data)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    static func companyName(_ id: UInt16) -> String {
        companies[id] ?? String(format: "Onbekend (0x%04X)", id)
    }

    static func serviceName(_ uuid: CBUUID) -> String {
        if let name = services[uuid.uuidString.uppercased()] { return "\(name) (\(uuid.uuidString))" }
        return uuid.uuidString
    }

    static func hex(_ data: Data?) -> String {
        guard let data else { return "–" }
        return data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: - Apple Continuity

    private static let appleModels: [UInt16: String] = [
        0x0220: "AirPods (1e gen)",
        0x0F20: "AirPods (2e gen)",
        0x1320: "AirPods (3e gen)",
        0x0E20: "AirPods Pro",
        0x1420: "AirPods Pro (2e gen)",
        0x2420: "AirPods Pro (2e gen, USB-C)",
        0x0A20: "AirPods Max",
        0x0320: "Powerbeats3",
        0x0520: "BeatsX",
        0x0620: "Beats Solo3",
        0x0920: "Beats Studio3",
        0x0B20: "Powerbeats Pro",
        0x1020: "Beats Flex",
        0x1120: "Beats Studio Buds",
    ]

    /// Ontleedt de TLV-structuur van Apple-fabrikantdata naar leesbare berichttypes.
    static func describeManufacturer(_ data: Data?) -> [String] {
        guard let data, let cid = companyID(data) else { return [] }
        let b = [UInt8](data)
        switch cid {
        case 0x004C: return appleMessages(b)
        case 0x0006 where b.count >= 3:
            switch b[2] {
            case 0x01: return ["Microsoft CDP-beacon (Windows-apparaat)"]
            case 0x03: return ["Microsoft Swift Pair"]
            default: return [String(format: "Microsoft beacon type 0x%02X", b[2])]
            }
        default: return []
        }
    }

    private static func appleMessages(_ b: [UInt8]) -> [String] {
        var out: [String] = []
        var i = 2
        while i + 1 < b.count {
            let type = b[i]
            let len = Int(b[i + 1])
            let start = i + 2
            let end = min(start + len, b.count)
            let p = Array(b[start..<end])
            out.append(appleMessage(type, p))
            i = end
        }
        return out
    }

    private static func appleMessage(_ type: UInt8, _ p: [UInt8]) -> String {
        switch type {
        case 0x02:
            if p.count >= 21 {
                let major = UInt16(p[16]) << 8 | UInt16(p[17])
                let minor = UInt16(p[18]) << 8 | UInt16(p[19])
                return "iBeacon (major \(major), minor \(minor), 1 m-vermogen \(Int8(bitPattern: p[20])) dBm)"
            }
            return "iBeacon"
        case 0x05: return "AirDrop"
        case 0x06: return "HomeKit-accessoire"
        case 0x07:
            if p.count >= 3 {
                let model = UInt16(p[1]) << 8 | UInt16(p[2])
                return appleModels[model].map { "\($0) (proximity pairing)" }
                    ?? String(format: "AirPods/Beats (model 0x%04X)", model)
            }
            return "AirPods/Beats (proximity pairing)"
        case 0x09: return "AirPlay-ontvanger"
        case 0x0A: return "AirPlay-bron"
        case 0x0B: return "Apple Watch (Magic Switch)"
        case 0x0C: return "Handoff"
        case 0x0D: return "Instant Hotspot (aanbieder)"
        case 0x0E: return "Instant Hotspot (zoekt)"
        case 0x0F: return "Nearby Action"
        case 0x10: return "Nearby Info (iPhone/iPad/Mac/Watch)"
        case 0x12: return p.count >= 20 ? "Find My (AirTag / offline-netwerk, volledige sleutel)" : "Find My (offline-netwerk)"
        default: return String(format: "Apple-bericht 0x%02X", type)
        }
    }

    /// iBeacon bevat een gekalibreerd vermogen op 1 m; dat is de beste standaardreferentie.
    static func iBeaconMeasuredPower(_ data: Data?) -> Double? {
        guard let data, companyID(data) == 0x004C else { return nil }
        let b = [UInt8](data)
        guard b.count >= 25, b[2] == 0x02, b[3] == 0x15 else { return nil }
        return Double(Int8(bitPattern: b[24]))
    }

    /// Korte typering voor in de lijst.
    static func shortKind(_ data: Data?) -> String? {
        let msgs = describeManufacturer(data)
        return msgs.first { !$0.hasPrefix("Apple-bericht") } ?? msgs.first
    }
}
