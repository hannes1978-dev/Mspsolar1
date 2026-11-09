import SwiftUI

// MARK: - Antwort des Pi-Dienstes

struct PoolStatus: Decodable {
    struct Snap: Decodable { let pv: Double; let grid: Double; let battery: Double; let soc: Double }
    struct Pool: Decodable {
        let water: Double?; let target: Double?
        let heater: Bool; let filter: Bool; let bubbles: Bool; let jets: Bool; let online: Bool
    }
    struct Settings: Decodable {
        let auto: Bool; let soc_start: Double; let soc_stop: Double; let surplus_kw: Double
        let start_hour: Int; let end_hour: Int; let target_temp: Double
    }
    let snap: Snap?
    let pool: Pool?
    let settings: Settings
    let state: String
    let msg: String
    let snap_err: String
    let pool_err: String
}

// MARK: - Verbindung zum Pi

@MainActor
final class PoolVM: ObservableObject {
    @Published var status: PoolStatus?
    @Published var error = ""
    @Published var busy = false

    private var base: String {
        "http://" + (UserDefaults.standard.string(forKey: "piHost") ?? "192.168.8.44:8080")
    }

    private func request(_ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        if let body {
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let text = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NSError(domain: "Pool", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: text ?? "Fehler vom Pi"])
        }
        return data
    }

    func refresh() async {
        do {
            let data = try await request("/api/status")
            status = try JSONDecoder().decode(PoolStatus.self, from: data)
            error = ""
        } catch {
            self.error = "Pi nicht erreichbar"
        }
    }

    func send(_ path: String, _ body: [String: Any]) async {
        busy = true
        do {
            _ = try await request(path, body: body)
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
        await refresh()
    }
}

// MARK: - Oberfläche

struct ContentView: View {
    @StateObject private var vm = PoolVM()
    @AppStorage("piHost") private var piHost = "192.168.8.44:8080"

    @State private var loaded = false
    @State private var auto = true
    @State private var socStart = 60.0
    @State private var socStop = 50.0
    @State private var surplus = 2.2
    @State private var startHour = 9
    @State private var endHour = 17
    @State private var target = 39.5

    var body: some View {
        NavigationStack {
            Form {
                Section("Pool") {
                    if let p = vm.status?.pool {
                        LabeledContent("Wassertemperatur",
                                       value: p.water.map { String(format: "%.1f °C", $0) } ?? "–")
                        LabeledContent("Ziel am Pool",
                                       value: p.target.map { String(format: "%.1f °C", $0) } ?? "–")
                        LabeledContent("Verbindung", value: p.online ? "Online" : "Offline")
                        toggle("Heizung", "heater", p.heater)
                        toggle("Filter", "filter", p.filter)
                        toggle("Blasen", "bubbles", p.bubbles)
                        toggle("Düsen", "jets", p.jets)
                    }
                }
                .disabled(vm.busy)

                Section("Anlage") {
                    if let s = vm.status?.snap {
                        LabeledContent("PV", value: String(format: "%.2f kW", s.pv))
                        LabeledContent("Netz", value: s.grid >= 0
                            ? String(format: "Bezug %.2f kW", s.grid)
                            : String(format: "Einspeisung %.2f kW", -s.grid))
                        LabeledContent("Batterie", value: String(format: "%@ %.2f kW",
                                                                 s.battery >= 0 ? "lädt" : "entlädt", abs(s.battery)))
                        LabeledContent("Akkustand", value: String(format: "%.1f %%", s.soc))
                    }
                }

                Section("Automatik") {
                    if let st = vm.status {
                        Text(st.msg).font(.headline)
                            .foregroundStyle(st.state == "idle" ? Color.primary : Color.orange)
                    }
                    Toggle("Automatik an", isOn: $auto)
                    Stepper("Start: \(startHour):00", value: $startHour, in: 0...23)
                    Stepper("Ende: \(endHour):00", value: $endHour, in: 1...24)
                    Stepper("Akku ab \(Int(socStart)) %", value: $socStart, in: 0...100, step: 5)
                    Stepper("Stopp unter \(Int(socStop)) %", value: $socStop, in: 0...100, step: 5)
                    LabeledContent("Überschuss ab", value: String(format: "%.1f kW", surplus))
                    Slider(value: $surplus, in: 1...8, step: 0.1)
                    LabeledContent("Zieltemperatur", value: String(format: "%.1f °C", target))
                    Slider(value: $target, in: 30...40, step: 0.5)
                    Button("Einstellungen speichern") {
                        Task {
                            await vm.send("/api/settings", [
                                "auto": auto, "soc_start": Int(socStart), "soc_stop": Int(socStop),
                                "surplus_kw": surplus, "start_hour": startHour,
                                "end_hour": endHour, "target_temp": target])
                        }
                    }
                }

                Section("Verbindung") {
                    TextField("Adresse des Pi", text: $piHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if !vm.error.isEmpty {
                        Text(vm.error).foregroundStyle(.red)
                    }
                    if let st = vm.status {
                        if !st.snap_err.isEmpty { Text("Sigenergy: \(st.snap_err)").font(.footnote) }
                        if !st.pool_err.isEmpty { Text("MSpa: \(st.pool_err)").font(.footnote) }
                    }
                }
            }
            .navigationTitle("Pool Solar")
            .refreshable { await vm.refresh() }
            .task {
                while !Task.isCancelled {
                    await vm.refresh()
                    if !loaded, let s = vm.status?.settings {
                        auto = s.auto; socStart = s.soc_start; socStop = s.soc_stop
                        surplus = s.surplus_kw; startHour = s.start_hour
                        endHour = s.end_hour; target = s.target_temp
                        loaded = true
                    }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    private func toggle(_ title: String, _ key: String, _ value: Bool) -> some View {
        Toggle(title, isOn: Binding(
            get: { value },
            set: { on in Task { await vm.send("/api/command", ["what": key, "on": on]) } }))
    }
}
