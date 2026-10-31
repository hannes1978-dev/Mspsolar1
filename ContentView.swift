import SwiftUI

@MainActor
final class EnergyVM: ObservableObject {
    private var automationTask: Task<Void, Never>?
    @Published var snapshot: SigenSnapshot?
    @Published var status = "Noch nicht getestet"
    @Published var connected = false

    @AppStorage("autoHeat") var autoHeat = true
    @AppStorage("threshold") var threshold = 2.5
    @AppStorage("minimumSOC") var minimumSOC = 80.0
    @AppStorage("targetTemperature") var targetTemperature = 39.5
    @AppStorage("startHour") var startHour = 9
    @AppStorage("endHour") var endHour = 17

    @Published var mspaEmail = ""
    @Published var mspaPassword = ""
    @Published var mspaStatus = "Nicht angemeldet"
    @Published var mspaConnected = false
    @Published var mspaDeviceName = ""
    @Published var mspaModel = ""
    @Published var waterTemperature: Double?
    @Published var mspaTargetTemperature: Double?
    @Published var mspaHeater = false
    @Published var mspaFilter = false
    @Published var mspaBubbles = false
    @Published var mspaJets = false
    @Published var mspaUVC = false
    @Published var mspaOnline = false
    @Published var commandRunning = false

    private let sigenClient = SigenModbusClient()
    private let mspaClient = MSpaClient()
    private var mspaDevice: MSpaDevice?
    private var solarAvailableSince: Date?
    private var solarMissingSince: Date?
    private var automaticHeatingStartedAt: Date?
    private var automaticHeatingStoppedAt: Date?
    private let solarStartDelay: TimeInterval = 180
    private let solarStopDelay: TimeInterval = 300
    private let minimumHeatingTime: TimeInterval = 600
    private let restartDelay: TimeInterval = 300

    func loadSavedMSpaCredentials() {
        if let email = KeychainHelper.load(account: "mspaEmail") {
            mspaEmail = email
        }
        if let password = KeychainHelper.load(account: "mspaPassword") {
            mspaPassword = password
        }
    }

    var solarPermit: Bool {
        guard let s = snapshot else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        let estimatedHouseKW = max(0, s.pvKW - s.batteryKW - s.exportKW + s.importKW)
        return autoHeat && hour >= startHour && hour < endHour &&
            s.batterySOC >= minimumSOC &&
            s.pvKW >= estimatedHouseKW + threshold
    }

    func updateSolarAutomationState() {
        let now = Date()
        if solarPermit {
            solarMissingSince = nil
            if solarAvailableSince == nil { solarAvailableSince = now }
        } else {
            solarAvailableSince = nil
            if solarMissingSince == nil { solarMissingSince = now }
        }
    }

    var solarStartReady: Bool {
        guard solarPermit, let since = solarAvailableSince else { return false }
        return Date().timeIntervalSince(since) >= solarStartDelay
    }

    var solarStopReady: Bool {
        guard let s = snapshot else { return false }
        let hour = Calendar.current.component(.hour, from: Date())

        // Diese Grenzen haben Vorrang vor der Mindestlaufzeit.
        if !autoHeat || hour < startHour || hour >= endHour ||
            s.batterySOC < minimumSOC {
            return true
        }

        if let started = automaticHeatingStartedAt,
           Date().timeIntervalSince(started) < minimumHeatingTime {
            return false
        }

        // Sowohl Netzbezug als auch Akkuentladung vermeiden.
        let unwantedSupply = s.importKW >= 0.4 || s.batteryKW <= -0.4
        guard unwantedSupply, let missingSince = solarMissingSince else { return false }
        return Date().timeIntervalSince(missingSince) >= solarStopDelay
    }

