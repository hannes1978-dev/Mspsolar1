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

    // MSpa
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

    private let sigenClient = SigenModbusClient()
    private let mspaClient = MSpaClient()
    private var mspaDevice: MSpaDevice?

    var solarPermit: Bool {
        guard let s = snapshot else { return false }

        let hour = Calendar.current.component(.hour, from: Date())

        return hour >= startHour &&
               hour < endHour &&
               s.exportKW >= threshold &&
               s.batterySOC >= minimumSOC
    }

    func testSigen() async {
        status = "Verbinde mit 192.168.1.127:502 …"

        do {
            let s = try await sigenClient.readSnapshot()
            snapshot = s
            connected = true
            status = "SigenStor verbunden"
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

            mspaStatus = "Lese Whirlpool-Status …"

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
                        if !vm.mspaDeviceName.isEmpty {
                            LabeledContent(
                                "Whirlpool",
                                value: vm.mspaDeviceName
                            )
                        }

                        if !vm.mspaModel.isEmpty {
                            LabeledContent(
                                "Modell",
                                value: vm.mspaModel
                            )
                        }

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
                                "MSpa Zieltemperatur",
                                value: String(
                                    format: "%.1f °C",
                                    target
                                )
                            )
                        }

                        LabeledContent(
                            "Heizung",
                            value: vm.mspaHeater ? "AN" : "AUS"
                        )

                        LabeledContent(
                            "Filter",
                            value: vm.mspaFilter ? "AN" : "AUS"
                        )

                        LabeledContent(
                            "Blasen",
                            value: vm.mspaBubbles ? "AN" : "AUS"
                        )

                        LabeledContent(
                            "Jets",
                            value: vm.mspaJets ? "AN" : "AUS"
                        )

                        LabeledContent(
                            "UVC",
                            value: vm.mspaUVC ? "AN" : "AUS"
                        )

                        Button("MSpa-Status aktualisieren") {
                            Task {
                                await vm.refreshMSpaButton()
                            }
                        }

                        Text(
                            "Diese Testversion liest den Whirlpool nur aus. Sie sendet noch keine Schaltbefehle."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

                Section("Whirlpool-Steuerung – Vorbereitung") {
                    Toggle(
                        "Heizung",
                        isOn: $vm.heater
                    )

                    Toggle(
                        "Blasen",
                        isOn: $vm.bubbles
                    )

                    Toggle(
                        "Düsen / Jets",
                        isOn: $vm.jets
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

                    Text(
                        "Diese Schalter senden noch keine Befehle an den MSpa."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                }
            }
            .navigationTitle("MSpa Solar")
            .task {
                await vm.testSigen()
            }
        }
    }
}
