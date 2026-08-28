import XCTest
import SwiftUI
import UIKit
import CoreGraphics
@testable import Evlin_iOS

private enum SnapshotFailure: Error {
    case unpinnedEnvironment
    case missingCGImage
    case imageNormalizationFailed
    case pngEncodingFailed
}

private struct SnapshotEnvironment {
    let folder: String
    let deviceName: String
    let modelIdentifier: String
    let logicalSize: CGSize

    static func current(file: StaticString = #filePath, line: UInt = #line) throws -> Self {
        let env = ProcessInfo.processInfo.environment
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let buildMatches = ProcessInfo.processInfo.operatingSystemVersionString.contains("23D8133")
        let localeMatches = Locale.current.identifier.hasPrefix("en_US")

        XCTAssertEqual(version.majorVersion, 26, file: file, line: line)
        XCTAssertEqual(version.minorVersion, 3, file: file, line: line)
        XCTAssertEqual(version.patchVersion, 1, file: file, line: line)
        XCTAssertTrue(
            buildMatches,
            "Expected iOS build 23D8133",
            file: file,
            line: line
        )
        XCTAssertTrue(localeMatches, file: file, line: line)

        guard version.majorVersion == 26,
              version.minorVersion == 3,
              version.patchVersion == 1,
              buildMatches,
              localeMatches else {
            throw SnapshotFailure.unpinnedEnvironment
        }

        let simulatorName = env["SIMULATOR_DEVICE_NAME"] ?? ""
        switch env["SIMULATOR_MODEL_IDENTIFIER"] {
        case "iPhone18,1" where simulatorName.hasSuffix("iPhone 17 Pro"):
            return .init(
                folder: "iPhone17Pro-iOS26.3.1-23D8133-en_US-light-AX2",
                deviceName: "iPhone 17 Pro",
                modelIdentifier: "iPhone18,1",
                logicalSize: CGSize(width: 402, height: 874)
            )
        case "iPad15,7" where simulatorName.hasSuffix("iPad (A16)"):
            return .init(
                folder: "iPadA16-iOS26.3.1-23D8133-en_US-light-AX2",
                deviceName: "iPad (A16)",
                modelIdentifier: "iPad15,7",
                logicalSize: CGSize(width: 820, height: 1180)
            )
        default:
            XCTFail(
                "Unpinned snapshot destination: \(env["SIMULATOR_DEVICE_NAME"] ?? "nil") / \(env["SIMULATOR_MODEL_IDENTIFIER"] ?? "nil")",
                file: file,
                line: line
            )
            throw SnapshotFailure.unpinnedEnvironment
        }
    }
}

private struct RGBAImage {
    let width: Int
    let height: Int
    var bytes: [UInt8]
}

private struct SnapshotDiff {
    let changedPixels: Int
    let totalPixels: Int
    let heatMap: UIImage

    var ratio: Double {
        guard totalPixels > 0 else { return 1 }
        return Double(changedPixels) / Double(totalPixels)
    }
}

private struct ProfileSnapshotCase {
    let name: String
    let view: AnyView
    let reflectionStore: ParentReflectionFixtureStore
    let iPhoneVerticalScrollOffset: CGFloat?

    init(
        name: String,
        view: AnyView,
        reflectionStore: ParentReflectionFixtureStore,
        iPhoneVerticalScrollOffset: CGFloat? = nil
    ) {
        self.name = name
        self.view = view
        self.reflectionStore = reflectionStore
        self.iPhoneVerticalScrollOffset = iPhoneVerticalScrollOffset
    }

    func verticalScrollOffset(for environment: SnapshotEnvironment) -> CGFloat? {
        environment.modelIdentifier == "iPhone18,1" ? iPhoneVerticalScrollOffset : nil
    }
}

