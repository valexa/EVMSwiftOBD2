#if os(iOS)
import Foundation
import ExternalAccessory
import CoreBluetooth
import Combine

/// USB serial backend for MFi OBD adapters (e.g. OBDLink EX).
/// Connects via the ExternalAccessory framework using the OBDLink protocol string.
/// The adapter must be physically connected via USB-C/Lightning before calling connectAsync.
final class SerialManager: NSObject, CommProtocol, StreamDelegate {

    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    private static let obdProtocol = "com.scantool.stnobd"

    private var session: EASession?
    private var inputStream: InputStream?
    private var outputStream: OutputStream?

    // Single-response path: accumulates bytes until ELM327 ">" prompt
    private var receiveBuffer = ""
    private var responseContinuation: CheckedContinuation<String, Error>?

    // Monitor-mode path: collects lines for a fixed duration
    private var monitorFrames: [String] = []
    private var monitorContinuation: CheckedContinuation<[String], Error>?
    private var monitorEndDate: Date?

    // MARK: - CommProtocol

    func scanForPeripherals() async throws {
        // USB accessories are already connected — nothing to scan for
    }

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        guard let accessory = accessories.first(where: {
            $0.protocolStrings.contains(Self.obdProtocol)
        }) else {
            throw CommunicationError.invalidData
        }

        guard let s = EASession(accessory: accessory, forProtocol: Self.obdProtocol) else {
            throw CommunicationError.invalidData
        }
        session = s

        let input  = s.inputStream
        let output = s.outputStream
        inputStream  = input
        outputStream = output

        input?.delegate  = self
        output?.delegate = self
        input?.schedule(in: .main, forMode: .common)
        output?.schedule(in: .main, forMode: .common)
        input?.open()
        output?.open()

        connectionState = .connectedToAdapter
    }

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        var lastError: Error = CommunicationError.invalidData
        for attempt in 0 ..< max(1, retries) {
            do {
                let raw = try await sendRaw(command)
                return parseLines(raw)
            } catch {
                lastError = error
                if attempt < max(1, retries) - 1 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
        throw lastError
    }

    func sendMonitorCommand(_ command: String, duration: TimeInterval) async throws -> [String] {
        monitorFrames  = []
        monitorEndDate = Date().addingTimeInterval(duration)

        return try await withCheckedThrowingContinuation { continuation in
            monitorContinuation = continuation
            writeBytes(command + "\r")
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self else { return }
                let frames = self.monitorFrames
                self.monitorContinuation?.resume(returning: frames)
                self.monitorContinuation = nil
                self.monitorEndDate      = nil
                self.writeBytes("\r")  // interrupt ELM327 monitor mode
            }
        }
    }

    func disconnectPeripheral() {
        inputStream?.remove(from: .main, forMode: .common)
        outputStream?.remove(from: .main, forMode: .common)
        inputStream?.close()
        outputStream?.close()
        inputStream  = nil
        outputStream = nil
        session      = nil
        responseContinuation?.resume(throwing: CommunicationError.invalidData)
        responseContinuation = nil
        connectionState = .disconnected
    }

    func reset() { disconnectPeripheral() }

    // MARK: - Private

    private func sendRaw(_ command: String) async throws -> String {
        guard let output = outputStream, output.streamStatus == .open else {
            throw CommunicationError.invalidData
        }
        try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self else { return }
            self.responseContinuation = continuation
            self.writeBytes(command + "\r")

            // 20-second hard deadline per command. handleReceivedData is @MainActor,
            // so this asyncAfter on main and the receive path cannot race: whichever
            // fires first nils responseContinuation and the other becomes a no-op.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, let cont = self.responseContinuation else { return }
                self.responseContinuation = nil
                cont.resume(throwing: CommunicationError.invalidData)
            }
        }
    }

    private func writeBytes(_ string: String) {
        guard let output = outputStream, output.streamStatus == .open else { return }
        let bytes = Array(string.utf8)
        output.write(bytes, maxLength: bytes.count)
    }

    private func parseLines(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
           .map    { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
           .filter { !$0.isEmpty && $0 != ">" }
    }

    // MARK: - StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard aStream === inputStream else { return }
        switch eventCode {
        case .hasBytesAvailable:
            drainInputStream()
        case .errorOccurred:
            let err = aStream.streamError ?? CommunicationError.invalidData
            responseContinuation?.resume(throwing: CommunicationError.errorOccurred(err))
            responseContinuation = nil
            monitorContinuation?.resume(returning: monitorFrames)
            monitorContinuation = nil
            connectionState = .disconnected
        default:
            break
        }
    }

    private func drainInputStream() {
        var temp = [UInt8](repeating: 0, count: 512)
        guard let stream = inputStream else { return }
        let count = stream.read(&temp, maxLength: temp.count)
        guard count > 0 else { return }
        let chunk = String(bytes: temp.prefix(count), encoding: .ascii) ?? ""

        if monitorEndDate != nil {
            let lines = parseLines(chunk)
            monitorFrames.append(contentsOf: lines)
        } else {
            receiveBuffer += chunk
            if receiveBuffer.contains(">") {
                let raw = receiveBuffer
                receiveBuffer = ""
                responseContinuation?.resume(returning: raw)
                responseContinuation = nil
            }
        }
    }
}
#endif
