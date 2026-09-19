//
//  BLECharacteristicHandlerFallbackTests.swift
//
//  Covers the property-based fallback classifier added for BLE OBD2 adapters
//  that don't advertise one of the known UUID families (FFE0/FFF0/18F0/ISSC).
//
//  BLECharacteristicHandler.applyFallbackIfNeeded(on:) itself takes a
//  CBPeripheral, which has no public initializer, so these tests exercise
//  the pure selection logic behind it (selectFallbackPair) instead.
//

@testable import SwiftOBD2
import CoreBluetooth
import XCTest

final class BLECharacteristicHandlerFallbackTests: XCTestCase {
    /// A vendor UUID we've never seen, with separate write and notify
    /// characteristics — the two-characteristic shape (like FFF0/FFF1/FFF2).
    func testSelectsSeparateWriteAndNotifyCharacteristics() {
        let writeChar = CBMutableCharacteristic(
            type: CBUUID(string: "12340001-0000-1000-8000-00805F9B34FB"),
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        let notifyChar = CBMutableCharacteristic(
            type: CBUUID(string: "12340002-0000-1000-8000-00805F9B34FB"),
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )

        let pair = BLECharacteristicHandler.selectFallbackPair(from: [writeChar, notifyChar])

        XCTAssertEqual(pair.write?.uuid, writeChar.uuid)
        XCTAssertEqual(pair.read?.uuid, notifyChar.uuid)
    }

    /// A single characteristic that both accepts writes and notifies — the
    /// one-characteristic shape (like FFE1) but under an unrecognised UUID.
    /// It should win over separate candidates, and be used for both roles.
    func testPrefersSingleCombinedCharacteristicOverSeparateOnes() {
        let decoyWrite = CBMutableCharacteristic(
            type: CBUUID(string: "12340004-0000-1000-8000-00805F9B34FB"),
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        let combined = CBMutableCharacteristic(
            type: CBUUID(string: "12340003-0000-1000-8000-00805F9B34FB"),
            properties: [.write, .notify],
            value: nil,
            permissions: [.writeable, .readable]
        )

        let pair = BLECharacteristicHandler.selectFallbackPair(from: [decoyWrite, combined])

        XCTAssertEqual(pair.write?.uuid, combined.uuid)
        XCTAssertEqual(pair.read?.uuid, combined.uuid)
    }

    /// writeWithoutResponse counts as a write candidate too — several clones
    /// (e.g. the ISSC UART) only offer that, never plain .write.
    func testWriteWithoutResponseCountsAsWriteCandidate() {
        let writeChar = CBMutableCharacteristic(
            type: CBUUID(string: "12340005-0000-1000-8000-00805F9B34FB"),
            properties: [.writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let notifyChar = CBMutableCharacteristic(
            type: CBUUID(string: "12340006-0000-1000-8000-00805F9B34FB"),
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )

        let pair = BLECharacteristicHandler.selectFallbackPair(from: [writeChar, notifyChar])

        XCTAssertEqual(pair.write?.uuid, writeChar.uuid)
        XCTAssertEqual(pair.read?.uuid, notifyChar.uuid)
    }

    /// No candidates at all (e.g. only Device Information Service was
    /// discovered) — must return nils, not crash.
    func testNoCandidatesYieldsNilPair() {
        let pair = BLECharacteristicHandler.selectFallbackPair(from: [])
        XCTAssertNil(pair.read)
        XCTAssertNil(pair.write)
    }

    /// A characteristic with no relevant properties at all (e.g. .indicate
    /// only) is not a plausible candidate for either role.
    func testCharacteristicWithUnrelatedPropertiesIsIgnored() {
        let indicateOnly = CBMutableCharacteristic(
            type: CBUUID(string: "12340007-0000-1000-8000-00805F9B34FB"),
            properties: [.indicate],
            value: nil,
            permissions: [.readable]
        )

        let pair = BLECharacteristicHandler.selectFallbackPair(from: [indicateOnly])

        XCTAssertNil(pair.read)
        XCTAssertNil(pair.write)
    }
}
