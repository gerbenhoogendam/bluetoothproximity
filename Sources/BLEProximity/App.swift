import SwiftUI

@main
struct BLEProximityApp: App {
    @State private var scanner = Scanner()

    var body: some Scene {
        WindowGroup("BLE Proximity") {
            ContentView()
                .environment(scanner)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .defaultSize(width: 1240, height: 820)
    }
}

// MARK: - Opmaak-hulpjes

func fmtDistance(_ m: Double) -> String {
    if m < 1 { return String(format: "%.0f cm", m * 100) }
    if m < 10 { return String(format: "%.2f m", m) }
    return String(format: "%.1f m", m)
}

func fmtDBm(_ v: Double) -> String { String(format: "%.1f dBm", v) }

func signalColor(_ rssi: Double) -> Color {
    if rssi >= -60 { return .green }
    if rssi >= -75 { return .yellow }
    if rssi >= -88 { return .orange }
    return .red
}

struct SignalBar: View {
    let rssi: Double
    var body: some View {
        let level = min(max((rssi + 100) / 60, 0), 1)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(signalColor(rssi)).frame(width: g.size.width * level)
            }
        }
        .frame(height: 5)
    }
}
