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

    // MSpa Anmeldung und Status
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

private let solarStartDelay: TimeInterval = 180
private let solarStopDelay: TimeInterval = 300
private let minimumHeatingTime: TimeInterval = 600
   var solarPermit: Bool {
    guard let s = snapshot else { return false }

    let hour = Calendar.current.component(.hour, from: Date())

    // Tatsächlicher Verbrauch, den die PV momentan versorgt.
    // Positive Batterieleistung bedeutet: Batterie wird geladen.
    let estimatedHouseKW = max(
        0,
        s.pvKW - s.batteryKW - s.exportKW + s.importKW
    )

    // Für den Whirlpool müssen zusätzlich etwa 2,2 kW
    // Heizleistung aus der aktuellen PV-Erzeugung verfügbar sein.
    let requiredPVKW = estimatedHouseKW + threshold

    return autoHeat &&
           hour >= startHour &&
           hour < endHour &&
           s.batterySOC >= minimumSOC &&
           s.pvKW >= requiredPVKW
}
func updateSolarAutomationState() {
    let now = Date()

    if solarPermit {
        solarMissingSince = nil

        if solarAvailableSince == nil {
            solarAvailableSince = now
        }
    } else {
        solarAvailableSince = nil

        if solarMissingSince == nil {
            solarMissingSince = now
        }
    }
}
func runSolarHeatingAutomation() async {
    updateSolarAutomationState()

    guard solarStartReady else {
        return
    }

    guard mspaConnected,
          mspaOnline,
          !mspaHeater,
          !commandRunning,
          let device = mspaDevice
    else {
        return
    }

    commandRunning = true
    mspaStatus = "PV-Überschuss stabil – Heizung startet"

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

var solarStartReady: Bool {
    guard
        solarPermit,
        let since = solarAvailableSince
    else {
        return false
    }

    return Date().timeIntervalSince(since) >= solarStartDelay
}

var solarStopReady: Bool {
    guard
        !solarPermit,
        let missingSince = solarMissingSince
    else {
        return false
    }

    if let started = automaticHeatingStartedAt {
        let runningTime = Date().timeIntervalSince(started)

        if runningTime < minimumHeatingTime {
            return false
        }
    }

    return Date().timeIntervalSince(missingSince) >= solarStopDelay
}


    func testSigen() async {
        status = "Verbinde mit 192.168.1.127:502 …"

        do {
            let s = try await sigenClient.readSnapshot()
            snapshot = s
            connected = true
            status = "SigenStor verbunden"
            updateSolarAutomationState()
        } catch {
            connected = false
            status = "Keine Verbindung: \(error.localizedDescription)"
        }
    }

    func connectMSpa() async {
        let email = mspaEmail.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !email.isEmpty, !mspaPassword.isEmpty else {
            mspaStatus = "E-Mail und Passwort eingeben"
            return
        }

        mspaStatus = "Anmeldung läuft …"
        mspaConnected = false

        do {
            try await mspaClient.login(
                email: email,
                password: mspaPassword
            )

            mspaStatus = "Suche Whirlpool …"

            let devices = try await mspaClient.getDevices()

            guard let device = devices.first else {
                mspaStatus = "Kein Whirlpool gefunden"
                return
            }

            mspaDevice = device
            mspaDeviceName = device.name
            mspaModel = device.model

            try await refreshMSpa()

            mspaConnected = true
            mspaStatus = "MSpa verbunden"
        } catch {
            mspaConnected = false
            mspaStatus = error.localizedDescription
        }
    }

    func refreshMSpa() async throws {
        guard let device = mspaDevice else {
            throw MSpaError.noDevices
        }

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

    private func runCommand(
        _ text: String,
        operation: () async throws -> Void
    ) async {
        guard !commandRunning else { return }

        commandRunning = true
        mspaStatus = text

        do {
            try await operation()

            // Dem Whirlpool kurz Zeit geben,
            // den neuen Zustand zu melden.
            try await Task.sleep(for: .seconds(1))

            try await refreshMSpa()
            mspaStatus = "Befehl bestätigt"
        } catch {
            mspaStatus = error.localizedDescription

            // Nach einem Fehler trotzdem versuchen,
            // den tatsächlichen Zustand neu einzulesen.
            try? await refreshMSpa()
        }

        commandRunning = false
    }

    func setHeater(_ on: Bool) async {
        guard let device = mspaDevice else { return }

        await runCommand(
            on ? "Heizung wird eingeschaltet …"
               : "Heizung wird ausgeschaltet …"
        ) {
            try await mspaClient.setHeater(
                on,
                for: device
            )
        }
    }

    func setFilter(_ on: Bool) async {
        guard let device = mspaDevice else { return }

        await runCommand(
            on ? "Filter wird eingeschaltet …"
               : "Filter wird ausgeschaltet …"
        ) {
            try await mspaClient.setFilter(
                on,
                for: device
            )
        }
    }

    func setBubbles(_ on: Bool) async {
        guard let device = mspaDevice else { return }

        await runCommand(
            on ? "Blasen werden eingeschaltet …"
               : "Blasen werden ausgeschaltet …"
        ) {
            try await mspaClient.setBubbles(
                on,
                for: device
            )
        }
    }

    func setJets(_ on: Bool) async {
        guard let device = mspaDevice else { return }

        await runCommand(
            on ? "Jets werden eingeschaltet …"
               : "Jets werden ausgeschaltet …"
        ) {
            try await mspaClient.setJets(
                on,
                for: device
            )
        }
    }

    func setUVC(_ on: Bool) async {
        guard let device = mspaDevice else { return }

        await runCommand(
            on ? "UVC wird eingeschaltet …"
               : "UVC wird ausgeschaltet …"
        ) {
            try await mspaClient.setUVC(
                on,
                for: device
            )
        }
    }

    func sendTargetTemperature() async {
        guard let device = mspaDevice else { return }

        await runCommand(
            "Zieltemperatur wird eingestellt …"
        ) {
            try await mspaClient.setTemperature(
                targetTemperature,
                for: device
            )
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
                        TextField(
                            "MSpa E-Mail",
                            text: $vm.mspaEmail
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)

                        SecureField(
                            "MSpa Passwort",
                            text: $vm.mspaPassword
                        )

                        Button("Bei MSpa anmelden") {
                            Task {
                                await vm.connectMSpa()
                            }
                        }
                    }

                    LabeledContent(
                        "Status",
                        value: vm.mspaStatus
                    )

                    if vm.mspaConnected {
                        LabeledContent(
                            "Whirlpool",
                            value: vm.mspaDeviceName
                        )

                        LabeledContent(
                            "Modell",
                            value: vm.mspaModel
                        )

                        LabeledContent(
                            "Cloud",
                            value: vm.mspaOnline
                                ? "Online"
                                : "Offline"
                        )

                        if let temperature = vm.waterTemperature {
                            LabeledContent(
                                "Wassertemperatur",
                                value: String(
                                    format: "%.1f °C",
                                    temperature
                                )
                            )
                        }

                        if let target = vm.mspaTargetTemperature {
                            LabeledContent(
                                "Aktuelles Ziel",
                                value: String(
                                    format: "%.1f °C",
                                    target
                                )
                            )
                        }

                        Toggle(
                            "Heizung",
                            isOn: Binding(
                                get: { vm.mspaHeater },
                                set: { newValue in
                                    Task {
                                        await vm.setHeater(newValue)
                                    }
                                }
                            )
                        )

                        Toggle(
                            "Filter",
                            isOn: Binding(
                                get: { vm.mspaFilter },
                                set: { newValue in
                                    Task {
                                        await vm.setFilter(newValue)
                                    }
                                }
                            )
                        )

                        Toggle(
                            "Blasen",
                            isOn: Binding(
                                get: { vm.mspaBubbles },
                                set: { newValue in
                                    Task {
                                        await vm.setBubbles(newValue)
                                    }
                                }
                            )
                        )

                        Toggle(
                            "Düsen / Jets",
                            isOn: Binding(
                                get: { vm.mspaJets },
                                set: { newValue in
                                    Task {
                                        await vm.setJets(newValue)
                                    }
                                }
                            )
                        )

                        Toggle(
                            "UVC",
                            isOn: Binding(
                                get: { vm.mspaUVC },
                                set: { newValue in
                                    Task {
                                        await vm.setUVC(newValue)
                                    }
                                }
                            )
                        )

                        .disabled(
                            vm.commandRunning ||
                            !vm.mspaOnline
                        )

                        HStack {
                            Text("Zieltemperatur")
                            Spacer()
                            Text(
                                String(
                                    format: "%.1f °C",
                                    vm.targetTemperature
                                )
                            )
                        }

                        Slider(
                            value: $vm.targetTemperature,
                            in: 30...40,
                            step: 0.5
                        )
                        .disabled(vm.commandRunning)

                        Button("Zieltemperatur übertragen") {
                            Task {
                                await vm.sendTargetTemperature()
                            }
                        }
                        .disabled(
                            vm.commandRunning ||
                            !vm.mspaOnline
                        )

                        Button("Status aktualisieren") {
                            Task {
                                await vm.refreshMSpaButton()
                            }
                        }
                        .disabled(vm.commandRunning)
                    }
                }

                Section("SigenStor") {
                    LabeledContent(
                        "Adresse",
                        value: "192.168.1.127:502"
                    )

                    LabeledContent(
                        "Status",
                        value: vm.status
                    )

                    if let s = vm.snapshot {
                        LabeledContent(
                            "PV",
                            value: String(
                                format: "%.2f kW",
                                s.pvKW
                            )
                        )

                        LabeledContent(
                            "Netz",
                            value: s.gridKW >= 0
                                ? String(
                                    format: "Bezug %.2f kW",
                                    s.importKW
                                )
                                : String(
                                    format: "Einspeisung %.2f kW",
                                    s.exportKW
                                )
                        )

                        LabeledContent(
                            "Batterie",
                            value: String(
                                format: "%.1f %%",
                                s.batterySOC
                            )
                        )

                        LabeledContent(
                            "Batterieleistung",
                            value: String(
                                format: "%.2f kW",
                                s.batteryKW
                            )
                        )
                    }

                    Button("Modbus-Verbindung testen") {
                        Task {
                            await vm.testSigen()
                        }
                    }
                }

                Section("PV-Heizautomatik") {
                    Toggle(
                        "Automatik",
                        isOn: $vm.autoHeat
                    )

                    Stepper(
                        "Start: \(vm.startHour):00",
                        value: $vm.startHour,
                        in: 0...23
                    )

                    Stepper(
                        "Ende: \(vm.endHour):00",
                        value: $vm.endHour,
                        in: 1...24
                    )

                    HStack {
                        Text("Überschuss mindestens")
                        Spacer()
                        Text(
                            String(
                                format: "%.1f kW",
                                vm.threshold
                            )
                        )
                    }

                    Slider(
                        value: $vm.threshold,
                        in: 2.2...8,
                        step: 0.1
                    )

                    HStack {
                        Text("Batterie mindestens")
                        Spacer()
                        Text("\(Int(vm.minimumSOC)) %")
                    }

                    Slider(
                        value: $vm.minimumSOC,
                        in: 0...100,
                        step: 5
                    )

                    LabeledContent(
                        "Heizfreigabe",
                        value: vm.solarPermit ? "JA" : "NEIN"
                    )

                    Text(
                        "Die PV-Automatik zeigt momentan nur die Freigabe an. Sie schaltet die Heizung noch nicht automatisch."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("MSpa Solar")
            .task {
                await vm.testSigen()
            }
        }
    }
}
