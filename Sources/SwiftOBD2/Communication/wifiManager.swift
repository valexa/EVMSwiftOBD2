//
//  wifiManager.swift
//
//
//  Created by kemo konteh on 2/26/24.
//

import CoreBluetooth
import Foundation
import Network
import OSLog

// CommProtocol and CommunicationError are defined in CommProtocol.swift

// NWConnection callbacks land outside Swift concurrency, so all continuation
// resumes are gated through ResumeOnce to guarantee exactly-one semantics even
// when a deadline and a receive callback race. It also owns the lock-protected
// text buffer those callbacks accumulate into.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var buffer = ""
    var continuation: CheckedContinuation<String, Error>?

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }

    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += text
    }

    var accumulated: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func finishWithAccumulated() {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation?.resume(returning: buffer)
    }

    func finish(throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation?.resume(throwing: error)
    }
}

class WifiManager: CommProtocol {
    @Published var connectionState: ConnectionState = .disconnected

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "wifiManager")

    var obdDelegate: OBDServiceDelegate?

    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    var tcp: NWConnection?

    private let hostString: String
    private let portString: String

    init(host: String = "192.168.0.10", port: String = "35000") {
        self.hostString = host
        self.portString = port
    }

    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral? = nil) async throws {
        let host = NWEndpoint.Host(hostString)
        guard let port = NWEndpoint.Port(portString) else {
            throw CommunicationError.invalidData
        }
        tcp = NWConnection(host: host, port: port, using: .tcp)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tcp?.stateUpdateHandler = { [weak self] newState in
                guard let self = self else { return }
                switch newState {
                case .ready:
                    self.logger.info("Connected to \(host.debugDescription):\(port.debugDescription)")
                    self.connectionState = .connectedToAdapter
                    continuation.resume(returning: ())
                case let .waiting(error):
                    self.logger.warning("Connection waiting: \(error.localizedDescription)")
                case let .failed(error):
                    self.logger.error("Connection failed: \(error.localizedDescription)")
                    self.connectionState = .disconnected
                    continuation.resume(throwing: CommunicationError.errorOccurred(error))
                default:
                    break
                }
            }
            tcp?.start(queue: .main)
        }
    }

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        guard let data = "\(command)\r".data(using: .ascii) else {
            throw CommunicationError.invalidData
        }
        logger.info("Sending: \(command)")

        // ATZ resets the adapter hardware — most WiFi ELM327 adapters drop the TCP
        // connection immediately after. Fire-and-forget the command, wait for the
        // reset to complete, then re-establish the TCP connection.
        if command.uppercased() == "ATZ" {
            let old = tcp
            old?.send(content: data, completion: .contentProcessed { _ in })
            try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 s for adapter reset
            old?.cancel()
            try await connectAsync(timeout: 10, peripheral: nil)
            return ["ELM327 v2.1"]
        }

        return try await sendCommandInternal(data: data, retries: retries)
    }

    func sendMonitorCommand(_ command: String, duration: TimeInterval) async throws -> [String] {
        guard let tcpConnection = tcp, let data = "\(command)\r".data(using: .ascii) else {
            throw CommunicationError.invalidData
        }

        let gate = ResumeOnce()
        let raw: String = try await withCheckedThrowingContinuation { continuation in
            gate.continuation = continuation

            // Monitor mode streams frames with no '>' terminator; the deadline is the
            // only stop condition. Whatever accumulated by then is the capture.
            DispatchQueue.global().asyncAfter(deadline: .now() + duration) {
                gate.finishWithAccumulated()
            }

            tcpConnection.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    gate.finishWithAccumulated()
                    return
                }
                func readNext() {
                    tcpConnection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { chunk, _, isComplete, error in
                        // After the deadline this pending receive doubles as the drain
                        // for the "STOPPED >" acknowledgment — consume and stop.
                        if gate.isDone { return }
                        if let chunk, let str = String(data: chunk, encoding: .utf8) {
                            gate.append(str)
                        }
                        if error != nil || isComplete {
                            gate.finishWithAccumulated()
                        } else {
                            readNext()
                        }
                    }
                }
                readNext()
            })
        }

        // A bare CR stops ELM327 monitor mode; the loop's still-pending receive
        // drains the resulting "STOPPED >" so it can't corrupt the next command.
        if let cr = "\r".data(using: .ascii) {
            tcpConnection.send(content: cr, completion: .contentProcessed { _ in })
        }

        return raw
            .replacingOccurrences(of: ">", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.uppercased() != "STOPPED" }
    }

    private func sendCommandInternal(data: Data, retries: Int) async throws -> [String] {
        // Clamp so retries <= 0 still makes one attempt — `1 ... 0` is an invalid
        // range and traps at runtime.
        let attempts = max(1, retries)
        for attempt in 1 ... attempts {
            do {
                let response = try await sendAndReceiveData(data)
                if let lines = processResponse(response) {
                    return lines
                } else if attempt < attempts {
                    logger.info("No data received, retrying attempt \(attempt + 1) of \(attempts)...")
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second delay
                }
            } catch {
                if attempt == attempts {
                    throw error
                }
                logger.warning("Attempt \(attempt) failed, retrying: \(error.localizedDescription)")
            }
        }
        throw CommunicationError.invalidData
    }

    private func sendAndReceiveData(_ data: Data) async throws -> String {
        guard let tcpConnection = tcp else {
            throw CommunicationError.invalidData
        }
        let logger = self.logger

        let gate = ResumeOnce()

        return try await withCheckedThrowingContinuation { continuation in
            gate.continuation = continuation

            // 15-second hard deadline — covers slow protocol auto-detection (SEARCHING...).
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                gate.finish(throwing: CommunicationError.invalidData)
            }

            tcpConnection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    logger.error("Error sending data: \(error.localizedDescription)")
                    gate.finish(throwing: CommunicationError.errorOccurred(error))
                    return
                }

                // Accumulate TCP chunks until the ELM327 '>' prompt is received.
                // A single receive() call may only return a partial response.
                func readNext() {
                    tcpConnection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { chunk, _, isComplete, error in
                        if gate.isDone { return }
                        if let error = error {
                            logger.error("Error receiving data: \(error.localizedDescription)")
                            gate.finish(throwing: gate.accumulated.isEmpty
                                ? CommunicationError.errorOccurred(error)
                                : CommunicationError.invalidData)
                            return
                        }

                        if let chunk, let str = String(data: chunk, encoding: .utf8) {
                            gate.append(str)
                        }

                        if gate.accumulated.contains(">") || isComplete {
                            gate.finishWithAccumulated()
                        } else {
                            readNext()
                        }
                    }
                }

                readNext()
            })
        }
    }

    private func processResponse(_ response: String) -> [String]? {
        logger.info("Processing response: \(response)")
        var lines = response.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !lines.isEmpty else {
            logger.warning("Empty response lines")
            return nil
        }

        if lines.last?.contains(">") == true {
            lines.removeLast()
        }

        if lines.first?.lowercased() == "no data" {
            return nil
        }

        return lines
    }

    func disconnectPeripheral() {
        tcp?.cancel()
    }

    func scanForPeripherals() async throws {}

    func reset() {
        disconnectPeripheral()
    }
}
