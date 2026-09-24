import Foundation
import CryptoKit

struct MSpaDevice: Identifiable, Sendable {
    let id: String
    let productID: String
    let name: String
    let model: String
}

struct MSpaStatus: Sendable {
    let waterTemperature: Double?
    let targetTemperature: Double?
    let heaterOn: Bool
    let filterOn: Bool
    let bubblesOn: Bool
    let jetsOn: Bool
    let uvcOn: Bool
    let online: Bool
}

enum MSpaError: Error, LocalizedError {
    case invalidResponse
    case authenticationFailed(String)
    case noDevices
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Ungültige Antwort vom MSpa-Server."
        case .authenticationFailed(let message):
            return "MSpa-Anmeldung fehlgeschlagen: \(message)"
        case .noDevices:
            return "Im MSpa-Konto wurde kein Whirlpool gefunden."
        case .api(let message):
            return "MSpa-Fehler: \(message)"
        }
    }
}

actor MSpaClient {

    // Europa / Rest of World
    private let baseURL = "https://api.iot.the-mspa.com"

    // Werte der offiziellen MSpa-Link-App.
    // Dies sind KEINE persönlichen Zugangsdaten.
    private let appID = "e1c8e068f9ca11eba4dc0242ac120002"
    private let appSecret = "87025c9ecd18906d27225fe79cb68349"

    private var token: String?

    // MARK: - Öffentliche Funktionen

    func login(email: String, password: String) async throws {
        let passwordHash = md5(password)

        let body: [String: Any] = [
            "account": email,
            "app_id": appID,
            "password": passwordHash,
            "brand": "",
            "registration_id": "",
            "push_type": "android",
            "lan_code": "EN",
            "country": ""
        ]

        let json = try await request(
            path: "/api/enduser/get_token/",
            method: "POST",
            body: body,
            authenticated: false
        )

        guard
            let data = json["data"] as? [String: Any],
            let receivedToken = data["token"] as? String,
            !receivedToken.isEmpty
        else {
            let message = json["message"] as? String ?? "Kein Token erhalten"
            throw MSpaError.authenticationFailed(message)
        }

        token = receivedToken
    }

    func getDevices() async throws -> [MSpaDevice] {
        let json = try await request(
            path: "/api/enduser/devices/",
            method: "GET",
            body: nil,
            authenticated: true
        )

        guard
            let data = json["data"] as? [String: Any],
            let list = data["list"] as? [[String: Any]]
        else {
            throw MSpaError.invalidResponse
        }

        let devices = list.compactMap { item -> MSpaDevice? in
            guard let deviceID = stringValue(item["device_id"]) else {
                return nil
            }

            let productID =
                stringValue(item["product_id"]) ?? ""

            let name =
                stringValue(item["device_alias"]) ??
                stringValue(item["name"]) ??
                "MSpa"

            let model =
                stringValue(item["product_model"]) ??
                stringValue(item["model"]) ??
                "Unbekannt"

            return MSpaDevice(
                id: deviceID,
                productID: productID,
                name: name,
                model: model
            )
        }

        guard !devices.isEmpty else {
            throw MSpaError.noDevices
        }

        return devices
    }

    func getStatus(for device: MSpaDevice) async throws -> MSpaStatus {
        let body: [String: Any] = [
            "device_id": device.id,
            "product_id": device.productID
        ]

        let json = try await request(
            path: "/api/device/thing_shadow/",
            method: "POST",
            body: body,
            authenticated: true
        )

        guard let data = json["data"] as? [String: Any] else {
            throw MSpaError.invalidResponse
        }

        /*
         MSpa liefert die Wassertemperatur bei diesen Geräten
         typischerweise in 0,5-°C-Schritten als Ganzzahl.
         Beispiel: 79 -> 39,5 °C.
        */
        let rawWater = doubleValue(data["water_temperature"])

        let waterTemperature: Double?
        if let rawWater {
            waterTemperature = rawWater > 50
                ? rawWater / 2.0
                : rawWater
        } else {
            waterTemperature = nil
        }

        let targetTemperature =
            doubleValue(data["temperature_setting"])

        return MSpaStatus(
            waterTemperature: waterTemperature,
            targetTemperature: targetTemperature,
            heaterOn: boolValue(data["heater_state"]),
            filterOn: boolValue(data["filter_state"]),
            bubblesOn: boolValue(data["bubble_state"]),
            jetsOn: boolValue(data["jet_state"]),
            uvcOn: boolValue(data["uvc_state"]),
            online: boolValue(data["is_online"])
        )
    }

    // MARK: - HTTP

    private func request(
        path: String,
        method: String,
        body: [String: Any]?,
        authenticated: Bool
    ) async throws -> [String: Any] {

        guard let url = URL(string: baseURL + path) else {
            throw MSpaError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30

        let nonce = randomNonce()
        let timestamp = String(Int(Date().timeIntervalSince1970))

        let signatureSource =
            "\(appID),\(appSecret),\(nonce),\(timestamp)"

        let signature = md5(signatureSource).uppercased()

        request.setValue("Android", forHTTPHeaderField: "push_type")
        request.setValue(
            authenticated
                ? "token \(token ?? "")"
                : "token",
            forHTTPHeaderField: "authorization"
        )

        request.setValue(appID, forHTTPHeaderField: "appid")
        request.setValue(nonce, forHTTPHeaderField: "nonce")
        request.setValue(timestamp, forHTTPHeaderField: "ts")
        request.setValue("de", forHTTPHeaderField: "lan_code")
        request.setValue(signature, forHTTPHeaderField: "sign")
        request.setValue(
            "application/json; charset=UTF-8",
            forHTTPHeaderField: "content-type"
        )

        request.setValue(
            "okhttp/4.9.0",
            forHTTPHeaderField: "user-agent"
        )

        if let body {
            request.httpBody = try JSONSerialization.data(
                withJSONObject: body
            )
        }

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let http = response as? HTTPURLResponse else {
            throw MSpaError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            throw MSpaError.api(
                "HTTP \(http.statusCode)"
            )
        }

        guard
            let object = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any]
        else {
            throw MSpaError.invalidResponse
        }

        if let code = object["code"] as? Int,
           code != 0,
           code != 200 {

            let message =
                object["message"] as? String ??
                "API-Code \(code)"

            // Manche erfolgreichen Antworten verwenden
            // ebenfalls eigene Codes. Daten haben deshalb Vorrang.
            if object["data"] == nil {
                throw MSpaError.api(message)
            }
        }

        return object
    }

    // MARK: - Hilfsfunktionen

    private func md5(_ text: String) -> String {
        let digest = Insecure.MD5.hash(
            data: Data(text.utf8)
        )

        return digest.map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func randomNonce(length: Int = 32) -> String {
        let characters =
            Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

        return String(
            (0..<length).compactMap { _ in
                characters.randomElement()
            }
        )
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }

        if let value = value as? NSNumber {
            return value.stringValue
        }

        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }

        if let value = value as? Int {
            return Double(value)
        }

        if let value = value as? NSNumber {
            return value.doubleValue
        }

        if let value = value as? String {
            return Double(value)
        }

        return nil
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }

        if let value = value as? Int {
            return value != 0
        }

        if let value = value as? NSNumber {
            return value.intValue != 0
        }

        if let value = value as? String {
            return value == "1" ||
                   value.lowercased() == "true" ||
                   value.lowercased() == "online"
        }

        return false
    }
}