@MainActor
final class ProfileSnapshotTests: XCTestCase {
    private static let changedPixelRatioThreshold = 0.0005
    private static let childID = "10000000-0000-0000-0000-000000000001"
    private static let deviceAID = "20000000-0000-0000-0000-000000000001"
    private static let deviceBID = "20000000-0000-0000-0000-000000000002"
    private static let appRuleID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!

    func test_profilePhaseZeroSnapshots() throws {
        let environment = try SnapshotEnvironment.current()
        assertPinnedScreenSize(environment.logicalSize)

        let cases = try snapshotCases()
        XCTAssertEqual(
            cases.map(\.name),
            [
                "A-independent-bars",
                "B-task-pause",
                "C-earned-exhausted",
                "D-mixed-manual",
                "E-reflection",
                "F-exact-app-profile",
                "F-exact-app-sheet",
            ]
        )

        for snapshotCase in cases {
            let image = try render(
                snapshotCase.view,
                size: environment.logicalSize,
                reflectionStore: snapshotCase.reflectionStore,
                verticalScrollOffset: snapshotCase.verticalScrollOffset(for: environment)
            )
            try assertSnapshot(
                named: snapshotCase.name,
                image: image,
                environment: environment
            )
        }
    }

    func test_debugFixtureSuppressesLiveRuntimeEffectsAfterAppearance() throws {
        let environment = try SnapshotEnvironment.current()
        assertPinnedScreenSize(environment.logicalSize)

        let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000009001")!
        let seededTask = TaskItem(
            id: 9_001,
            title: "Snapshot fixture task 9001",
            state: .pending,
            iconSystemName: nil
        )
        let seededDevice = DeviceItem(
            dto: EnrolledDeviceDTO(
                device_id: deviceID.uuidString,
                mode: "child",
                label: "Snapshot fixture device 9001",
                device_model: "iPhone18,1",
                platform: "ios",
                os_version: "26.3.1",
                display: nil,
                last_seen_at: nil,
                online: true,
                is_self: false
            )
        )
        let seededFixture = fixture(tasks: [seededTask], devices: [seededDevice])
        let emptyFixture = fixture(tasks: [], devices: [])

        let seededPixels = try rgbaImage(
            from: render(ProfileView(snapshotFixture: seededFixture), size: environment.logicalSize)
        )
        let emptyPixels = try rgbaImage(
            from: render(ProfileView(snapshotFixture: emptyFixture), size: environment.logicalSize)
        )

        XCTAssertTrue(isNonBlank(seededPixels))
        XCTAssertTrue(isNonBlank(emptyPixels))
        XCTAssertEqual(seededPixels.width, emptyPixels.width)
        XCTAssertEqual(seededPixels.height, emptyPixels.height)
        XCTAssertGreaterThanOrEqual(
            differingPixelRatio(seededPixels, emptyPixels),
            0.01,
            "Seeded fixture content did not survive ProfileView.onAppear."
        )
    }

