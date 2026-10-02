import SwiftUI

struct ContentView: View {
    @Environment(Scanner.self) private var scanner

    var body: some View {
        @Bindable var scanner = scanner
        NavigationSplitView {
            VStack(spacing: 0) {
                FilterBar()
                List(selection: Binding(get: { scanner.selectedID }, set: { scanner.select($0) })) {
                    ForEach(scanner.visibleDevices) { d in
                        DeviceRow(device: d, pinned: scanner.pinned.contains(d.id))
                            .tag(d.id)
                    }
                }
                .overlay {
                    if scanner.visibleDevices.isEmpty {
                        ContentUnavailableView(scanner.isScanning ? "Zoeken…" : "Scan gestopt",
                                               systemImage: "dot.radiowaves.left.and.right",
                                               description: Text(scanner.bluetoothState))
                    }
                }
                Divider()
                ControlPanel()
            }
            .navigationSplitViewColumnWidth(min: 340, ideal: 380, max: 460)
        } detail: {
            if let d = scanner.selected {
                DeviceDetail(device: d)
            } else {
                ContentUnavailableView("Kies een apparaat", systemImage: "sensor.tag.radiowaves.forward",
                                       description: Text("\(scanner.devices.count) apparaten in de buurt · \(scanner.bluetoothState)"))
            }
        }
        .searchable(text: $scanner.search, placement: .sidebar, prompt: "Naam, fabrikant, type of UUID")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    scanner.isScanning ? scanner.stop() : scanner.start()
                } label: {
                    Label(scanner.isScanning ? "Stop" : "Scan", systemImage: scanner.isScanning ? "stop.fill" : "play.fill")
                }
                .help(scanner.isScanning ? "Scan stoppen" : "Scan starten")

                Button { scanner.clear() } label: { Label("Wissen", systemImage: "trash") }
                    .help("Apparatenlijst leegmaken")

                Divider()

                Toggle(isOn: $scanner.recording) {
                    Label(scanner.recording ? "Opnemen (\(scanner.recordCount))" : "Opnemen",
                          systemImage: scanner.recording ? "record.circle.fill" : "record.circle")
                }
                .tint(.red)
                .help("Elk ontvangen pakket vastleggen voor CSV-export")

                Menu {
                    Toggle("Alleen geselecteerd apparaat opnemen", isOn: $scanner.recordOnlySelected)
                    Divider()
                    Button("Exporteer CSV (\(scanner.recordCount) regels)…") { scanner.exportCSV() }
                        .disabled(scanner.recordCount == 0)
                    Button("Opname wissen") { scanner.clearRecording() }
                        .disabled(scanner.recordCount == 0)
                } label: {
                    Label("CSV", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("BLE Proximity")
        .navigationSubtitle("\(scanner.devices.count) apparaten · \(scanner.bluetoothState)")
    }
}

struct FilterBar: View {
    @Environment(Scanner.self) private var scanner

    var body: some View {
        @Bindable var scanner = scanner
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Sorteer", selection: $scanner.sortOrder) {
                    ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                Toggle("Herkend", isOn: $scanner.onlyIdentified)
                    .help("Alleen apparaten met naam of fabrikantdata")
                Toggle("Vastgezet", isOn: $scanner.onlyPinned)
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            HStack {
                Text("Min. signaal").font(.caption)
                Slider(value: $scanner.minRSSI, in: -100 ... -30, step: 1)
                Text("\(Int(scanner.minRSSI)) dBm").font(.caption.monospacedDigit()).frame(width: 58, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct DeviceRow: View {
    let device: DeviceSnapshot
    let pinned: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                    Text(device.displayName).font(.body.weight(.medium)).lineLimit(1)
                    if device.isCalibrated { Image(systemName: "scope").font(.caption2).foregroundStyle(.blue).help("Gekalibreerd") }
                }
                Text([device.manufacturer, device.name == nil ? nil : device.kind].compactMap { $0 }.joined(separator: " · ").ifEmpty("Geen fabrikantdata"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                SignalBar(rssi: device.filteredRSSI)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(fmtDistance(device.distance)).font(.body.monospacedDigit().weight(.semibold))
                Text("\(Int(device.filteredRSSI.rounded())) dBm · \(String(format: "%.0f", device.packetsPerSecond))/s")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .opacity(device.isStale ? 0.45 : 1)
    }
}

struct ControlPanel: View {
    @Environment(Scanner.self) private var scanner

    var body: some View {
        @Bindable var scanner = scanner
        VStack(alignment: .leading, spacing: 10) {
            LabeledSlider(title: "Meetinterval",
                          value: Binding(get: { log10(scanner.intervalMs) }, set: { scanner.intervalMs = (pow(10, $0) / 10).rounded() * 10 }),
                          range: log10(50) ... log10(2000),
                          valueText: "\(Int(scanner.intervalMs)) ms · \(String(format: scanner.intervalMs < 1000 ? "%.0f" : "%.1f", 1000 / scanner.intervalMs)) Hz",
                          help: "Hoe vaak de app een meting toont en een grafiekpunt neemt. Elk pakket gaat altijd door het filter.")

            Toggle("Elk pakket ontvangen (duplicaten)", isOn: $scanner.allowDuplicates)
                .help("Uit: macOS meldt een apparaat maar zelden opnieuw — veel minder metingen.")

            HStack {
                Toggle("Kalman-filter", isOn: $scanner.filterEnabled)
                Spacer()
                Text(String(format: "Q = %.1f dBm²/s", scanner.processNoise))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            LabeledSlider(title: "Reactiesnelheid",
                          value: $scanner.responsiveness, range: 0...1,
                          valueText: scanner.responsiveness < 0.33 ? "stabiel" : scanner.responsiveness < 0.66 ? "gemiddeld" : "snel",
                          help: "Links: rustige maar trage waarde. Rechts: volgt beweging snel maar met meer ruis.")
                .disabled(!scanner.filterEnabled)

            LabeledSlider(title: "Padverlies n",
                          value: $scanner.pathLossExponent, range: 1.5...4.0,
                          valueText: String(format: "%.2f", scanner.pathLossExponent),
                          help: "2,0 = vrije ruimte / zichtlijn. 2,5–3,5 = binnen met muren en mensen.")

            LabeledSlider(title: "Grafiekvenster",
                          value: $scanner.historyWindow, range: 10...60,
                          valueText: "\(Int(scanner.historyWindow)) s", help: nil)
        }
        .font(.callout)
        .padding(12)
        .background(.bar)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueText: String
    let help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range).controlSize(.small)
        }
        .help(help ?? "")
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
