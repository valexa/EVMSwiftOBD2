import CoreBluetooth
import Foundation

// MARK: - Shared transport protocol

/// Implemented by every OBD transport backend (BLE, WiFi TCP, USB serial).
protocol CommProtocol {
    func sendCommand(_ command: String, retries: Int) async throws -> [String]
    func sendMonitorCommand(_ command: String, duration: TimeInterval) async throws -> [String]
    func disconnectPeripheral()
    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral?) async throws
    func scanForPeripherals() async throws
    func reset()
    var connectionStatePublisher: Published<ConnectionState>.Publisher { get }
    var obdDelegate: OBDServiceDelegate? { get set }
}

// MARK: - Transport-layer errors

enum CommunicationError: Error {
    case invalidData
    case errorOccurred(Error)
    /// The connect attempt exceeded the caller's timeout without reaching `.ready`.
    case timeout
    /// The connection was cancelled (e.g. user disconnect or app-side timeout) before it was established.
    case cancelled
}