    private func snapshotCases() throws -> [ProfileSnapshotCase] {
        let child = snapshotChild()
        let devices = snapshotDevices()
        let sharedSummary = try decodeSummary(Self.sharedSummaryJSON)
        let taskPauseSummary = try decodeSummary(Self.taskPauseSummaryJSON)
        let exhaustedSummary = try decodeSummary(Self.exhaustedSummaryJSON)
        let pendingTask = TaskItem(
            id: 2_001,
            title: "Finish reading chapter 4",
            state: .pending,
            iconSystemName: nil,
            category: "Reading",
            description: "Read chapter 4 and mark the task complete."
        )

        let aStore = ParentReflectionFixtureStore()
        let bStore = ParentReflectionFixtureStore()
        let cStore = ParentReflectionFixtureStore()
        let dStore = ParentReflectionFixtureStore()
        let eStore = ParentReflectionFixtureStore()
        eStore.simulateAssignment(childId: "liam")
        let fProfileStore = ParentReflectionFixtureStore()
        let fSheetStore = ParentReflectionFixtureStore()

        let aFixture = profileFixture(
            child: child,
            tasks: [],
            devices: devices,
            localStatus: .unlocked,
            manualLockState: .unlocked,
            automaticCoveringSources: [],
            earnedSummary: sharedSummary
        )
        let bFixture = profileFixture(
            child: child,
            tasks: [pendingTask],
            devices: devices,
            localStatus: .locked,
            manualLockState: .unlocked,
            automaticCoveringSources: ["task_pause"],
            earnedSummary: taskPauseSummary
        )
        let cFixture = profileFixture(
            child: child,
            tasks: [],
            devices: devices,
            localStatus: .locked,
            manualLockState: .unlocked,
            automaticCoveringSources: ["earned_time"],
            earnedSummary: exhaustedSummary
        )
        let dFixture = profileFixture(
            child: child,
            tasks: [],
            devices: devices,
            localStatus: .locked,
            manualLockState: .mixed,
            automaticCoveringSources: [],
            earnedSummary: sharedSummary
        )
        let eFixture = profileFixture(
            child: .previewLiam,
            tasks: [],
            devices: devices,
            localStatus: .locked,
            manualLockState: .unlocked,
            automaticCoveringSources: ["reflection"],
            earnedSummary: sharedSummary,
            profileTab: .overview
        )
        let fFixture = profileFixture(
            child: child,
            tasks: [],
            devices: devices,
            localStatus: .unlocked,
            manualLockState: .unlocked,
            automaticCoveringSources: [],
            earnedSummary: sharedSummary
        )
        let instagram = DeviceAppItem(
            id: "instagram",
            name: "Instagram",
            iconSystemName: "camera",
            brandColor: Color(hex: 0xE1306C),
            bgColor: .white,
            enabled: true,
            usedMin: 12,
            limitMin: 30,
            artworkURL: nil,
            bundleID: "com.burbn.instagram",
            ruleID: Self.appRuleID
        )
        let appSheet = DeviceAppsSheet(
            device: devices[0],
            childId: child.id,
            fixtureApps: [instagram]
        )

        return [
            .init(
                name: "A-independent-bars",
                view: AnyView(ProfileView(snapshotFixture: aFixture)),
                reflectionStore: aStore,
                iPhoneVerticalScrollOffset: 420
            ),
            .init(name: "B-task-pause", view: AnyView(ProfileView(snapshotFixture: bFixture)), reflectionStore: bStore),
            .init(name: "C-earned-exhausted", view: AnyView(ProfileView(snapshotFixture: cFixture)), reflectionStore: cStore),
            .init(name: "D-mixed-manual", view: AnyView(ProfileView(snapshotFixture: dFixture)), reflectionStore: dStore),
            .init(name: "E-reflection", view: AnyView(ProfileView(snapshotFixture: eFixture)), reflectionStore: eStore),
            .init(name: "F-exact-app-profile", view: AnyView(ProfileView(snapshotFixture: fFixture)), reflectionStore: fProfileStore),
            .init(name: "F-exact-app-sheet", view: AnyView(appSheet), reflectionStore: fSheetStore),
        ]
    }

    private func snapshotChild() -> ChildProfile {
        ChildProfile(
            id: Self.childID,
            name: "Liam",
            age: 12,
            avatarURL: nil,
            accentColor: .evChildLiam,
            status: .unlocked,
            timeLeft: "35m",
            timePct: 35.0 / 120.0,
            subtitle: ""
        )
    }

    private func snapshotDevices() -> [DeviceItem] {
        [
            DeviceItem(
                dto: EnrolledDeviceDTO(
                    device_id: Self.deviceAID,
                    mode: "child",
                    label: "Liam's iPhone",
                    device_model: "iPhone18,1",
                    platform: "ios",
                    os_version: "26.3.1",
                    display: "iPhone 17 Pro - iOS 26",
                    last_seen_at: nil,
                    online: true,
                    is_self: false
                )
            ),
            DeviceItem(
                dto: EnrolledDeviceDTO(
                    device_id: Self.deviceBID,
                    mode: "child",
                    label: "Liam's iPad",
                    device_model: "iPad15,7",
                    platform: "ios",
                    os_version: "26.3.1",
                    display: "iPad (A16) - iOS 26",
                    last_seen_at: nil,
                    online: true,
                    is_self: false
                )
            ),
        ]
    }

