import CoreBluetooth
import Foundation

// MARK: - Filter en afstandsmodel

/// 1D Kalman-filter op RSSI. De procesruis schaalt met de tijd tussen pakketten,
/// zodat de reactiesnelheid niet afhangt van hoe vaak een apparaat uitzendt.
struct Kalman1D {
    private(set) var x = 0.0
    private var p = 0.0
    private var initialized = false

    mutating func update(_ z: Double, dt: Double, q: Double, r: Double) -> Double {
        guard initialized else {
            x = z; p = r; initialized = true
            return x
        }
        p += q * max(dt, 0.001)
        let k = p / (p + r)
        x += k * (z - x)
        p *= 1 - k
        return x
    }
}

/// Log-distance path loss: d = 10 ^ ((RSSI@1m − RSSI) / (10·n))
func estimateDistance(rssi: Double, ref: Double, n: Double) -> Double {
    pow(10, (ref - rssi) / (10 * n))
}

struct Sample {
    let t: TimeInterval
    let raw: Double
    let filtered: Double
}

struct ChartPoint: Identifiable {
    let id: Int
    let t: Double
    let raw: Double
    let filtered: Double
    let distance: Double
}

struct DeviceSnapshot: Identifiable {
    let id: UUID
    let name: String?
    let companyID: UInt16?
    let manufacturer: String?
    let kind: String?
    let messages: [String]
    let manufacturerHex: String
    let services: [String]
    let serviceData: [String]
    let txPower: Int?
    let connectable: Bool?

    let rawRSSI: Double
    let filteredRSSI: Double
    let distance: Double
    let distanceLow: Double
    let distanceHigh: Double
    let reference: Double
    let referenceSource: String
    let isCalibrated: Bool
    let calibrationProgress: Double?

    let packetsPerSecond: Double
    let meanInterval: Double?
    let stdDev: Double
    let minRSSI: Double
    let maxRSSI: Double
    let windowCount: Int
    let totalPackets: Int
    let secondsSinceLast: Double
    let age: Double

    let history: [ChartPoint]

    var displayName: String { name ?? kind ?? manufacturer ?? "Onbekend apparaat" }
    var isStale: Bool { secondsSinceLast > 5 }
}

// MARK: - Apparaat

final class TrackedDevice {
    let id: UUID
    var name: String?
    var manufacturerData: Data?
    var services: Set<CBUUID> = []
    var serviceData: [CBUUID: Data] = [:]
    var txPower: Int?
    var connectable: Bool?
    let firstSeen: TimeInterval
    var lastSeen: TimeInterval
    var totalPackets = 0
    var kalman = Kalman1D()
    var samples: [Sample] = []

    var calibrationEnd: TimeInterval?
    var calibrationStart: TimeInterval = 0
    var calibrationSamples: [Double] = []

    init(id: UUID, now: TimeInterval) {
        self.id = id
        firstSeen = now
        lastSeen = now
    }

    func absorb(_ adv: [String: Any], peripheralName: String?) {
        if let n = adv[CBAdvertisementDataLocalNameKey] as? String, !n.isEmpty { name = n }
        else if let n = peripheralName, !n.isEmpty { name = n }
        if let d = adv[CBAdvertisementDataManufacturerDataKey] as? Data { manufacturerData = d }
        if let s = adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] { services.formUnion(s) }
        if let s = adv[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] { services.formUnion(s) }
        if let sd = adv[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] { serviceData.merge(sd) { $1 } }
        if let tx = adv[CBAdvertisementDataTxPowerLevelKey] as? NSNumber { txPower = tx.intValue }
        if let c = adv[CBAdvertisementDataIsConnectable] as? NSNumber { connectable = c.boolValue }
    }

    /// Referentie-RSSI op 1 m: kalibratie > iBeacon > standaard. TX-power is te onbetrouwbaar
    /// (Apple meldt bv. +12 dBm) en wordt alleen als informatie getoond.
    func reference(calibrated: Double?) -> (Double, String) {
        if let calibrated { return (calibrated, "gekalibreerd") }
        if let p = BLEInfo.iBeaconMeasuredPower(manufacturerData) { return (p, "iBeacon 1 m-waarde") }
        return (-59, "standaard (−59 dBm)")
    }
}

