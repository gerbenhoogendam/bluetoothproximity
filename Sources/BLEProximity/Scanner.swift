import AppKit
import CoreBluetooth
import Observation
import UniformTypeIdentifiers

enum SortOrder: String, CaseIterable, Identifiable {
    case signal = "Signaal"
    case name = "Naam"
    case age = "Eerst gezien"
    var id: String { rawValue }
}

/// UI-model. De engine verwerkt elk pakket op zijn eigen queue; dit model haalt
/// met het ingestelde meetinterval een snapshot op, zodat de UI niet bij elk pakket hertekent.
@Observable @MainActor
final class Scanner {
    private let engine = ScanEngine()
    private let addressBook = AddressBook()
    private var pushedAddresses: [UUID: String] = [:]
    private var timer: Timer?

    var devices: [DeviceSnapshot] = []
    var bluetoothState = "Bluetooth starten…"
    var isScanning = false
    var selectedID: UUID?
    var pinned: Set<UUID> = []
    var recordCount = 0
    var addresses: [UUID: AddressMatch] = [:]

    // Filters
    var search = ""
    var minRSSI = -100.0
    var onlyIdentified = false
    var onlyPinned = false
    var sortOrder: SortOrder = .signal

    // Instellingen
    var intervalMs = 250.0 { didSet { restartTimer(); let v = intervalMs / 1000; engine.queue.async { [engine] in engine.rssiInterval = v } } }
    var allowDuplicates = true { didSet { let v = allowDuplicates; engine.queue.async { [engine] in engine.allowDuplicates = v; engine.applyScanState() } } }
    var filterEnabled = true { didSet { let v = filterEnabled; engine.queue.async { [engine] in engine.filterEnabled = v } } }
    /// 0 = traag/stabiel, 1 = snel/onrustig. Logaritmisch op de Kalman-procesruis.
    var responsiveness = 0.45 { didSet { let q = Self.processNoise(responsiveness); engine.queue.async { [engine] in engine.processNoise = q } } }
    var pathLossExponent = 2.0 { didSet { let v = pathLossExponent; engine.queue.async { [engine] in engine.pathLossExponent = v } } }
    var historyWindow = 30.0 { didSet { let v = historyWindow; engine.queue.async { [engine] in engine.historyWindow = v } } }
    var recording = false { didSet { let v = recording; engine.queue.async { [engine] in engine.recording = v } } }
    var recordOnlySelected = false { didSet { syncRecordFilter() } }

    static func processNoise(_ r: Double) -> Double { pow(10, -1 + r * 3.5) } // 0.1 … ~316 dBm²/s
    var processNoise: Double { Self.processNoise(responsiveness) }

    init() {
        engine.onStateChange = { [weak self] state in
            Task { @MainActor in self?.bluetoothState = Self.describe(state) }
        }
        let q = processNoise
        engine.queue.async { [engine] in engine.processNoise = q }
        restartTimer()
        start()
    }

    func start() {
        isScanning = true
        engine.queue.async { [engine] in engine.wantScanning = true; engine.applyScanState() }
    }

    func stop() {
        isScanning = false
        engine.queue.async { [engine] in engine.wantScanning = false; engine.applyScanState() }
    }

    func clear() {
        engine.queue.async { [engine] in engine.clearDevices() }
        devices = []
        selectedID = nil
    }

    func togglePin(_ id: UUID) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
    }

    func calibrate(_ id: UUID) {
        engine.queue.async { [engine] in engine.startCalibration(id, seconds: 5) }
    }

    func resetCalibration(_ id: UUID) {
        engine.queue.async { [engine] in engine.resetCalibration(id) }
    }

    func select(_ id: UUID?) {
        selectedID = id
        syncRecordFilter()
        refresh()
    }

    private func syncRecordFilter() {
        let only = recordOnlySelected ? selectedID : nil
        engine.queue.async { [engine] in engine.recordOnly = only }
    }

    // MARK: Lijst

    var visibleDevices: [DeviceSnapshot] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = devices.filter { d in
            if onlyPinned && !pinned.contains(d.id) { return false }
            if onlyIdentified && d.name == nil && d.manufacturer == nil { return false }
            if d.filteredRSSI < minRSSI && !pinned.contains(d.id) { return false }
            guard !q.isEmpty else { return true }
            return [d.name, d.manufacturer, d.kind, d.id.uuidString, addresses[d.id]?.address].compactMap { $0?.lowercased() }.contains { $0.contains(q) }
                || d.messages.contains { $0.lowercased().contains(q) }
        }
        return list.sorted { a, b in
            let pa = pinned.contains(a.id), pb = pinned.contains(b.id)
            if pa != pb { return pa }
            switch sortOrder {
            case .signal: return a.filteredRSSI > b.filteredRSSI
            case .name: return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            case .age: return a.age > b.age
            }
        }
    }

    var selected: DeviceSnapshot? { devices.first { $0.id == selectedID } }

    func address(_ id: UUID) -> AddressMatch { addresses[id] ?? .hidden }

    // MARK: Timer

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: intervalMs / 1000, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        let sel = selectedID
        let (snaps, count) = engine.queue.sync { (engine.snapshots(selected: sel), engine.recordCount) }
        devices = snaps
        recordCount = count

        addressBook.reloadIfNeeded()
        var matches: [UUID: AddressMatch] = [:]
        for d in snaps { matches[d.id] = addressBook.match(name: d.name) }
        addresses = matches
        let known = matches.compactMapValues(\.address)
        if known != pushedAddresses {
            pushedAddresses = known
            engine.queue.async { [engine] in engine.addresses = known }
        }
    }

    // MARK: CSV

    func exportCSV() {
        let csv = engine.queue.sync { engine.takeCSV() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        panel.nameFieldStringValue = "ble-metingen_\(f.string(from: Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }

    func clearRecording() {
        engine.queue.async { [engine] in engine.clearRecording() }
        recordCount = 0
    }

    private static func describe(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: "Bluetooth aan"
        case .poweredOff: "Bluetooth staat uit"
        case .unauthorized: "Geen toestemming — zie Systeeminstellingen › Privacy › Bluetooth"
        case .unsupported: "Bluetooth LE niet ondersteund"
        case .resetting: "Bluetooth herstart…"
        default: "Bluetooth-status onbekend"
        }
    }
}