    private func profileFixture(
        child: ChildProfile,
        tasks: [TaskItem],
        devices: [DeviceItem],
        localStatus: ChildProfile.Status,
        manualLockState: ManualLockAggregateState,
        automaticCoveringSources: [String],
        earnedSummary: APIClient.EarnedSummaryDTO?,
        profileTab: ProfileView.ProfileSubTab = .overview
    ) -> ProfileView.ProfileSnapshotFixture_v1 {
        ProfileView.ProfileSnapshotFixture_v1(
            child: child,
            tasks: tasks,
            devices: devices,
            rules: ProfileMockData.rules(for: child.id, dailyLimitMinutes: 120),
            dailyLimitMinutes: 120,
            localStatus: localStatus,
            manualLockState: manualLockState,
            automaticCoveringSources: automaticCoveringSources,
            masterLockPresentation: snapshotMasterLockPresentation(
                child: child,
                devices: devices,
                manualLockState: manualLockState,
                automaticCoveringSources: automaticCoveringSources
            ),
            earnedSummary: earnedSummary,
            profileTab: profileTab
        )
    }

    private func snapshotMasterLockPresentation(
        child: ChildProfile,
        devices: [DeviceItem],
        manualLockState: ManualLockAggregateState,
        automaticCoveringSources: [String]
    ) -> MasterLockPresentation {
        guard let childID = UUID(uuidString: child.id) else { return .updating }
        let projectedDevices = devices.compactMap { device -> MasterLockDeviceProjection? in
            guard let deviceID = device.deviceUUID else { return nil }
            let position = devices.firstIndex(where: { $0.id == device.id }) ?? 0
            let manualLocked: Bool = switch manualLockState {
            case .locked: true
            case .mixed: position == 0
            case .unlocked, .pending: false
            }
            return MasterLockDeviceProjection(
                childDeviceID: deviceID,
                deviceName: device.name,
                identityVerified: true,
                manualAllApps: manualLocked,
                earnedExhausted: automaticCoveringSources.contains("earned_time"),
                taskIncomplete: automaticCoveringSources.contains("task_pause"),
                deviceLimitActive: false,
                limitedAppIDs: [],
                limitedLegacyScopeIDs: [],
                reflectionActive: false,
                deliveryState: .confirmed
            )
        }
        let projection = MasterLockProjection(
            childProfileID: childID,
            snapshotDigest: "profile-snapshot",
            overrideRevision: 7,
            overrideExpiresAt: nil,
            devices: projectedDevices
        )
        return MasterLockPresentation.reduce(projection: projection)
    }

    private func fixture(
        tasks: [TaskItem],
        devices: [DeviceItem]
    ) -> ProfileView.ProfileSnapshotFixture_v1 {
        profileFixture(
            child: .previewLiam,
            tasks: tasks,
            devices: devices,
            localStatus: .unlocked,
            manualLockState: .unlocked,
            automaticCoveringSources: [],
            earnedSummary: nil
        )
    }

    private func decodeSummary(_ json: String) throws -> APIClient.EarnedSummaryDTO {
        try JSONDecoder().decode(APIClient.EarnedSummaryDTO.self, from: Data(json.utf8))
    }

    private func assertPinnedScreenSize(
        _ expectedSize: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(UIScreen.main.bounds.size, expectedSize, file: file, line: line)
    }