    func runSolarHeatingAutomation() async {
        updateSolarAutomationState()
        guard mspaConnected, mspaOnline, !commandRunning,
              let device = mspaDevice else { return }

        let targetReached = waterTemperature.map { $0 >= targetTemperature } ?? false
        if mspaHeater, automaticHeatingStartedAt != nil,
           (targetReached || solarStopReady) {
            commandRunning = true
            mspaStatus = targetReached
                ? "Zieltemperatur erreicht â Heizung stoppt"
                : "PV-Leistung zu niedrig â Heizung stoppt"
            do {
                try await mspaClient.setHeater(false, for: device)
                automaticHeatingStartedAt = nil
                automaticHeatingStoppedAt = Date()
                solarMissingSince = nil
                try await Task.sleep(for: .seconds(1))
                try await refreshMSpa()
                mspaStatus = "Heizung automatisch gestoppt"
            } catch {
                mspaStatus = "Automatik-Fehler: \(error.localizedDescription)"
            }
            commandRunning = false
            return
        }

        if let stoppedAt = automaticHeatingStoppedAt,
           Date().timeIntervalSince(stoppedAt) < restartDelay { return }
        guard solarStartReady, !mspaHeater,
              let waterTemperature, waterTemperature < targetTemperature else { return }

        commandRunning = true
        mspaStatus = "PV-Ãberschuss stabil â Heizung startet"
        do {
            try await mspaClient.setHeater(true, for: device)
            automaticHeatingStartedAt = Date()
            solarAvailableSince = nil
            try await Task.sleep(for: .seconds(1))
            try await refreshMSpa()
            mspaStatus = "Heizung automatisch mit PV gestartet"
        } catch {
            mspaStatus = "Automatik-Fehler: \(error.localizedDescription)"
        }
        commandRunning = false
    }

