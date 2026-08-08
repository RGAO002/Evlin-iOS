import Foundation
import XCTest

final class MeteringTargetMembershipTests: XCTestCase {
    // MARK: - Push-target metering surface (#96)
    //
    // The NSE runs `MeteringProductionComposition.recoverFromSharedConfiguration`
    // on a silent wake so a force-quit kid device can self-heal without anyone
    // opening the app (2026-08-05, device-verified). That pulled the earned
    // metering stack — store, callback, recovery driver, dated routes, delivery,
    // composition — into EvlinPushApplier. These assertions therefore encode the
    // NEW rule: those files ARE push members. What stays out is owner-side
    // execution (parent/policy write paths), asserted below.

    private enum Target: String {
        case app = "Evlin iOS"
        case deviceActivityMonitor = "EvlinDeviceActivityMonitor"
        case push = "EvlinPushApplier"
    }

    func testRuntimeInfrastructureBelongsToAppMonitorAndPushTargets() throws {
        let project = try projectSource()

        XCTAssertTrue(isMember("Services/MeteringRuntimeInfrastructure.swift", of: .app, in: project))
        XCTAssertTrue(isMember("Services/MeteringRuntimeInfrastructure.swift", of: .deviceActivityMonitor, in: project))
        XCTAssertTrue(isMember("Services/MeteringRuntimeInfrastructure.swift", of: .push, in: project))
    }

    func testCenterBelongsToAppMonitorAndPushTargets() throws {
        let project = try projectSource()

        XCTAssertTrue(isMember("Services/MeteringDeviceActivityCenter.swift", of: .app, in: project))
        XCTAssertTrue(isMember("Services/MeteringDeviceActivityCenter.swift", of: .deviceActivityMonitor, in: project))
        XCTAssertTrue(isMember("Services/MeteringDeviceActivityCenter.swift", of: .push, in: project))
    }

    func testEpochWireBelongsToAppMonitorAndPushTargets() throws {
        let project = try projectSource()

        XCTAssertTrue(isMember("Services/MeteringEpochWire.swift", of: .app, in: project))
        XCTAssertTrue(isMember("Services/MeteringEpochWire.swift", of: .deviceActivityMonitor, in: project))
        XCTAssertTrue(isMember("Services/MeteringEpochWire.swift", of: .push, in: project))
    }

    func testDeviceEpochStoreBelongsToAppMonitorAndPushTargets() throws {
        let project = try projectSource()

        XCTAssertTrue(isMember("Services/DeviceEpochStore.swift", of: .app, in: project))
        XCTAssertTrue(isMember("Services/DeviceEpochStore.swift", of: .deviceActivityMonitor, in: project))
        XCTAssertTrue(isMember("Services/DeviceEpochStore.swift", of: .push, in: project))
    }

    func testDatedRouteServicesBelongToAppMonitorAndPushTargets() throws {
        let project = try projectSource()
        let paths = [
            "Services/MeteringCallbackRoute.swift",
            "Services/MeteringDatedSchedule.swift",
            "Services/DatedRouteInstaller.swift",
        ]

        for path in paths {
            XCTAssertTrue(isMember(path, of: .app, in: project), path)
            XCTAssertTrue(isMember(path, of: .deviceActivityMonitor, in: project), path)
            XCTAssertTrue(isMember(path, of: .push, in: project), path)
        }
    }

    func testEpochDeliveryBelongsToAppMonitorAndPushTargets() throws {
        let project = try projectSource()

        XCTAssertTrue(isMember("Services/MeteringEpochDelivery.swift", of: .app, in: project))
        XCTAssertTrue(isMember("Services/MeteringEpochDelivery.swift", of: .deviceActivityMonitor, in: project))
        XCTAssertTrue(isMember("Services/MeteringEpochDelivery.swift", of: .push, in: project))
    }

    func testEarnedMeteringCallbackBelongsToAppMonitorAndPushTargets() throws {
        let project = try projectSource()

        XCTAssertTrue(isMember("Services/EarnedMeteringCallback.swift", of: .app, in: project))
        XCTAssertTrue(isMember("Services/EarnedMeteringCallback.swift", of: .deviceActivityMonitor, in: project))
        XCTAssertTrue(isMember("Services/EarnedMeteringCallback.swift", of: .push, in: project))
    }

    func testV2RecoveryBelongsToAppMonitorAndPushTargets() throws {
        let project = try projectSource()

        XCTAssertTrue(isMember("Services/EarnedMeteringRecoveryDriver.swift", of: .app, in: project))
        XCTAssertTrue(isMember("Services/EarnedMeteringRecoveryDriver.swift", of: .deviceActivityMonitor, in: project))
        XCTAssertTrue(isMember("Services/EarnedMeteringRecoveryDriver.swift", of: .push, in: project))
    }

