import Foundation
import XCTest

final class MeteringTargetMembershipTests: XCTestCase {
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

    func testCenterBelongsToAppAndMonitorButNotPushTargets() throws {
        let project = try projectSource()

        XCTAssertTrue(isMember("Services/MeteringDeviceActivityCenter.swift", of: .app, in: project))
        XCTAssertTrue(isMember("Services/MeteringDeviceActivityCenter.swift", of: .deviceActivityMonitor, in: project))
        XCTAssertFalse(isMember("Services/MeteringDeviceActivityCenter.swift", of: .push, in: project))
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

    func testDatedRouteServicesBelongToAppAndMonitorButNotPushTargets() throws {
        let project = try projectSource()
        let paths = [
            "Services/MeteringCallbackRoute.swift",
            "Services/MeteringDatedSchedule.swift",
            "Services/DatedRouteInstaller.swift",
        ]

        for path in paths {
            XCTAssertTrue(isMember(path, of: .app, in: project), path)
            XCTAssertTrue(isMember(path, of: .deviceActivityMonitor, in: project), path)
            XCTAssertFalse(isMember(path, of: .push, in: project), path)
        }
    }

    func testEpochDeliveryBelongsToAppAndMonitorButNotPushTargets() throws {
        let project = try projectSource()

        XCTAssertTrue(isMember("Services/MeteringEpochDelivery.swift", of: .app, in: project))
        XCTAssertTrue(isMember("Services/MeteringEpochDelivery.swift", of: .deviceActivityMonitor, in: project))
        XCTAssertFalse(isMember("Services/MeteringEpochDelivery.swift", of: .push, in: project))
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
