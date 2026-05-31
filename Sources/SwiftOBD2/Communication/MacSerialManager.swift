#if os(macOS)
import Foundation
import CoreBluetooth

/// macOS backend for serial OBD adapters (e.g., USB to Serial).
/// Uses POSIX file descriptors and termios for communication.
final class MacSerialManager: CommProtocol {
    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    private var fileDescriptor: Int32 = -1
    private var isMonitoring = false
    private var monitorContinuation: CheckedContinuation<[String], Error>?
    private var monitorFrames: [String] = []

    private var readTask: Task<Void, Never>?
    private var responseContinuation: CheckedContinuation<String, Error>?
    private var receiveBuffer = ""

    func scanForPeripherals() async throws {
        // Not used, discovery is done via SerialPortDiscovery
    }

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral?) async throws {
        // On macOS, the configuration passes the path via ConfigurationService
        // Wait, how does the service get the path?
        let path = UserDefaults.standard.string(forKey: "serialPath") ?? ""
        guard !path.isEmpty else {
            throw CommunicationError.invalidData
        }

        fileDescriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fileDescriptor >= 0 else {
            throw CommunicationError.errorOccurred(NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil))
        }

        var settings = termios()
        tcgetattr(fileDescriptor, &settings)

        cfmakeraw(&settings)
        cfsetspeed(&settings, speed_t(B38400)) // Standard ELM327 baud rate

        settings.c_cc.16 = 1 // VMIN
        settings.c_cc.17 = 1 // VTIME

        let result = tcsetattr(fileDescriptor, TCSANOW, &settings)
        if result != 0 {
            close(fileDescriptor)
            fileDescriptor = -1
            throw CommunicationError.errorOccurred(NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil))
        }

        connectionState = .connectedToAdapter
        startReading()
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
        isMonitoring = true
        monitorFrames = []

        return try await withCheckedThrowingContinuation { continuation in
            monitorContinuation = continuation
            writeBytes(command + "\r")
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self = self else { return }
                self.isMonitoring = false
                let frames = self.monitorFrames
                self.monitorContinuation?.resume(returning: frames)
                self.monitorContinuation = nil
                self.writeBytes("\r") // Interrupt ELM327
            }
        }
    }

    func disconnectPeripheral() {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        readTask?.cancel()
        readTask = nil
        responseContinuation?.resume(throwing: CommunicationError.invalidData)
        responseContinuation = nil
        monitorContinuation?.resume(throwing: CommunicationError.invalidData)
        monitorContinuation = nil
        connectionState = .disconnected
    }

    func reset() {
        disconnectPeripheral()
    }

    private func sendRaw(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self = self else { return }
            self.responseContinuation?.resume(throwing: CommunicationError.invalidData)
            self.responseContinuation = continuation
            self.receiveBuffer = ""
            self.writeBytes(command + "\r")
        }
    }

    private func writeBytes(_ string: String) {
        guard fileDescriptor >= 0 else { return }
        let bytes = Array(string.utf8)
        bytes.withUnsafeBufferPointer { ptr in
            _ = write(fileDescriptor, ptr.baseAddress, bytes.count)
        }
    }

    private func startReading() {
        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            while let self = self, self.fileDescriptor >= 0, !Task.isCancelled {
                var readyFileDescriptors = fd_set()
                readyFileDescriptors.fds_bits.0 = Int32(1 << self.fileDescriptor)

                var timeout = timeval(tv_sec: 0, tv_usec: 100_000) // 100ms timeout
                let result = select(self.fileDescriptor + 1, &readyFileDescriptors, nil, nil, &timeout)

                if result > 0 {
                    let bytesRead = read(self.fileDescriptor, buffer, bufferSize)
                    if bytesRead > 0 {
                        let chunk = String(bytes: UnsafeBufferPointer(start: buffer, count: bytesRead), encoding: .ascii) ?? ""
                        await self.handleReceivedData(chunk)
                    } else if bytesRead < 0 && errno != EAGAIN {
                        await self.handleError()
                        break
                    }
                }
            }
        }
    }

    @MainActor
    private func handleReceivedData(_ chunk: String) {
        if isMonitoring {
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

    @MainActor
    private func handleError() {
        disconnectPeripheral()
    }

    private func parseLines(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != ">" }
    }
}
#endif
