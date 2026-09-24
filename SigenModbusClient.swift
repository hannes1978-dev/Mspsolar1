import Foundation
import Network

struct SigenSnapshot: Sendable {
    let gridKW: Double       // + import, - export
    let pvKW: Double
    let batteryKW: Double    // + charging, - discharging
    let batterySOC: Double

    var exportKW: Double { max(0, -gridKW) }
    var importKW: Double { max(0, gridKW) }
}

enum ModbusError: Error, LocalizedError {
    case connection(String), timeout, malformed, exception(UInt8)
    var errorDescription: String? {
        switch self {
        case .connection(let s): return s
        case .timeout: return "Zeitüberschreitung"
        case .malformed: return "Ungültige Modbus-Antwort"
        case .exception(let c): return "Modbus-Fehler \(c)"
        }
    }
}

actor SigenModbusClient {
    let host: NWEndpoint.Host
    let port: NWEndpoint.Port
    let unitID: UInt8 = 247
    private var transaction: UInt16 = 1

    init(host: String = "192.168.1.127", port: UInt16 = 502) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    // Sigenergy plant registers: 30005 grid, 30014 SOC, 30035 PV, 30037 battery.
    func readSnapshot() async throws -> SigenSnapshot {
        async let grid = readInt32(address: 30005)
        async let soc = readUInt16(address: 30014)
        async let pv = readInt32(address: 30035)
        async let batt = readInt32(address: 30037)
        return try await SigenSnapshot(
            gridKW: Double(grid) / 1000.0,
            pvKW: Double(pv) / 1000.0,
            batteryKW: Double(batt) / 1000.0,
            batterySOC: Double(soc) / 10.0
        )
    }

    private func readUInt16(address: UInt16) async throws -> UInt16 {
        let d = try await readRegisters(address: address, count: 1)
        guard d.count >= 2 else { throw ModbusError.malformed }
        return (UInt16(d[0]) << 8) | UInt16(d[1])
    }

    private func readInt32(address: UInt16) async throws -> Int32 {
        let d = try await readRegisters(address: address, count: 2)
        guard d.count >= 4 else { throw ModbusError.malformed }
        let u = (UInt32(d[0]) << 24) | (UInt32(d[1]) << 16) | (UInt32(d[2]) << 8) | UInt32(d[3])
        return Int32(bitPattern: u)
    }

    private func readRegisters(address: UInt16, count: UInt16) async throws -> Data {
        let tx = transaction; transaction &+= 1
        var request = Data()
        request.append(contentsOf: [UInt8(tx >> 8), UInt8(tx & 0xff), 0, 0, 0, 6, unitID, 4,
                                    UInt8(address >> 8), UInt8(address & 0xff), UInt8(count >> 8), UInt8(count & 0xff)])
        let connection = NWConnection(host: host, port: port, using: .tcp)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { cont in
                var finished = false
                func finish(_ result: Result<Data, Error>) {
                    guard !finished else { return }; finished = true
                    connection.cancel(); cont.resume(with: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: request, completion: .contentProcessed { err in
                            if let err { finish(.failure(ModbusError.connection(err.localizedDescription))); return }
                            connection.receive(minimumIncompleteLength: 9, maximumLength: 260) { data, _, _, err in
                                if let err { finish(.failure(ModbusError.connection(err.localizedDescription))); return }
                                guard let data, data.count >= 9 else { finish(.failure(ModbusError.malformed)); return }
                                let bytes = [UInt8](data)
                                let function = bytes[7]
                                if function & 0x80 != 0 { finish(.failure(ModbusError.exception(bytes[8]))); return }
                                guard function == 4 else { finish(.failure(ModbusError.malformed)); return }
                                let byteCount = Int(bytes[8])
                                guard bytes.count >= 9 + byteCount else { finish(.failure(ModbusError.malformed)); return }
                                finish(.success(Data(bytes[9..<(9 + byteCount)])))
                            }
                        })
                    case .failed(let e): finish(.failure(ModbusError.connection(e.localizedDescription)))
                    case .cancelled: break
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(.failure(ModbusError.timeout)) }
            }
        }, onCancel: { connection.cancel() })
    }
}
