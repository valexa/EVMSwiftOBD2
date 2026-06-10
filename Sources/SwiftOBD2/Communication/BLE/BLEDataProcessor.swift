import Combine
import CoreBluetooth
import Foundation
import OSLog

class BLEMessageProcessor {
    private var buffer = Data()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "BLEMessageProcessor")
    // messageCompletion is set from the waiting task and consumed from either the
    // BLE queue (response arrived) or the cancellation handler (timeout). Those two
    // can race; takeCompletion() makes the hand-off atomic so the continuation can
    // never be resumed twice.
    private let completionLock = NSLock()
    private var messageCompletion: (([String]?, Error?) -> Void)?

    private func setCompletion(_ completion: @escaping ([String]?, Error?) -> Void) {
        completionLock.lock()
        assert(messageCompletion == nil, "Concurrent command detected")
        messageCompletion = completion
        completionLock.unlock()
    }

    private func takeCompletion() -> (([String]?, Error?) -> Void)? {
        completionLock.lock()
        defer { completionLock.unlock() }
        let completion = messageCompletion
        messageCompletion = nil
        return completion
    }
    /// When true, a timeout in waitForResponse returns buffered data instead of throwing.
    /// Used by sendMonitorCommand to capture ELM327 AT MA / AT MT streaming output.
    var monitorMode = false

    func processReceivedData(_ data: Data) {
        buffer.append(data)

        guard let string = String(data: buffer, encoding: .utf8) else {
            if buffer.count > BLEConstants.maxBufferSize {
                logger.warning("Buffer exceeded max size, clearing")
                buffer.removeAll()
            }
            return
        }

        // In monitor mode (AT MA) the ELM327 streams frames without a prompt; the adapter
        // may emit a bare '>' acknowledgment before the stream starts. Triggering completion
        // on that early '>' stops the monitor before any frames arrive. Let the duration
        // timeout path collect the full stream instead.
        if monitorMode { return }

        if string.contains(">") {
            let response = parseResponse(from: string)
            handleParsedResponse(response)
            buffer.removeAll()
        }
    }

    private func parseResponse(from string: String) -> [String] {
        // Split by newlines and clean up
        let lines = string
            .replacingOccurrences(of: ">", with: "") // Remove prompt marker
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        logger.debug("Parsed response: \(lines)")
        return lines
    }

    private func handleParsedResponse(_ lines: [String]) {
       guard let completion = takeCompletion() else {
           logger.warning("Received response with no pending completion")
           return
       }

       if let firstLine = lines.first, firstLine.uppercased().contains("NO DATA") {
           completion(nil, BLEManagerError.noData)
       } else if lines.isEmpty {
           completion(nil, BLEManagerError.noData)
       } else {
           completion(lines, nil)
       }
   }


    func waitForResponse(timeout: TimeInterval) async throws -> [String] {
        do {
            return try await withTimeout(seconds: timeout, timeoutError: BLEMessageProcessorError.responseTimeout) { [self] in
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                        setCompletion { response, error in
                            if let response = response {
                                continuation.resume(returning: response)
                            } else if let error = error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume(throwing: BLEMessageProcessorError.responseTimeout)
                            }
                        }
                    }
                } onCancel: { [self] in
                    self.takeCompletion()?(nil, BLEMessageProcessorError.responseTimeout)
                }
            }
        } catch BLEMessageProcessorError.responseTimeout where monitorMode {
            // In monitor mode the ELM327 streams frames without a '>' terminator;
            // return whatever accumulated in the buffer rather than throwing.
            monitorMode = false
            let captured = buffer
            buffer.removeAll()
            _ = takeCompletion()
            guard let string = String(data: captured, encoding: .utf8), !string.isEmpty else { return [] }
            return string
                .replacingOccurrences(of: ">", with: "")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    func reset() {
           buffer.removeAll()
           // Call completion with error if it exists
           takeCompletion()?(nil, BLEManagerError.peripheralNotConnected)
       }
}

// MARK: - Error Types

enum BLEMessageProcessorError: Error, LocalizedError {
    case characteristicNotWritable
    case writeOperationFailed
    case responseTimeout
    case invalidResponseData

    var errorDescription: String? {
        switch self {
        case .characteristicNotWritable:
            return "BLE characteristic does not support write operations"
        case .writeOperationFailed:
            return "Failed to write data to BLE characteristic"
        case .responseTimeout:
            return "Timeout waiting for BLE response"
        case .invalidResponseData:
            return "Received invalid response data from BLE device"
        }
    }
}
