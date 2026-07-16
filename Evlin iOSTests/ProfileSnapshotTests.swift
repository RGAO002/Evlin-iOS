import XCTest
import SwiftUI
import UIKit
@testable import Evlin_iOS

@MainActor
final class ProfileSnapshotTests: XCTestCase {
    func test_debugFixtureSuppressesLiveRuntimeEffectsAfterAppearance() {
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

        let seededPixels = normalizedPixels(in: renderedImage(for: seededFixture))
        let emptyPixels = normalizedPixels(in: renderedImage(for: emptyFixture))

        XCTAssertTrue(isNonBlank(seededPixels))
        XCTAssertTrue(isNonBlank(emptyPixels))
        XCTAssertEqual(seededPixels.count, emptyPixels.count)
        XCTAssertGreaterThanOrEqual(
            differingPixelRatio(seededPixels, emptyPixels),
            0.01,
            "Seeded fixture content did not survive ProfileView.onAppear."
        )
    }

    private func fixture(
        tasks: [TaskItem],
        devices: [DeviceItem]
    ) -> ProfileView.ProfileSnapshotFixture_v1 {
        ProfileView.ProfileSnapshotFixture_v1(
            child: .previewLiam,
            tasks: tasks,
            devices: devices,
            rules: ProfileMockData.rules(for: "liam", dailyLimitMinutes: 120),
            dailyLimitMinutes: 120,
            localStatus: .unlocked,
            manualLockState: .unlocked,
            automaticCoveringSources: [],
            earnedSummary: nil,
            profileTab: .overview
        )
    }

    private func renderedImage(
        for fixture: ProfileView.ProfileSnapshotFixture_v1
    ) -> UIImage {
        let apiClient = APIClient(baseURL: "http://profile-snapshot.fixture")
        let rootView = ProfileView(snapshotFixture: fixture)
            .environmentObject(apiClient)
            .environment(ParentReflectionFixtureStore())
            .environment(FamilyStore(api: apiClient))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let hostingController = UIHostingController(rootView: rootView)
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        hostingController.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
        window.isHidden = true
        window.rootViewController = nil
        return image
    }

    private func normalizedPixels(in image: UIImage) -> [UInt8] {
        guard let cgImage = image.cgImage else {
            XCTFail("Rendered image has no CGImage backing.")
            return []
        }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(.init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        let context = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        }
        guard let context else {
            XCTFail("Could not normalize rendered pixels.")
            return []
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private func isNonBlank(_ pixels: [UInt8]) -> Bool {
        guard pixels.count >= 8 else { return false }
        return stride(from: 4, to: pixels.count, by: 4).contains { offset in
            pixels[offset] != pixels[0]
                || pixels[offset + 1] != pixels[1]
                || pixels[offset + 2] != pixels[2]
                || pixels[offset + 3] != pixels[3]
        }
    }

    private func differingPixelRatio(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        let pixelCount = lhs.count / 4
        guard pixelCount > 0, lhs.count == rhs.count else { return 0 }
        let differingPixels = stride(from: 0, to: lhs.count, by: 4).reduce(into: 0) { count, offset in
            if lhs[offset] != rhs[offset]
                || lhs[offset + 1] != rhs[offset + 1]
                || lhs[offset + 2] != rhs[offset + 2]
                || lhs[offset + 3] != rhs[offset + 3] {
                count += 1
            }
        }
        return Double(differingPixels) / Double(pixelCount)
    }
}
