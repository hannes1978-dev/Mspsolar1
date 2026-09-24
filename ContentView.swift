import SwiftUI

@MainActor
final class EnergyVM: ObservableObject {
    @Published var snapshot: SigenSnapshot?
    @Published var status = "Noch nicht getestet"
    @Published var connected = false
    @Published var autoHeat = true
    @Published var threshold = 2.5
    @Published var minimumSOC = 80.0
    @Published var targetTemperature = 39.5
    @Published var startHour = 9
    @Published var endHour = 17
    @Published var heater = false
    @Published var bubbles = false
    @Published var jets = false
    private let client = SigenModbusClient()

    var solarPermit: Bool {
        guard let s = snapshot else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        // Export at grid connection is the safest definition of currently unused solar power.
        return hour >= startHour && hour < endHour && s.exportKW >= threshold && s.batterySOC >= minimumSOC
    }

    func test() async {
        status = "Verbinde mit 192.168.1.127:502 …"
        do {
            let s = try await client.readSnapshot()
            snapshot = s; connected = true
            status = "SigenStor verbunden"
        } catch {
            connected = false; status = "Keine Verbindung: \(error.localizedDescription)"
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = EnergyVM()
    var body: some View {
        NavigationStack {
            Form {
                Section("SigenStor") {
                    LabeledContent("Adresse", value: "192.168.1.127:502")
                    LabeledContent("Status", value: vm.status)
                    if let s = vm.snapshot {
                        LabeledContent("PV", value: String(format: "%.2f kW", s.pvKW))
                        LabeledContent("Netz", value: s.gridKW >= 0 ? String(format:"Bezug %.2f kW",s.importKW) : String(format:"Einspeisung %.2f kW",s.exportKW))
                        LabeledContent("Batterie", value: String(format:"%.1f %%",s.batterySOC))
                        LabeledContent("Batterieleistung", value: String(format:"%.2f kW",s.batteryKW))
                    }
                    Button("Modbus-Verbindung testen") { Task { await vm.test() } }
                }
                Section("Whirlpool") {
                    Toggle("Heizung", isOn: $vm.heater)
                    Toggle("Blasen", isOn: $vm.bubbles)
                    Toggle("Düsen / Jets", isOn: $vm.jets)
                    HStack { Text("Zieltemperatur"); Spacer(); Text(String(format:"%.1f °C",vm.targetTemperature)) }
                    Slider(value: $vm.targetTemperature, in: 30...40, step: 0.5)
                    Text("MSpa-Schalter sind in dieser Testversion noch lokal. Cloud-Anmeldung wird als nächstes angebunden.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("PV-Heizautomatik") {
                    Toggle("Automatik", isOn: $vm.autoHeat)
                    Stepper("Start: \(vm.startHour):00", value: $vm.startHour, in: 0...23)
                    Stepper("Ende: \(vm.endHour):00", value: $vm.endHour, in: 1...24)
                    HStack { Text("Überschuss mindestens"); Spacer(); Text(String(format:"%.1f kW",vm.threshold)) }
                    Slider(value: $vm.threshold, in: 2.2...8, step: 0.1)
                    HStack { Text("Batterie mindestens"); Spacer(); Text("\(Int(vm.minimumSOC)) %") }
                    Slider(value: $vm.minimumSOC, in: 0...100, step: 5)
                    LabeledContent("Heizfreigabe", value: vm.solarPermit ? "JA" : "NEIN")
                }
            }
            .navigationTitle("MSpa Solar")
            .task { await vm.test() }
        }
    }
}