    private func render<V: View>(
        _ view: V,
        size: CGSize,
        reflectionStore suppliedReflectionStore: ParentReflectionFixtureStore? = nil,
        verticalScrollOffset: CGFloat? = nil
    ) throws -> UIImage {
        assertPinnedScreenSize(size)
        guard UIScreen.main.bounds.size == size else {
            throw SnapshotFailure.unpinnedEnvironment
        }

        let apiClient = APIClient(baseURL: "https://snapshot.invalid")
        let familyStore = FamilyStore(api: apiClient)
        let reflectionStore = suppliedReflectionStore ?? ParentReflectionFixtureStore()
        let previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: \.isKeyWindow)
        let rootView = NavigationStack {
            view
        }
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.dynamicTypeSize, .accessibility2)
        .preferredColorScheme(.light)
        .environmentObject(apiClient)
        .environment(familyStore)
        .environment(reflectionStore)

        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let hostingController = UIHostingController(rootView: rootView)
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            window.isHidden = true
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            window.rootViewController = nil
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            previousKeyWindow?.makeKey()
            UIView.setAnimationsEnabled(animationsWereEnabled)
        }

        window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .systemBackground
        window.rootViewController = hostingController
        hostingController.view.frame = window.bounds
        window.makeKeyAndVisible()

        XCTAssertEqual(window.traitCollection.userInterfaceStyle, .light)
        guard window.traitCollection.userInterfaceStyle == .light else {
            throw SnapshotFailure.unpinnedEnvironment
        }

        window.setNeedsLayout()
        window.layoutIfNeeded()
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        window.layoutIfNeeded()
        hostingController.view.layoutIfNeeded()

        if let verticalScrollOffset {
            let scrollViews = hostedScrollViews(in: hostingController.view)
            let candidates = scrollViews.filter {
                !$0.isHidden
                    && $0.alpha > 0
                    && $0.bounds.height > 0
                    && $0.contentSize.height > $0.bounds.height
            }
            XCTAssertEqual(
                candidates.count,
                1,
                "Expected one visible hosted SwiftUI vertical scroll view; found \(candidates.count)."
            )
            guard let scrollView = candidates.first, candidates.count == 1 else {
                throw SnapshotFailure.unpinnedEnvironment
            }

            let minimumOffset = -scrollView.adjustedContentInset.top
            let maximumOffset = max(
                minimumOffset,
                scrollView.contentSize.height
                    - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom
            )
            XCTAssertGreaterThanOrEqual(
                maximumOffset,
                verticalScrollOffset,
                "Hosted scroll content does not cover the requested snapshot offset."
            )
            guard maximumOffset >= verticalScrollOffset else {
                throw SnapshotFailure.unpinnedEnvironment
            }

            let clampedOffset = min(max(verticalScrollOffset, minimumOffset), maximumOffset)
            guard abs(clampedOffset - verticalScrollOffset) <= 0.001 else {
                XCTFail("Hosted scroll offset was clamped before snapshot capture.")
                throw SnapshotFailure.unpinnedEnvironment
            }
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: clampedOffset),
                animated: false
            )
            scrollView.layoutIfNeeded()
            window.layoutIfNeeded()
            hostingController.view.layoutIfNeeded()
            guard abs(scrollView.contentOffset.y - clampedOffset) <= 0.001 else {
                XCTFail("Hosted scroll view did not retain the requested snapshot offset.")
                throw SnapshotFailure.unpinnedEnvironment
            }
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
    }

    private func hostedScrollViews(in view: UIView) -> [UIScrollView] {
        let current = view as? UIScrollView
        return current.map { [$0] } ?? view.subviews.flatMap(hostedScrollViews(in:))
    }

    private func assertSnapshot(
        named name: String,
        image actualImage: UIImage,
        environment: SnapshotEnvironment,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let validatedEnvironment = try SnapshotEnvironment.current(file: file, line: line)
        guard validatedEnvironment.folder == environment.folder,
              validatedEnvironment.deviceName == environment.deviceName,
              validatedEnvironment.modelIdentifier == environment.modelIdentifier,
              validatedEnvironment.logicalSize == environment.logicalSize else {
            XCTFail("Snapshot environment changed during the test run.", file: file, line: line)
            throw SnapshotFailure.unpinnedEnvironment
        }
        assertPinnedScreenSize(environment.logicalSize, file: file, line: line)
        guard UIScreen.main.bounds.size == environment.logicalSize else {
            throw SnapshotFailure.unpinnedEnvironment
        }

        let testFileURL = URL(fileURLWithPath: String(describing: file))
        let baselineDirectory = testFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__", isDirectory: true)
            .appendingPathComponent("ProfileSnapshotTests", isDirectory: true)
            .appendingPathComponent(environment.folder, isDirectory: true)
        let baselineURL = baselineDirectory
            .appendingPathComponent("\(environment.folder)-\(name).png")

        if ProcessInfo.processInfo.environment["EVLIN_RECORD_PROFILE_SNAPSHOTS"] == "1" {
            try FileManager.default.createDirectory(
                at: baselineDirectory,
                withIntermediateDirectories: true
            )
            try pngData(for: actualImage).write(to: baselineURL, options: .atomic)
            return
        }

        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            XCTFail(
                "Missing profile snapshot baseline: \(baselineURL.path). Compare mode did not write a baseline.",
                file: file,
                line: line
            )
            return
        }
        guard let expectedImage = UIImage(contentsOfFile: baselineURL.path) else {
            XCTFail("Could not decode profile snapshot baseline: \(baselineURL.path)", file: file, line: line)
            return
        }

        let expected = try rgbaImage(from: expectedImage)
        let actual = try rgbaImage(from: actualImage)
        let dimensionsMatch = expected.width == actual.width && expected.height == actual.height
        let diff = dimensionsMatch
            ? try imageDiff(expected: expected, actual: actual)
            : try dimensionMismatchDiff(expected: expected, actual: actual)

        guard dimensionsMatch && diff.ratio <= Self.changedPixelRatioThreshold else {
            let artifactDirectory = URL(fileURLWithPath: "/tmp/evlin-profile-snapshot-diffs", isDirectory: true)
                .appendingPathComponent(environment.folder, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: artifactDirectory,
                withIntermediateDirectories: true
            )

            let actualURL = artifactDirectory.appendingPathComponent("actual.png")
            let diffURL = artifactDirectory.appendingPathComponent("diff.png")
            let comparisonURL = artifactDirectory.appendingPathComponent("comparison.png")
            let comparison = try comparisonImage(
                expected: expectedImage,
                actual: actualImage,
                diff: diff.heatMap
            )
            try pngData(for: actualImage).write(to: actualURL, options: .atomic)
            try pngData(for: diff.heatMap).write(to: diffURL, options: .atomic)
            try pngData(for: comparison).write(to: comparisonURL, options: .atomic)
            attachArtifact(at: actualURL, name: "\(name) actual")
            attachArtifact(at: diffURL, name: "\(name) diff")
            attachArtifact(at: comparisonURL, name: "\(name) comparison")

            XCTFail(
                """
                Profile snapshot mismatch: \(name).png
                dimensions expected=\(expected.width)x\(expected.height) actual=\(actual.width)x\(actual.height)
                changedPixels=\(diff.changedPixels)/\(diff.totalPixels) ratio=\(String(format: "%.8f", diff.ratio)) threshold=\(Self.changedPixelRatioThreshold)
                actual=\(actualURL.path)
                diff=\(diffURL.path)
                comparison=\(comparisonURL.path)
                """,
                file: file,
                line: line
            )
            return
        }
    }

    private func rgbaImage(from image: UIImage) throws -> RGBAImage {
        guard let cgImage = image.cgImage else {
            XCTFail("Snapshot image has no CGImage backing.")
            throw SnapshotFailure.missingCGImage
        }

        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        let didNormalize = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didNormalize else {
            XCTFail("Could not normalize snapshot pixels.")
            throw SnapshotFailure.imageNormalizationFailed
        }
        return RGBAImage(width: width, height: height, bytes: bytes)
    }

    private func imageDiff(expected: RGBAImage, actual: RGBAImage) throws -> SnapshotDiff {
        let totalPixels = expected.width * expected.height
        var changedPixels = 0
        var heatMapBytes = [UInt8](repeating: 0, count: expected.bytes.count)

        for offset in stride(from: 0, to: expected.bytes.count, by: 4) {
            let changed = (0..<4).contains { channel in
                abs(Int(expected.bytes[offset + channel]) - Int(actual.bytes[offset + channel])) > 2
            }
            if changed {
                changedPixels += 1
                heatMapBytes[offset] = 255
                heatMapBytes[offset + 1] = 0
                heatMapBytes[offset + 2] = 0
                heatMapBytes[offset + 3] = 255
            } else {
                let grayscale = UInt8(
                    (Int(actual.bytes[offset])
                        + Int(actual.bytes[offset + 1])
                        + Int(actual.bytes[offset + 2])) / 12
                )
                heatMapBytes[offset] = grayscale
                heatMapBytes[offset + 1] = grayscale
                heatMapBytes[offset + 2] = grayscale
                heatMapBytes[offset + 3] = 255
            }
        }

        return SnapshotDiff(
            changedPixels: changedPixels,
            totalPixels: totalPixels,
            heatMap: try uiImage(from: RGBAImage(
                width: expected.width,
                height: expected.height,
                bytes: heatMapBytes
            ))
        )
    }

    private func dimensionMismatchDiff(expected: RGBAImage, actual: RGBAImage) throws -> SnapshotDiff {
        let width = max(expected.width, actual.width)
        let height = max(expected.height, actual.height)
        let totalPixels = width * height
        let bytes = stride(from: 0, to: totalPixels * 4, by: 4).reduce(
            into: [UInt8](repeating: 0, count: totalPixels * 4)
        ) { result, offset in
            result[offset] = 255
            result[offset + 3] = 255
        }
        return SnapshotDiff(
            changedPixels: totalPixels,
            totalPixels: totalPixels,
            heatMap: try uiImage(from: RGBAImage(width: width, height: height, bytes: bytes))
        )
    }

    private func uiImage(from rgba: RGBAImage) throws -> UIImage {
        let data = Data(rgba.bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let cgImage = CGImage(
                width: rgba.width,
                height: rgba.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: rgba.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw SnapshotFailure.imageNormalizationFailed
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private func comparisonImage(
        expected: UIImage,
        actual: UIImage,
        diff: UIImage
    ) throws -> UIImage {
        guard let expectedCG = expected.cgImage,
              let actualCG = actual.cgImage,
              let diffCG = diff.cgImage else {
            throw SnapshotFailure.missingCGImage
        }

        let labelHeight = 44
        let widths = [expectedCG.width, actualCG.width, diffCG.width]
        let height = max(expectedCG.height, actualCG.height, diffCG.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: widths.reduce(0, +), height: height + labelHeight),
            format: format
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: widths.reduce(0, +), height: height + labelHeight))

            let images = [expectedCG, actualCG, diffCG]
            let labels = ["EXPECTED", "ACTUAL", "DIFF"]
            var x = 0
            for index in images.indices {
                let width = widths[index]
                UIImage(cgImage: images[index]).draw(
                    in: CGRect(x: x, y: labelHeight, width: width, height: images[index].height)
                )
                labels[index].draw(
                    at: CGPoint(x: x + 14, y: 10),
                    withAttributes: [
                        .font: UIFont.boldSystemFont(ofSize: 20),
                        .foregroundColor: UIColor.black,
                    ]
                )
                x += width
            }
        }
    }

    private func pngData(for image: UIImage) throws -> Data {
        guard let data = image.pngData() else {
            throw SnapshotFailure.pngEncodingFailed
        }
        return data
    }

    private func attachArtifact(at url: URL, name: String) {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func isNonBlank(_ image: RGBAImage) -> Bool {
        guard image.bytes.count >= 8 else { return false }
        return stride(from: 4, to: image.bytes.count, by: 4).contains { offset in
            image.bytes[offset] != image.bytes[0]
                || image.bytes[offset + 1] != image.bytes[1]
                || image.bytes[offset + 2] != image.bytes[2]
                || image.bytes[offset + 3] != image.bytes[3]
        }
    }

    private func differingPixelRatio(_ lhs: RGBAImage, _ rhs: RGBAImage) -> Double {
        guard lhs.width == rhs.width,
              lhs.height == rhs.height,
              !lhs.bytes.isEmpty else { return 0 }
        let differingPixels = stride(from: 0, to: lhs.bytes.count, by: 4).reduce(into: 0) { count, offset in
            if lhs.bytes[offset] != rhs.bytes[offset]
                || lhs.bytes[offset + 1] != rhs.bytes[offset + 1]
                || lhs.bytes[offset + 2] != rhs.bytes[offset + 2]
                || lhs.bytes[offset + 3] != rhs.bytes[offset + 3] {
                count += 1
            }
        }
        return Double(differingPixels) / Double(lhs.width * lhs.height)
    }

    private static let sharedSummaryJSON = """
    {
      "child_profile_id": "10000000-0000-0000-0000-000000000001",
      "usage_date": "2026-07-15",
      "state": "ok",
      "earned_minutes": 120,
      "used_minutes": 85,
      "remaining_minutes": 35,
      "override_active": false,
      "updated_at": null,
      "countdown_label": null,
      "daily_pool_minutes": 120,
      "devices": [
        {
          "child_device_id": "20000000-0000-0000-0000-000000000001",
          "estimated_minutes": 0,
          "remaining_to_cap_minutes": 120,
          "cap_minutes": 120
        },
        {
          "child_device_id": "20000000-0000-0000-0000-000000000002",
          "estimated_minutes": 0,
          "remaining_to_cap_minutes": 60,
          "cap_minutes": 60
        }
      ]
    }
    """

    private static let taskPauseSummaryJSON = """
    {
      "child_profile_id": "10000000-0000-0000-0000-000000000001",
      "usage_date": "2026-07-15",
      "state": "ok",
      "earned_minutes": 120,
      "used_minutes": 0,
      "remaining_minutes": 120,
      "override_active": false,
      "updated_at": null,
      "countdown_label": null,
      "daily_pool_minutes": 120,
      "devices": [
        {
          "child_device_id": "20000000-0000-0000-0000-000000000001",
          "estimated_minutes": 0,
          "remaining_to_cap_minutes": 120,
          "cap_minutes": 120
        },
        {
          "child_device_id": "20000000-0000-0000-0000-000000000002",
          "estimated_minutes": 0,
          "remaining_to_cap_minutes": 60,
          "cap_minutes": 60
        }
      ]
    }
    """

    private static let exhaustedSummaryJSON = """
    {
      "child_profile_id": "10000000-0000-0000-0000-000000000001",
      "usage_date": "2026-07-15",
      "state": "exhausted",
      "earned_minutes": 120,
      "used_minutes": 120,
      "remaining_minutes": 0,
      "override_active": false,
      "updated_at": null,
      "countdown_label": null,
      "daily_pool_minutes": 120,
      "devices": [
        {
          "child_device_id": "20000000-0000-0000-0000-000000000001",
          "estimated_minutes": 120,
          "remaining_to_cap_minutes": 0,
          "cap_minutes": 120
        },
        {
          "child_device_id": "20000000-0000-0000-0000-000000000002",
          "estimated_minutes": 60,
          "remaining_to_cap_minutes": 0,
          "cap_minutes": 60
        }
      ]
    }
    """
}
