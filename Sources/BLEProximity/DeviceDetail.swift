import Charts
import SwiftUI

struct DeviceDetail: View {
    @Environment(Scanner.self) private var scanner
    let device: DeviceSnapshot
    @State private var chartMode = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                AddressCard(match: scanner.address(device.id), uuid: device.id)
                tiles
                chart
                HStack(alignment: .top, spacing: 18) {
                    stats
                    calibration
                }
                advertisement
            }
            .padding(20)
        }
    }

    // MARK: Kop

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName).font(.largeTitle.weight(.semibold))
                Text([device.manufacturer, device.kind].compactMap { $0 }.joined(separator: " · ").ifEmpty("Geen fabrikantdata"))
                    .foregroundStyle(.secondary)
                Text(device.id.uuidString).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            Spacer()
            if device.viaConnection {
                Label("Verbonden · RSSI via verbinding", systemImage: "link")
                    .foregroundStyle(.green)
                    .help("Dit apparaat adverteert niet (het is verbonden). De app leest de RSSI van de verbinding; macOS ververst die waarde ongeveer 1× per seconde.")
            }
            if device.isStale {
                Label("\(Int(device.secondsSinceLast)) s geen signaal", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Button {
                scanner.togglePin(device.id)
            } label: {
                Label(scanner.pinned.contains(device.id) ? "Losmaken" : "Vastzetten",
                      systemImage: scanner.pinned.contains(device.id) ? "pin.slash" : "pin")
            }
        }
    }

    // MARK: Kerncijfers

    private var tiles: some View {
        HStack(spacing: 12) {
            Tile(title: "Geschatte afstand", value: fmtDistance(device.distance),
                 sub: "±1σ: \(fmtDistance(device.distanceLow)) – \(fmtDistance(device.distanceHigh))",
                 color: signalColor(device.filteredRSSI))
            Tile(title: scanner.filterEnabled ? "RSSI gefilterd" : "RSSI", value: fmtDBm(device.filteredRSSI),
                 sub: "ref. 1 m: \(fmtDBm(device.reference))")
            Tile(title: "RSSI laatste pakket", value: "\(Int(device.rawRSSI)) dBm",
                 sub: "σ \(String(format: "%.1f", device.stdDev)) dB over 10 s")
            Tile(title: "Pakketten / s", value: String(format: "%.1f", device.packetsPerSecond),
                 sub: device.meanInterval.map { "gem. interval \(Int($0 * 1000)) ms" } ?? "–")
        }
    }

    // MARK: Grafiek

    private var chart: some View {
        GroupBox {
            VStack(alignment: .leading) {
                HStack {
                    Picker("", selection: $chartMode) {
                        Text("RSSI").tag(0)
                        Text("Afstand").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    Spacer()
                    if chartMode == 0 {
                        Label("ruw pakket", systemImage: "circle.fill").foregroundStyle(.gray).font(.caption)
                    }
                    Label(chartMode == 0 ? "gefilterd" : "afstand (gefilterd)", systemImage: "line.diagonal")
                        .foregroundStyle(Color.accentColor).font(.caption)
                }
                Chart {
                    ForEach(device.history) { p in
                        if chartMode == 0 {
                            PointMark(x: .value("t", p.t), y: .value("ruw", p.raw))
                                .symbolSize(10)
                                .foregroundStyle(.gray.opacity(0.55))
                            LineMark(x: .value("t", p.t), y: .value("dBm", p.filtered), series: .value("s", "f"))
                                .foregroundStyle(Color.accentColor)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        } else {
                            LineMark(x: .value("t", p.t), y: .value("m", p.distance))
                                .foregroundStyle(Color.accentColor)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                }
                .chartXScale(domain: -scanner.historyWindow ... 0)
                .chartXAxisLabel("seconden geleden")
                .chartYAxisLabel(chartMode == 0 ? "dBm" : "meter")
                .chartYScale(domain: .automatic(includesZero: chartMode == 1))
                .frame(height: 260)
            }
        }
    }

    // MARK: Statistiek

    private var stats: some View {
        GroupBox("Meetstatistiek (laatste 10 s)") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Pakketten in venster", "\(device.windowCount)")
                row("Totaal ontvangen", "\(device.totalPackets)")
                row("Min / max ruw", "\(Int(device.minRSSI)) / \(Int(device.maxRSSI)) dBm")
                row("Spreiding (σ)", String(format: "%.2f dB", device.stdDev))
                row("Gem. pakketinterval", device.meanInterval.map { String(format: "%.0f ms", $0 * 1000) } ?? "–")
                row("Laatste pakket", String(format: "%.0f ms geleden", device.secondsSinceLast * 1000))
                row("Gezien sinds", "\(Int(device.age)) s")
                row("Padverlies n", String(format: "%.2f", scanner.pathLossExponent))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: Kalibratie

    private var calibration: some View {
        GroupBox("Kalibratie op 1 meter") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Leg het apparaat op precies 1 m van de Mac, met vrije zichtlijn, en start de meting. De app middelt 5 s aan ruwe pakketten.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Referentie:")
                    Text(fmtDBm(device.reference)).monospacedDigit().bold()
                    Text("(\(device.referenceSource))").foregroundStyle(.secondary)
                }
                if let p = device.calibrationProgress {
                    ProgressView(value: p) { Text("Bezig met meten… \(Int(p * 5)) / 5 s") }
                } else {
                    HStack {
                        Button("Kalibreer op 1 m") { scanner.calibrate(device.id) }
                            .buttonStyle(.borderedProminent)
                            .disabled(device.isStale)
                        if device.isCalibrated {
                            Button("Reset") { scanner.resetCalibration(device.id) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: Advertentie

    private var advertisement: some View {
        GroupBox("Advertisement-data") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Naam", device.name ?? "–")
                row("Fabrikant", device.manufacturer.map { name in device.companyID.map { String(format: "%@ (0x%04X)", name, $0) } ?? name } ?? "–")
                row("Berichten", device.messages.isEmpty ? "–" : device.messages.joined(separator: "\n"))
                row("Fabrikantdata", device.manufacturerHex, mono: true)
                row("Services", device.services.isEmpty ? "–" : device.services.joined(separator: "\n"))
                row("Service-data", device.serviceData.isEmpty ? "–" : device.serviceData.joined(separator: "\n"), mono: true)
                row("TX-power", device.txPower.map { "\($0) dBm" } ?? "niet uitgezonden")
                row("Verbindbaar", device.connectable.map { $0 ? "ja" : "nee" } ?? "–")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .callout.monospaced() : .callout.monospacedDigit())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Tile: View {
    let title: String
    let value: String
    let sub: String
    var color: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color ?? .primary)
                .contentTransition(.numericText())
            Text(sub).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AddressCard: View {
    let match: AddressMatch
    let uuid: UUID

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text("Bluetooth-adres (MAC)").font(.caption).foregroundStyle(.secondary)
                content
            }
            Spacer()
            if case .known(let k) = match {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(k.address, forType: .string)
                } label: { Label("Kopieer", systemImage: "doc.on.doc") }
            }
        }
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.25)))
    }

    @ViewBuilder private var content: some View {
        switch match {
        case .known(let k):
            Text(k.address)
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            Text("Gekoppeld met deze Mac als „\(k.name)\"\(k.connected ? " · nu verbonden" : "")")
                .font(.caption).foregroundStyle(.secondary)
        case .ambiguous(let list):
            ForEach(list, id: \.address) { k in
                Text("\(k.address)  \(k.connected ? "· verbonden" : "")")
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            Text("Meerdere gekoppelde apparaten met deze naam — de scan kan niet bepalen welke dit is.")
                .font(.caption).foregroundStyle(.secondary)
        case .hidden:
            Text("Niet vrijgegeven door macOS")
                .font(.title3.weight(.medium))
            Text("macOS toont bij een BLE-scan alleen een per-Mac UUID (\(uuid.uuidString.prefix(8))…). Het echte adres is alleen bekend voor apparaten die met deze Mac gekoppeld of via iCloud gelinkt zijn én hun naam uitzenden.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var icon: String {
        switch match {
        case .known: "checkmark.seal.fill"
        case .ambiguous: "questionmark.diamond"
        case .hidden: "eye.slash"
        }
    }

    private var tint: Color {
        switch match {
        case .known: .blue
        case .ambiguous: .orange
        case .hidden: .gray
        }
    }
}
