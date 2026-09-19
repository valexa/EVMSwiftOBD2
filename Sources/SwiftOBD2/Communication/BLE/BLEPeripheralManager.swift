import Foundation
import CoreBluetooth
import Combine

protocol BLEPeripheralManagerDelegate: AnyObject {
    func peripheralManager(_ manager: BLEPeripheralManager, didSetupCharacteristics peripheral: CBPeripheral)
}

class BLEPeripheralManager: NSObject, ObservableObject {
    func didWriteValue(_ peripheral: CBPeripheral, descriptor: CBDescriptor, error: (any Error)?) {

    }

    @Published var connectedPeripheral: CBPeripheral?
    private let characteristicHandler: BLECharacteristicHandler

    // Tracks how many of the peripheral's services still owe us a
    // didDiscoverCharacteristicsFor callback. Once it reaches zero without
    // characteristicHandler.isReady, every known-UUID service the peripheral
    // has to offer has already been examined and come up empty — that's the
    // signal to fall back to classifying by characteristic properties instead
    // of giving up (see BLECharacteristicHandler.applyFallbackIfNeeded).
    private var pendingServiceDiscoveries = 0

    weak var delegate: BLEPeripheralManagerDelegate?
    // Resumed from the CB queue (characteristics ready/failed), reset() on an
    // arbitrary thread, or the cancellation handler — take-once so those racing
    // paths can never double-resume the waiting continuation.
    private let setupCompletion = TakeOnceCompletion<CBPeripheral>()

    init(characteristicHandler: BLECharacteristicHandler) {
        self.characteristicHandler = characteristicHandler
        super.init()
    }

    func setPeripheral(_ peripheral: CBPeripheral?) {
        connectedPeripheral?.delegate = nil
        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self

        pendingServiceDiscoveries = 0

        if let peripheral = peripheral {
            // Discover every service, not just the known OBD UUIDs. An adapter
            // whose GATT layout we've never seen still needs its services
            // reported so the fallback classifier (triggered from
            // didDiscoverCharacteristics below) gets a chance to look at them.
            // Filtering here would hide them from CoreBluetooth's delegate
            // entirely, before characteristicHandler ever runs.
            peripheral.discoverServices(nil)
        }
    }

    /// timeout may be .infinity (pending-connect mode: CoreBluetooth holds the
    /// connect until the dongle appears, so cancellation is the only way out —
    /// withTimeout runs the operation with no timeout child in that case).
    func waitForCharacteristicsSetup(timeout: TimeInterval) async throws {
        try await withTimeout(seconds: timeout) { [self] in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let claimed = setupCompletion.set { peripheral, error in
                        if peripheral != nil {
                            continuation.resume()
                        } else if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(throwing: BLEManagerError.unknownError)
                        }
                    }
                    if !claimed {
                        continuation.resume(throwing: BLEManagerError.connectionInProgress)
                    }
                }
            } onCancel: { [self] in
                setupCompletion.take()?(nil, CancellationError())
            }
        }
    }

    func didDiscoverServices(_ peripheral: CBPeripheral, error: Error?) {
        let services = peripheral.services ?? []
        pendingServiceDiscoveries = services.count
        for service in services {
            obdInfo("Discovered service: \(service.uuid.uuidString)", category: .bluetooth)
            characteristicHandler.discoverCharacteristics(for: service, on: peripheral)
        }
    }

    func didDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
        if pendingServiceDiscoveries > 0 {
            pendingServiceDiscoveries -= 1
        }

        if let error = error {
            obdError("Error discovering characteristics: \(error.localizedDescription)", category: .bluetooth)
            // Don't fail the whole setup on one service's error — an unrelated
            // service (e.g. Device Information) can legitimately refuse
            // discovery while the OBD service still comes through fine.
        } else if let characteristics = service.characteristics {
            characteristicHandler.setupCharacteristics(characteristics, on: peripheral)
        }

        // Every known-UUID candidate has reported and none produced a usable
        // read/write pair — try classifying by characteristic properties
        // instead of failing outright. Adapters we've never cataloged by
        // UUID still tend to expose one write-ish and one notify-ish
        // characteristic; this is what makes them work without a code change.
        if !characteristicHandler.isReady && pendingServiceDiscoveries == 0 {
            characteristicHandler.applyFallbackIfNeeded(on: peripheral)
        }

        // Check if all required characteristics are set up
        if characteristicHandler.isReady {
            // Claim first: if the timeout/cancel/reset path already took the
            // slot, this late success must not resume again — and must not
            // announce .connectedToAdapter for a connection the caller has
            // already torn down. Also swallows repeat isReady callbacks from
            // additional services.
            guard let completion = setupCompletion.take() else { return }
            completion(peripheral, nil)
            delegate?.peripheralManager(self, didSetupCharacteristics: peripheral)
        }
    }

    func didUpdateValue(_: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            obdError("Error reading characteristic value: \(error.localizedDescription)", category: .bluetooth)
            return
        }

        guard let data = characteristic.value else { return }
        characteristicHandler.handleUpdatedValue(data, from: characteristic)
    }

    func reset() {
        connectedPeripheral?.delegate = nil
        connectedPeripheral = nil
        setupCompletion.take()?(nil, BLEManagerError.peripheralNotConnected)
    }
}

extension BLEPeripheralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        didDiscoverServices(peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        didDiscoverCharacteristics(peripheral, service: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        didUpdateValue(peripheral, characteristic: characteristic, error: error)
    }
}
