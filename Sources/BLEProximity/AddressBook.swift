import Foundation
import IOBluetooth

/// macOS geeft via CoreBluetooth geen MAC-adressen vrij, alleen een per-Mac UUID.
/// Wel kent IOBluetooth het (identiteits)adres van alle apparaten die met deze Mac
/// gekoppeld of via iCloud gelinkt zijn — hetzelfde adres dat iOS onder
/// Instellingen › Algemeen › Info › Bluetooth toont. Die koppelen we op naam.
struct KnownDevice {
    let name: String
    let address: String
    let connected: Bool
}

enum AddressMatch {
    case known(KnownDevice)
    case ambiguous([KnownDevice])
    case hidden

    var address: String? {
        if case .known(let d) = self { return d.address }
        return nil
    }
}

@MainActor
final class AddressBook {
    private var byName: [String: [KnownDevice]] = [:]
    private var lastLoad = Date.distantPast

    func reloadIfNeeded() {
        guard Date().timeIntervalSince(lastLoad) > 10 else { return }
        lastLoad = Date()
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        var map: [String: [KnownDevice]] = [:]
        for d in devices {
            guard let name = d.name, let raw = d.addressString else { continue }
            let address = raw.replacingOccurrences(of: "-", with: ":").uppercased()
            map[Self.key(name), default: []].append(KnownDevice(name: name, address: address, connected: d.isConnected()))
        }
        byName = map
    }

    func match(name: String?) -> AddressMatch {
        guard let name, let candidates = byName[Self.key(name)], !candidates.isEmpty else { return .hidden }
        if candidates.count == 1 { return .known(candidates[0]) }
        let connected = candidates.filter(\.connected)
        if connected.count == 1 { return .known(connected[0]) }
        return .ambiguous(candidates)
    }

    private static func key(_ name: String) -> String {
        name.replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
