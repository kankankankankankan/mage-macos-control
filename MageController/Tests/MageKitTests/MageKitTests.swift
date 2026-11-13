import XCTest
import IOKit.hid
import CoreGraphics
import Darwin
@testable import MageKit

final class MageKitTests: XCTestCase {
    func testVendorRunLoopCleanupUsesOwningThreadAndCloseWaits() {
        let worker = VendorRunLoopWorker()
        let stateLock = NSLock()
        var setupThread: ObjectIdentifier?
        var cleanupThread: ObjectIdentifier?
        let cleanupStarted = DispatchSemaphore(value: 0)
        let allowCleanup = DispatchSemaphore(value: 0)
        let stopReturned = DispatchSemaphore(value: 0)

        worker.start { _ in
            stateLock.lock()
            setupThread = ObjectIdentifier(Thread.current)
            stateLock.unlock()
        }
        DispatchQueue.global().async {
            worker.stopAndWait { _ in
                stateLock.lock()
                cleanupThread = ObjectIdentifier(Thread.current)
                stateLock.unlock()
                cleanupStarted.signal()
                allowCleanup.wait()
            }
            stopReturned.signal()
        }

        XCTAssertEqual(cleanupStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 0.05), .timedOut)
        allowCleanup.signal()
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 1), .success)

        stateLock.lock()
        let observedSetupThread = setupThread
        let observedCleanupThread = cleanupThread
        stateLock.unlock()
        XCTAssertEqual(observedCleanupThread, observedSetupThread)
    }

    func testVendorRunLoopWorkerCanBeRepeatedlyStartedAndClosed() {
        let lock = NSLock()
        var cleanupCount = 0

        for _ in 0..<32 {
            let worker = VendorRunLoopWorker()
            worker.start { _ in }
            worker.stopAndWait { _ in
                lock.lock()
                cleanupCount += 1
                lock.unlock()
            }
        }

        XCTAssertEqual(cleanupCount, 32)
    }

    func testLiveVendorTimeoutCanCloseAndReopen() throws {
        guard ProcessInfo.processInfo.environment["MAGE_LIVE_HID_TEST"] == "1" else {
            throw XCTSkip("requires an attached SNOWSKY MAGE and explicit opt-in")
        }

        let channel = VendorChannel()
        var timeoutCount = 0
        for _ in 0..<8 {
            XCTAssertTrue(try channel.open(), "SNOWSKY MAGE was not found")
            do {
                _ = try channel.send(cmd: .ledLight, timeout: 0)
            } catch VendorChannel.Error.timeout {
                timeoutCount += 1
            } catch {
                XCTFail("unexpected live HID error: \(error)")
            }
            channel.close()
        }

        XCTAssertGreaterThan(timeoutCount, 0, "the zero-timeout path was not exercised")
        XCTAssertFalse(channel.isConnected)
    }

    func testLiveVendorAcceptsIndependentResponseSequence() throws {
        guard ProcessInfo.processInfo.environment["MAGE_LIVE_HID_TEST"] == "1" else {
            throw XCTSkip("requires an attached SNOWSKY MAGE and explicit opt-in")
        }

        let channel = VendorChannel()
        XCTAssertTrue(try channel.open(), "SNOWSKY MAGE was not found")
        let led = try channel.send(cmd: .ledLight)
        let mic = try channel.send(cmd: .micSwitch)
        channel.close()

        XCTAssertEqual(led.count, 1)
        XCTAssertEqual(mic.count, 1)
        XCTAssertFalse(channel.isConnected)
    }

    func testVendorBuildsOneShot71SetReport() throws {
        MageProtocol.resetSeq()
        let output = VendorChannel.makeOutputReport(
            cmd: .channel71Switch, payload: [1], set: true
        )

        XCTAssertEqual(output.report.count, 64)
        XCTAssertEqual(output.report.first, 7)
        let frame = try XCTUnwrap(
            MageProtocol.parseDetailedFrame(Array(output.report.dropFirst()))
        )
        XCTAssertEqual(frame.head, MageProtocol.setHead)
        XCTAssertEqual(frame.start, MageProtocol.setStart)
        XCTAssertEqual(frame.sequence, output.sequence)
        XCTAssertEqual(frame.cmd, MageProtocol.Cmd.channel71Switch.rawValue)
        XCTAssertEqual(frame.payload, [1])
    }

    func testVendorErrorsExposeActionableDescriptions() {
        XCTAssertEqual(VendorChannel.Error.deviceNotFound.localizedDescription,
                       "未发现 SNOWSKY MAGE")
        XCTAssertEqual(VendorChannel.Error.timeout.localizedDescription,
                       "MAGE HID 响应超时")
        XCTAssertTrue(
            VendorChannel.Error.writeFailed(kIOReturnError).localizedDescription
                .contains("命令写入失败")
        )
    }

    func testLiveUnavailableVendorCanRepeatedlyOpenAndClose() throws {
        guard ProcessInfo.processInfo.environment["MAGE_LIVE_HID_UNAVAILABLE_TEST"] == "1" else {
            throw XCTSkip("requires the attached SNOWSKY MAGE to be seized by a separate helper")
        }

        let channel = VendorChannel()
        for _ in 0..<8 {
            let opened: Bool
            do {
                opened = try channel.open()
            } catch VendorChannel.Error.openFailed {
                // Exclusive access may be reported while opening the manager or the device.
                opened = false
            } catch {
                XCTFail("unexpected unavailable-device error: \(error)")
                opened = false
            }
            XCTAssertFalse(opened, "seized device unexpectedly opened")
            channel.close()
            XCTAssertFalse(channel.isConnected)
        }
    }

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

        let emptyFrame = MageProtocol.makeFrame(
            head: MageProtocol.getHead,
            start: MageProtocol.getStart,
            cmd: MageProtocol.Cmd.deviceName.rawValue,
            payload: []
        )
        XCTAssertEqual(MageProtocol.parseDetailedFrame(emptyFrame)?.payload, [])

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

    func testForwardDeleteAndModifierAliasesProduceVirtualKeyboardReport() {
        var reports = [[UInt8]]()
        let keyboard = VirtualKeyboard { report in
            reports.append(report)
            return kIOReturnSuccess
        }

        let result = KeystrokeSimulator.postUsingVirtualKeyboard(
            key: "forwarddelete", modifiers: ["lcmd", "rshift"],
            keyboard: keyboard, holdMicros: 0
        )

        guard case .success = result else {
            return XCTFail("expected successful report delivery, got \(result)")
        }
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[0][0], 0x08 | 0x20)
        XCTAssertEqual(reports[0][2], 0x4C)
        XCTAssertEqual(reports[1], [UInt8](repeating: 0, count: 8))
    }

    func testModifierAliasesSurviveLegacyFallback() {
        let flags = KeystrokeSimulator.legacyFlags(
            for: ["lcmd", "lctl", "lshift", "lopt", "rcmd", "rctl", "rshift", "ropt"]
        )
        XCTAssertTrue(flags.contains(.maskCommand))
        XCTAssertTrue(flags.contains(.maskControl))
        XCTAssertTrue(flags.contains(.maskShift))
        XCTAssertTrue(flags.contains(.maskAlternate))
    }

    func testVirtualKeyboardReportFailurePropagates() {
        let pressFailureKeyboard = VirtualKeyboard { _ in kIOReturnError }

        let pressResult = KeystrokeSimulator.postUsingVirtualKeyboard(
            key: "a", modifiers: ["command"], keyboard: pressFailureKeyboard, holdMicros: 0
        )

        guard case .failure(.eventDeliveryFailed(let pressReason)) = pressResult else {
            return XCTFail("expected press delivery failure, got \(pressResult)")
        }
        XCTAssertFalse(pressReason.isEmpty)

        var reportCount = 0
        let releaseFailureKeyboard = VirtualKeyboard { _ in
            reportCount += 1
            return reportCount == 1 ? kIOReturnSuccess : kIOReturnError
        }
        let releaseResult = KeystrokeSimulator.postUsingVirtualKeyboard(
            key: "a", modifiers: ["command"], keyboard: releaseFailureKeyboard, holdMicros: 0
        )
        guard case .failure(.eventDeliveryFailed(let releaseReason)) = releaseResult else {
            return XCTFail("expected release delivery failure, got \(releaseResult)")
        }
        XCTAssertFalse(releaseReason.isEmpty)
        XCTAssertEqual(reportCount, 2)
    }

    func testHIDMatchingIsLimitedToPhysicalMageAndExcludesVirtualKeyboard() {
        let matching = VendorChannel.deviceMatching
        XCTAssertEqual(matching[kIOHIDVendorIDKey] as? Int, VendorChannel.vendorID)
        XCTAssertEqual(matching[kIOHIDProductKey] as? String, VendorChannel.productName)
        XCTAssertNotEqual(VendorChannel.virtualKeyboardVendorID, VendorChannel.vendorID)
    }

    func testHelperLaunchOptionsUseExplicitAbsolutePaths() throws {
        let options = try HelperLaunchOptions(
            arguments: [
                "--config", "/Users/test/.config/mage-controller/config.json",
                "--pid-file", "/Users/test/Library/Application Support/MAGE Controller/helper.pid",
                "--status-file", "/Users/test/Library/Application Support/MAGE Controller/status.json",
            ],
            homeDirectoryURL: URL(fileURLWithPath: "/fallback")
        )

        XCTAssertEqual(options.configURL.path, "/Users/test/.config/mage-controller/config.json")
        XCTAssertEqual(options.processArguments.count, 6)
        XCTAssertThrowsError(try HelperLaunchOptions(
            arguments: ["--config", "relative/config.json"],
            homeDirectoryURL: URL(fileURLWithPath: "/fallback")
        ))
    }

    func testProcessInspectorVerifiesPIDUIDAndExecutablePath() throws {
        let pid = getpid()
        let identity = try XCTUnwrap(HelperProcessInspector.identity(for: pid))
        XCTAssertEqual(identity.pid, pid)
        XCTAssertEqual(identity.uid, getuid())
        XCTAssertTrue(HelperProcessInspector.matches(
            pid: pid,
            executableURL: identity.executableURL,
            uid: getuid()
        ))
        XCTAssertFalse(HelperProcessInspector.matches(
            pid: pid,
            executableURL: URL(fileURLWithPath: "/not/the/current/executable"),
            uid: getuid()
        ))
        XCTAssertTrue(
            try HelperProcessInspector.identities(named: identity.executableURL.lastPathComponent)
                .contains(where: { $0.pid == pid })
        )
    }

    func testProcessInspectorFindsAnExecutableAtALaterPIDIndex() throws {
        let pids = try HelperProcessInspector.allProcessIDs()
        XCTAssertGreaterThan(pids.count, 120)

        var candidate: (index: Int, identity: HelperProcessIdentity)?
        for index in stride(from: pids.count - 1, through: 100, by: -1) {
            if let identity = HelperProcessInspector.identity(for: pids[index]) {
                candidate = (index, identity)
                break
            }
        }
        let selected = try XCTUnwrap(candidate)
        XCTAssertGreaterThanOrEqual(selected.index, 100)

        let identities = try HelperProcessInspector.identities(
            named: selected.identity.executableURL.lastPathComponent
        )
        XCTAssertTrue(identities.contains(where: { $0.pid == selected.identity.pid }))
    }

    func testProcessInspectorRetriesWhenPIDBufferIsExactlyFull() throws {
        var bufferCalls = 0
        let expected: [pid_t] = [41, 42, 43]

        let pids = try HelperProcessInspector.allProcessIDs { buffer, byteCount in
            guard let buffer else { return 1 }
            bufferCalls += 1
            let capacity = Int(byteCount) / MemoryLayout<pid_t>.stride
            let storage = buffer.bindMemory(to: pid_t.self, capacity: capacity)

            if bufferCalls == 1 {
                for index in 0..<capacity { storage[index] = pid_t(index + 1) }
                return Int32(capacity)
            }
            for (index, pid) in expected.enumerated() { storage[index] = pid }
            return Int32(expected.count)
        }

        XCTAssertEqual(pids, expected)
        XCTAssertEqual(bufferCalls, 2)
    }

    func testProcessInspectorRejectsPersistentlyFullPIDBuffers() {
        XCTAssertThrowsError(try HelperProcessInspector.allProcessIDs(
            maxAttempts: 3
        ) { buffer, byteCount in
            guard let buffer else { return 1 }
            let capacity = Int(byteCount) / MemoryLayout<pid_t>.stride
            let storage = buffer.bindMemory(to: pid_t.self, capacity: capacity)
            for index in 0..<capacity { storage[index] = pid_t(index + 1) }
            return Int32(capacity)
        }) { error in
            XCTAssertEqual(
                error as? HelperProcessInspector.EnumerationError,
                .processListKeptGrowing
            )
        }
    }

    func testConfigStoreReportsAtomicWriteFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mage-config-\(UUID().uuidString)", isDirectory: true)
        let configURL = root.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try KeyConfigStore(url: configURL).save(KeyConfig()))
    }

    func testHelperStopPreferenceFailureKeepsDiskPreferenceVisible() {
        let failed = HelperStopPreferenceOutcome(persistenceSucceeded: false)
        XCTAssertTrue(failed.helperEnabled)
        XCTAssertTrue(failed.message?.contains("关闭偏好未写入") == true)
        XCTAssertTrue(failed.message?.contains("下次启动") == true)

        let succeeded = HelperStopPreferenceOutcome(persistenceSucceeded: true)
        XCTAssertFalse(succeeded.helperEnabled)
        XCTAssertNil(succeeded.message)
    }

    func testHelperStatusPresentationUsesTheRelevantFailurePriority() {
        let bindingFailure = "配置未保存：测试写入失败"
        let stopFailure = HelperStopPreferenceOutcome.persistenceFailureMessage

        XCTAssertEqual(HelperStatusPresentation.text(
            bindingMessage: bindingFailure,
            helperMessage: stopFailure,
            transitioning: false,
            running: false,
            enabled: true
        ), stopFailure)

        XCTAssertEqual(HelperStatusPresentation.text(
            bindingMessage: bindingFailure,
            helperMessage: "按键拦截未运行，请重试",
            transitioning: false,
            running: false,
            enabled: true
        ), bindingFailure)
    }

    func testInterceptorReportsUnsupportedPlaybackFailure() {
        let interceptor = KeyInterceptor()
        var received: String?
        interceptor.onActionError = { received = $0 }

        interceptor.run(action: .keystroke(key: "not-a-key", modifiers: []))

        XCTAssertNotNil(received)
        XCTAssertTrue(received?.contains("不支持回放的按键") == true)
    }
}