    func testProductionCompositionBelongsToAppMonitorAndPushTargets() throws {
        let project = try projectSource()

        XCTAssertTrue(isMember("Services/MeteringProductionComposition.swift", of: .app, in: project))
        XCTAssertTrue(isMember("Services/MeteringProductionComposition.swift", of: .deviceActivityMonitor, in: project))
        XCTAssertTrue(isMember("Services/MeteringProductionComposition.swift", of: .push, in: project))
    }

    /// The readback client is a dependency of the recovery driver, so the NSE's
    /// self-heal leg (#96) carries it too.
    func testPolicyOwnerReadbackCompilesEverywhereRecoveryRuns() throws {
        let project = try projectSource()

        XCTAssertTrue(isMember("Services/MeteringPolicyOwnerReadbackClient.swift", of: .app, in: project))
        XCTAssertTrue(isMember("Services/MeteringPolicyOwnerReadbackClient.swift", of: .deviceActivityMonitor, in: project))
        XCTAssertTrue(isMember("Services/MeteringPolicyOwnerReadbackClient.swift", of: .push, in: project))
    }

    func testProcessEntriesBelongToAppAndMonitorButNotPushTargets() throws {
        let project = try projectSource()

        XCTAssertTrue(isMember("Services/MeteringProcessEntries.swift", of: .app, in: project))
        XCTAssertTrue(isMember("Services/MeteringProcessEntries.swift", of: .deviceActivityMonitor, in: project))
        XCTAssertFalse(isMember("Services/MeteringProcessEntries.swift", of: .push, in: project))
    }

    func testPhase5OwnerExecutionStaysOutOfPushTarget() throws {
        let project = try projectSource()
        // Process entries own the app-side lifecycle wiring; the NSE composes
        // its own recovery entry instead, so these must never reach push.
        let ownerOnly = [
            "Services/MeteringProcessEntries.swift",
            "Services/AppLimitOwnerReadbackClient.swift",
        ]
        for path in ownerOnly {
            XCTAssertTrue(isMember(path, of: .app, in: project), path)
            XCTAssertFalse(isMember(path, of: .push, in: project), path)
        }
        XCTAssertTrue(isMember("Services/AppLimitProductionComposition.swift", of: .push, in: project))
        XCTAssertTrue(isMember("Services/MeteringEpochWire.swift", of: .push, in: project))
    }

    func testV30EncoderStaysAppOnly() throws {
        let project = try projectSource()

        XCTAssertTrue(isMember("Services/MeteringV30ScenarioEncoder.swift", of: .app, in: project))
        XCTAssertFalse(isMember("Services/MeteringV30ScenarioEncoder.swift", of: .deviceActivityMonitor, in: project))
        XCTAssertFalse(isMember("Services/MeteringV30ScenarioEncoder.swift", of: .push, in: project))
    }

    func testEarnedShieldEffectStoreClosureBelongsToAppMonitorAndPushTargets() throws {
        let project = try projectSource()
        let paths = [
            "Services/EarnedShieldEffectStore.swift",
            "Models/ShieldRecord.swift",
            "Models/ShieldTier.swift",
            "Services/ShieldSourceLogic.swift",
            "Services/ActiveLockPersistenceLock.swift"
        ]

        for path in paths {
            XCTAssertTrue(isMember(path, of: .app, in: project), path)
            XCTAssertTrue(isMember(path, of: .deviceActivityMonitor, in: project), path)
            XCTAssertTrue(isMember(path, of: .push, in: project), path)
        }
    }

    func testActiveLockStoreStaysOutOfMonitorTarget() throws {
        let project = try projectSource()
        let appOnlyPaths = [
            "Services/ActiveLockStore.swift",
            "Services/ActiveLockStoreTypes.swift",
        ]

        for path in appOnlyPaths {
            XCTAssertTrue(isMember(path, of: .app, in: project), path)
            XCTAssertFalse(isMember(path, of: .deviceActivityMonitor, in: project), path)
            XCTAssertTrue(isMember(path, of: .push, in: project), path)
        }
    }

    private func projectSource() throws -> String {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Evlin iOS.xcodeproj/project.pbxproj")
        return try String(contentsOf: projectURL, encoding: .utf8)
    }

    private func isMember(_ path: String, of target: Target, in project: String) -> Bool {
        guard target != .app else { return true }
        let marker = "Exceptions for \"Evlin iOS\" folder in \"\(target.rawValue)\" target"
        guard let exceptionStart = project.range(of: marker),
              let exceptionEnd = project.range(of: "\n\t\t};", range: exceptionStart.upperBound..<project.endIndex)
        else {
            XCTFail("missing synchronized-group exception set for \(target.rawValue)")
            return false
        }

        return project[exceptionStart.lowerBound..<exceptionEnd.lowerBound].contains(path)
    }
}
