import Foundation
import Network

struct SigenSnapshot: Sendable {
    let gridKW: Double
    let pvKW: Double
    let batteryKW: Double
    let batterySOC: Double

    var exportKW: Double { max(0, -gridKW) }
    var importKW: Double { max(0, gridKW) }
}

enum ModbusError: Error, LocalizedError {
    case connection(String)
    case timeout
    case malformed
    case exception(UInt8)

    var errorDescription: String? {
        switch self {
        case .connection(let text):
            return text
        case .timeout:
            return "Zeitüberschreitung"
        case .malformed:
            return "Ungültige Modbus-Antwort"
        case .exception(let code):
            return "Modbus-Fehler \(code)"
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

    func readSnapshot() async throws -> SigenSnapshot {
        async let grid = readInt32(address: 30005)
        async let soc = readUInt16(address: 30014)
        async let pv = readInt32(address: 30035)
        async let battery = readInt32(address: 30037)

        return try await SigenSnapshot(
            gridKW: Double(grid) / 1000.0,
            pvKW: Double(pv) / 1000.0,
            batteryKW: Double(battery) / 1000.0,
            batterySOC: Double(soc) / 10.0
        )
    }

    private func readUInt16(address: UInt16) async throws -> UInt16 {
        let data = try await readRegisters(address: address, count: 1)

        guard data.count == 2 else {
            throw ModbusError.malformed
        }

        return (UInt16(data[0]) << 8) |
               UInt16(data[1])
    }

    private func readInt32(address: UInt16) async throws -> Int32 {
        let data = try await readRegisters(address: address, count: 2)

        guard data.count == 4 else {
            throw ModbusError.malformed
        }

        let value =
            (UInt32(data[0]) << 24) |
            (UInt32(data[1]) << 16) |
            (UInt32(data[2]) << 8) |
            UInt32(data[3])

        return Int32(bitPattern: value)
    }

    private func readRegisters(
        address: UInt16,
        count: UInt16
    ) async throws -> Data {

        let tx = transaction
        transaction &+= 1

        var request = Data()

        request.append(contentsOf: [
            UInt8(tx >> 8),
            UInt8(tx & 0xff),

            0,
            0,

            0,
            6,

            unitID,
            4,

            UInt8(address >> 8),
            UInt8(address & 0xff),

            UInt8(count >> 8),
            UInt8(count & 0xff)
        ])

        let connection = NWConnection(
            host: host,
            port: port,
            using: .tcp
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in

                var finished = false
                var buffer = Data()

                func finish(_ result: Result<Data, Error>) {
                    guard !finished else { return }
                    finished = true

                    connection.cancel()
                    continuation.resume(with: result)
                }

                func processBuffer() {
                    guard buffer.count >= 6 else {
                        return
                    }

                    let length =
                        (Int(buffer[4]) << 8) |
                        Int(buffer[5])

                    guard length >= 3,
                          length <= 254 else {
                        finish(.failure(ModbusError.malformed))
                        return
                    }

                    let totalLength = 6 + length

                    guard buffer.count >= totalLength else {
                        return
                    }

                    let response = Data(
                        buffer.prefix(totalLength)
                    )

                    let responseTx =
                        (UInt16(response[0]) << 8) |
                        UInt16(response[1])

                    guard responseTx == tx else {
                        finish(.failure(ModbusError.malformed))
                        return
                    }

                    guard response[2] == 0,
                          response[3] == 0 else {
                        finish(.failure(ModbusError.malformed))
                        return
                    }

                    guard response[6] == unitID else {
                        finish(.failure(ModbusError.malformed))
                        return
                    }

                    let function = response[7]

                    if function == 0x84 {
                        guard response.count >= 9 else {
                            finish(.failure(ModbusError.malformed))
                            return
                        }

                        finish(
                            .failure(
                                ModbusError.exception(response[8])
                            )
                        )
                        return
                    }

                    guard function == 4,
                          response.count >= 9 else {
                        finish(.failure(ModbusError.malformed))
                        return
                    }

                    let byteCount = Int(response[8])
                    let expectedByteCount = Int(count) * 2

                    guard byteCount == expectedByteCount,
                          response.count >= 9 + byteCount else {
                        finish(.failure(ModbusError.malformed))
                        return
                    }

                    let registerData = Data(
                        response[9..<(9 + byteCount)]
                    )

                    finish(.success(registerData))
                }

                func receiveMore() {
                    guard !finished else { return }

                    connection.receive(
                        minimumIncompleteLength: 1,
                        maximumLength: 260
                    ) { data, _, isComplete, error in

                        if let error {
                            finish(
                                .failure(
                                    ModbusError.connection(
                                        error.localizedDescription
                                    )
                                )
                            )
                            return
                        }

                        if let data, !data.isEmpty {
                            buffer.append(data)
                            processBuffer()
                        }

                        guard !finished else {
                            return
                        }

                        if isComplete {
                            finish(
                                .failure(
                                    ModbusError.malformed
                                )
                            )
                            return
                        }

                        receiveMore()
                    }
                }

                connection.stateUpdateHandler = { state in
                    switch state {

                    case .ready:
                        connection.send(
                            content: request,
                            completion: .contentProcessed { error in

                                if let error {
                                    finish(
                                        .failure(
                                            ModbusError.connection(
                                                error.localizedDescription
                                            )
                                        )
                                    )
                                    return
                                }

                                receiveMore()
                            }
                        )

                    case .failed(let error):
                        finish(
                            .failure(
                                ModbusError.connection(
                                    error.localizedDescription
                                )
                            )
                        )

                    case .cancelled:
                        break

                    default:
                        break
                    }
                }

                connection.start(
                    queue: .global(qos: .userInitiated)
                )

                DispatchQueue.global().asyncAfter(
                    deadline: .now() + 5
                ) {
                    finish(
                        .failure(
                            ModbusError.timeout
                        )
                    )
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}