// MARK: - Engine (draait volledig op de eigen BLE-queue)

final class ScanEngine: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "nl.gerben.bleproximity.scan", qos: .userInteractive)
    private var central: CBCentralManager!
    private var devices: [UUID: TrackedDevice] = [:]

    // Instellingen — alleen op `queue` lezen/schrijven.
    var wantScanning = false
    var allowDuplicates = true
    var filterEnabled = true
    var processNoise = 4.0        // dBm²/s
    var measurementNoise = 16.0   // dBm² (σ ≈ 4 dB)
    var pathLossExponent = 2.0
    var statsWindow = 10.0
    var historyWindow = 30.0
    var calibrations: [UUID: Double]

    var recording = false
    var recordOnly: UUID?
    private var recordRows: [String] = []
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var onStateChange: ((CBManagerState) -> Void)?

    private static let calibrationKey = "calibrations"

    override init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.calibrationKey) as? [String: Double] ?? [:]
        calibrations = Dictionary(uniqueKeysWithValues: stored.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: Scannen

    func applyScanState() {
        guard central.state == .poweredOn else { return }
        central.stopScan()
        if wantScanning {
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates])
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onStateChange?(central.state)
        applyScanState()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.doubleValue
        guard rssi < 0, rssi > -127 else { return } // 127 = niet beschikbaar
        let now = ProcessInfo.processInfo.systemUptime
        let id = peripheral.identifier

        let dev = devices[id] ?? TrackedDevice(id: id, now: now)
        devices[id] = dev
        dev.absorb(advertisementData, peripheralName: peripheral.name)

        let dt = dev.totalPackets == 0 ? 0 : now - dev.lastSeen
        let kalmanValue = dev.kalman.update(rssi, dt: dt, q: processNoise, r: measurementNoise)
        let filtered = filterEnabled ? kalmanValue : rssi
        dev.lastSeen = now
        dev.totalPackets += 1
        dev.samples.append(Sample(t: now, raw: rssi, filtered: filtered))
        let cutoff = now - max(historyWindow, statsWindow, 60)
        if let first = dev.samples.firstIndex(where: { $0.t >= cutoff }), first > 0 {
            dev.samples.removeFirst(first)
        }

        if dev.calibrationEnd != nil { dev.calibrationSamples.append(rssi) }
        finishCalibrationIfDue(dev, now: now)

        if recording, recordOnly == nil || recordOnly == id {
            let (ref, _) = dev.reference(calibrated: calibrations[id])
            let dist = estimateDistance(rssi: filtered, ref: ref, n: pathLossExponent)
            let name = (dev.name ?? "").replacingOccurrences(of: ",", with: " ")
            let mfg = BLEInfo.companyID(dev.manufacturerData).map { BLEInfo.companyName($0) } ?? ""
            recordRows.append("\(iso.string(from: Date())),\(String(format: "%.4f", now)),\(id.uuidString),\(name),\(mfg),\(Int(rssi)),\(String(format: "%.2f", filtered)),\(String(format: "%.3f", dist))")
        }
    }

    // MARK: Kalibratie

    func startCalibration(_ id: UUID, seconds: Double) {
        guard let dev = devices[id] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        dev.calibrationStart = now
        dev.calibrationEnd = now + seconds
        dev.calibrationSamples = []
    }

    func resetCalibration(_ id: UUID) {
        calibrations[id] = nil
        persistCalibrations()
    }

    private func finishCalibrationIfDue(_ dev: TrackedDevice, now: TimeInterval) {
        guard let end = dev.calibrationEnd, now >= end else { return }
        dev.calibrationEnd = nil
        let s = dev.calibrationSamples.sorted()
        guard s.count >= 3 else { return }
        // Getrimd gemiddelde (middelste 80 %) — robuust tegen uitschieters door reflecties.
        let trim = s.count / 10
        let core = s[trim..<(s.count - trim)]
        calibrations[dev.id] = core.reduce(0, +) / Double(core.count)
        persistCalibrations()
    }

    private func persistCalibrations() {
        let dict = Dictionary(uniqueKeysWithValues: calibrations.map { ($0.key.uuidString, $0.value) })
        UserDefaults.standard.set(dict, forKey: Self.calibrationKey)
    }

    // MARK: Opname

    func takeCSV() -> String {
        let header = "timestamp,uptime_s,uuid,name,manufacturer,rssi_raw_dbm,rssi_filtered_dbm,distance_m"
        return ([header] + recordRows).joined(separator: "\n") + "\n"
    }

    var recordCount: Int { recordRows.count }
    func clearRecording() { recordRows.removeAll() }

    func clearDevices() { devices.removeAll() }

    // MARK: Snapshot voor de UI

    func snapshots(selected: UUID?) -> [DeviceSnapshot] {
        let now = ProcessInfo.processInfo.systemUptime
        devices = devices.filter { now - $0.value.lastSeen < 120 }

        return devices.values.compactMap { dev in
            finishCalibrationIfDue(dev, now: now)
            guard let last = dev.samples.last else { return nil }

            let (ref, refSource) = dev.reference(calibrated: calibrations[dev.id])
            let n = pathLossExponent
            let window = dev.samples.filter { $0.t >= now - statsWindow }
            let raws = window.map(\.raw)
            let mean = raws.isEmpty ? last.raw : raws.reduce(0, +) / Double(raws.count)
            let variance = raws.count > 1 ? raws.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(raws.count - 1) : 0
            let sd = variance.squareRoot()
            let span = min(statsWindow, max(now - dev.firstSeen, 0.001))
            let meanInterval = window.count > 1 ? (window.last!.t - window.first!.t) / Double(window.count - 1) : nil

            var history: [ChartPoint] = []
            if dev.id == selected {
                let hs = dev.samples.filter { $0.t >= now - historyWindow }
                history = hs.enumerated().map { i, s in
                    ChartPoint(id: i, t: s.t - now, raw: s.raw, filtered: s.filtered,
                               distance: estimateDistance(rssi: s.filtered, ref: ref, n: n))
                }
            }

            var calProgress: Double?
            if let end = dev.calibrationEnd {
                calProgress = min(1, (now - dev.calibrationStart) / (end - dev.calibrationStart))
            }

            let cid = BLEInfo.companyID(dev.manufacturerData)
            return DeviceSnapshot(
                id: dev.id,
                name: dev.name,
                companyID: cid,
                manufacturer: cid.map { BLEInfo.companyName($0) },
                kind: BLEInfo.shortKind(dev.manufacturerData),
                messages: BLEInfo.describeManufacturer(dev.manufacturerData),
                manufacturerHex: BLEInfo.hex(dev.manufacturerData),
                services: dev.services.map { BLEInfo.serviceName($0) }.sorted(),
                serviceData: dev.serviceData.map { "\(BLEInfo.serviceName($0.key)): \(BLEInfo.hex($0.value))" }.sorted(),
                txPower: dev.txPower,
                connectable: dev.connectable,
                rawRSSI: last.raw,
                filteredRSSI: last.filtered,
                distance: estimateDistance(rssi: last.filtered, ref: ref, n: n),
                distanceLow: estimateDistance(rssi: last.filtered + sd, ref: ref, n: n),
                distanceHigh: estimateDistance(rssi: last.filtered - sd, ref: ref, n: n),
                reference: ref,
                referenceSource: refSource,
                isCalibrated: calibrations[dev.id] != nil,
                calibrationProgress: calProgress,
                packetsPerSecond: Double(window.count) / span,
                meanInterval: meanInterval,
                stdDev: sd,
                minRSSI: raws.min() ?? last.raw,
                maxRSSI: raws.max() ?? last.raw,
                windowCount: window.count,
                totalPackets: dev.totalPackets,
                secondsSinceLast: now - dev.lastSeen,
                age: now - dev.firstSeen,
                history: history
            )
        }
    }
}
