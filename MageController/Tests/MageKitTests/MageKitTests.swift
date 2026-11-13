import XCTest
import IOKit.hid
@testable import MageKit

final class MageKitTests: XCTestCase {
    func testProtocolSequenceIsUniqueWhenFramesAreBuiltConcurrently() {
        MageProtocol.resetSeq()
        let count = 512
        let lock = NSLock()
        var frames = [[UInt8]]()
        frames.reserveCapacity(count)
        DispatchQueue.concurrentPerform(iterations: count) { index in
            let frame = MageProtocol.makeFrame(
                head: MageProtocol.getHead,
                start: MageProtocol.getStart,
                cmd: UInt8(index % 200),
                payload: [UInt8(index & 0xFF)]
            )
            lock.lock()
            frames.append(frame)
            lock.unlock()
        }

        let parsed = frames.compactMap(MageProtocol.parseDetailedFrame)
        XCTAssertEqual(parsed.count, count)
        XCTAssertEqual(Set(parsed.map(\.sequence)).count, count)
        XCTAssertEqual(Set(parsed.map(\.cmd)).count, 200)
    }

    func testProtocolParserRetainsSequenceAndRejectsBadCRC() {
        let frame = MageProtocol.makeFrame(
            head: MageProtocol.setHead,
            start: MageProtocol.setStart,
            cmd: MageProtocol.Cmd.ledLight.rawValue,
            payload: [0]
        )
        XCTAssertEqual(MageProtocol.parseDetailedFrame(frame)?.payload, [0])

        var corrupted = frame
        corrupted[corrupted.count - 2] ^= 0xFF
        XCTAssertNil(MageProtocol.parseDetailedFrame(corrupted))
    }

    func testReplayContractCoversRecordedKeyboardClasses() throws {
        let letters = Array("abcdefghijklmnopqrstuvwxyz").map(String.init)
        let digits = Array("1234567890").map(String.init)
        let punctuation = ["-", "=", "[", "]", "\\", ";", "'", "`", ",", ".", "/",
                           "_", "+", "{", "}", "|", ":", "\"", "~", "<", ">", "?"]
        let functionKeys = (1...24).map { "f\($0)" }
        let arrows = ["left", "right", "up", "down"]

        for key in letters + digits + punctuation + functionKeys + arrows {
            XCTAssertTrue(
                KeystrokeSimulator.isSupported(key: key, modifiers: ["command"]),
                "expected \(key) to be replayable"
            )
        }
        XCTAssertNoThrow(try KeystrokeSimulator.validate(key: "", modifiers: ["command", "shift"]))
        XCTAssertNoThrow(try KeystrokeSimulator.validate(key: "a", modifiers: ["fn"]))
    }

    func testReplayContractRejectsUnknownKeysAndModifiers() {
        XCTAssertThrowsError(try KeystrokeSimulator.validate(key: "", modifiers: []))
        XCTAssertThrowsError(try KeystrokeSimulator.validate(key: "not-a-key", modifiers: []))
        XCTAssertThrowsError(try KeystrokeSimulator.validate(key: "a", modifiers: ["hyper"]))
        XCTAssertFalse(KeystrokeSimulator.isSupported(key: "not-a-key", modifiers: []))
    }

    func testHIDMatchingIsLimitedToPhysicalMageAndExcludesVirtualKeyboard() {
        let matching = VendorChannel.deviceMatching
        XCTAssertEqual(matching[kIOHIDVendorIDKey] as? Int, VendorChannel.vendorID)
        XCTAssertEqual(matching[kIOHIDProductKey] as? String, VendorChannel.productName)
        XCTAssertNotEqual(VendorChannel.virtualKeyboardVendorID, VendorChannel.vendorID)
    }
}