    func startAutomationLoop() {
        guard automationTask == nil else { return }
        automationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runAutomationCycle()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func runAutomationCycle() async {
        guard !commandRunning else { return }
        do {
            let s = try await sigenClient.readSnapshot()
            guard s.pvKW >= 0, s.pvKW <= 25,
                  s.batterySOC >= 0, s.batterySOC <= 100,
                  abs(s.gridKW) <= 30, abs(s.batteryKW) <= 30 else {
                snapshot = nil
                connected = false
                status = "SigenStor: unplausible Messwerte"
                return
            }
            snapshot = s
            connected = true
            status = "SigenStor verbunden"
            updateSolarAutomationState()
        } catch {
            connected = false
            snapshot = nil
            status = "SigenStor: \(error.localizedDescription)"
            return
        }

        guard mspaConnected else { return }
        do {
            try await refreshMSpa()
            await runSolarHeatingAutomation()
        } catch {
            mspaStatus = "MSpa: \(error.localizedDescription)"
        }
    }

    func testSigen() async {
        status = "Verbinde mit 192.168.1.127:502 â¦"
        do {
            let s = try await sigenClient.readSnapshot()
            snapshot = s
            connected = true
            status = "SigenStor verbunden"
            updateSolarAutomationState()
        } catch {
            connected = false
            snapshot = nil
            status = "Keine Verbindung: \(error.localizedDescription)"
        }
    }

    func connectMSpa() async {
        let email = mspaEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !mspaPassword.isEmpty else {
            mspaStatus = "E-Mail und Passwort eingeben"
            return
        }
        mspaStatus = "Anmeldung lÃ¤uft â¦"
        mspaConnected = false
        do {
            try await mspaClient.login(email: email, password: mspaPassword)
            mspaStatus = "Suche Whirlpool â¦"
            let devices = try await mspaClient.getDevices()
            guard let device = devices.first else {
                mspaStatus = "Kein Whirlpool gefunden"
                return
            }
            mspaDevice = device
            mspaDeviceName = device.name
            mspaModel = device.model
            try await refreshMSpa()
            KeychainHelper.save(email, account: "mspaEmail")
            KeychainHelper.save(mspaPassword, account: "mspaPassword")
            mspaConnected = true
            mspaStatus = "MSpa verbunden"
        } catch {
            mspaConnected = false
            mspaStatus = error.localizedDescription
        }
    }

    func refreshMSpa() async throws {
        guard let device = mspaDevice else { throw MSpaError.noDevices }
        let s = try await mspaClient.getStatus(for: device)
        waterTemperature = s.waterTemperature
        mspaTargetTemperature = s.targetTemperature
        mspaHeater = s.heaterOn
        mspaFilter = s.filterOn
        mspaBubbles = s.bubblesOn
        mspaJets = s.jetsOn
        mspaUVC = s.uvcOn
        mspaOnline = s.online
    }

    func refreshMSpaButton() async {
        do {
            try await refreshMSpa()
            mspaStatus = "Status aktualisiert"
        } catch {
            mspaStatus = error.localizedDescription
        }
    }

    private func runCommand(_ text: String, operation: () async throws -> Void) async {
        guard !commandRunning else { return }
        commandRunning = true
        mspaStatus = text
        do {
            try await operation()
            try await Task.sleep(for: .seconds(1))
            try await refreshMSpa()
            mspaStatus = "Befehl bestÃ¤tigt"
        } catch {
            mspaStatus = error.localizedDescription
            try? await refreshMSpa()
        }
        commandRunning = false
    }

    func setHeater(_ on: Bool) async {
        guard let device = mspaDevice else { return }
        await runCommand(on ? "Heizung wird eingeschaltet â¦" : "Heizung wird ausgeschaltet â¦") {
            try await mspaClient.setHeater(on, for: device)
        }
    }

    func setFilter(_ on: Bool) async {
        guard let device = mspaDevice else { return }
        await runCommand(on ? "Filter wird eingeschaltet â¦" : "Filter wird ausgeschaltet â¦") {
            try await mspaClient.setFilter(on, for: device)
        }
    }

    func setBubbles(_ on: Bool) async {
        guard let device = mspaDevice else { return }
        await runCommand(on ? "Blasen werden eingeschaltet â¦" : "Blasen werden ausgeschaltet â¦") {
            try await mspaClient.setBubbles(on, for: device)
        }
    }

    func setJets(_ on: Bool) async {
        guard let device = mspaDevice else { return }
        await runCommand(on ? "Jets werden eingeschaltet â¦" : "Jets werden ausgeschaltet â¦") {
            try await mspaClient.setJets(on, for: device)
        }
    }

    func setUVC(_ on: Bool) async {
        guard let device = mspaDevice else { return }
        await runCommand(on ? "UVC wird eingeschaltet â¦" : "UVC wird ausgeschaltet â¦") {
            try await mspaClient.setUVC(on, for: device)
        }
    }

    func sendTargetTemperature() async {
        guard let device = mspaDevice else { return }
        await runCommand("Zieltemperatur wird eingestellt â¦") {
            try await mspaClient.setTemperature(targetTemperature, for: device)
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = EnergyVM()

    var body: some View {
        NavigationStack {
            Form {
                Section("MSpa Oslo") {
                    if !vm.mspaConnected {
                        TextField("MSpa E-Mail", text: $vm.mspaEmail)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                        SecureField("MSpa Passwort", text: $vm.mspaPassword)
                        Button("Bei MSpa anmelden") {
                            Task { await vm.connectMSpa() }
                        }
                    }
                    LabeledContent("Status", value: vm.mspaStatus)
                    if vm.mspaConnected {
                        LabeledContent("Whirlpool", value: vm.mspaDeviceName)
                        LabeledContent("Modell", value: vm.mspaModel)
                        LabeledContent("Cloud", value: vm.mspaOnline ? "Online" : "Offline")
                        if let temperature = vm.waterTemperature {
                            LabeledContent("Wassertemperatur", value: String(format: "%.1f Â°C", temperature))
                        }
                        if let target = vm.mspaTargetTemperature {
                            LabeledContent("Aktuelles Ziel", value: String(format: "%.1f Â°C", target))
                        }
                        Toggle("Heizung", isOn: Binding(
                            get: { vm.mspaHeater },
                            set: { value in Task { await vm.setHeater(value) } }
                        ))
                        Toggle("Filter", isOn: Binding(
                            get: { vm.mspaFilter },
                            set: { value in Task { await vm.setFilter(value) } }
                        ))
                        Toggle("Blasen", isOn: Binding(
                            get: { vm.mspaBubbles },
                            set: { value in Task { await vm.setBubbles(value) } }
                        ))
                        Toggle("DÃ¼sen / Jets", isOn: Binding(
                            get: { vm.mspaJets },
                            set: { value in Task { await vm.setJets(value) } }
                        ))
                        Toggle("UVC", isOn: Binding(
                            get: { vm.mspaUVC },
                            set: { value in Task { await vm.setUVC(value) } }
                        ))
                        .disabled(vm.commandRunning || !vm.mspaOnline)
                        HStack {
                            Text("Zieltemperatur")
                            Spacer()
                            Text(String(format: "%.1f Â°C", vm.targetTemperature))
                        }
                        Slider(value: $vm.targetTemperature, in: 30...40, step: 0.5)
                            .disabled(vm.commandRunning)
                        Button("Zieltemperatur Ã¼bertragen") {
                            Task { await vm.sendTargetTemperature() }
                        }
                        .disabled(vm.commandRunning || !vm.mspaOnline)
                        Button("Status aktualisieren") {
                            Task { await vm.refreshMSpaButton() }
                        }
                        .disabled(vm.commandRunning)
                    }
                }

                Section("SigenStor") {
                    LabeledContent("Adresse", value: "192.168.1.127:502")
                    LabeledContent("Status", value: vm.status)
                    if let s = vm.snapshot {
                        LabeledContent("PV", value: String(format: "%.2f kW", s.pvKW))
                        LabeledContent("Netz", value: s.gridKW >= 0
                            ? String(format: "Bezug %.2f kW", s.importKW)
                            : String(format: "Einspeisung %.2f kW", s.exportKW))
                        LabeledContent("Batterie", value: String(format: "%.1f %%", s.batterySOC))
                        LabeledContent("Batterieleistung", value: String(format: "%.2f kW", s.batteryKW))
                    }
                    Button("Modbus-Verbindung testen") {
                        Task { await vm.testSigen() }
                    }
                }

                Section("PV-Heizautomatik") {
                    Toggle("Automatik", isOn: $vm.autoHeat)
                    Stepper("Start: \(vm.startHour):00", value: $vm.startHour, in: 0...23)
                    Stepper("Ende: \(vm.endHour):00", value: $vm.endHour, in: 1...24)
                    HStack {
                        Text("Ãberschuss mindestens")
                        Spacer()
                        Text(String(format: "%.1f kW", vm.threshold))
                    }
                    Slider(value: $vm.threshold, in: 2.2...8, step: 0.1)
                    HStack {
                        Text("Batterie mindestens")
                        Spacer()
                        Text("\(Int(vm.minimumSOC)) %")
                    }
                    Slider(value: $vm.minimumSOC, in: 0...100, step: 5)
                    LabeledContent("PV-Status", value: vm.mspaHeater
                        ? "Heizung aktiv"
                        : (vm.solarPermit ? "PV-Heizen mÃ¶glich" : "Warte auf PV"))
                    Text("Die PV-Automatik steuert die Heizung automatisch, solange die App aktiv ist. Kurze PV-Schwankungen werden durch Ein- und AusschaltverzÃ¶gerungen abgefangen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("MSpa Solar")
            .task {
                vm.loadSavedMSpaCredentials()
                await vm.testSigen()
                if !vm.mspaEmail.isEmpty && !vm.mspaPassword.isEmpty {
                    await vm.connectMSpa()
                }
                vm.startAutomationLoop()
            }
        }
    }
}
