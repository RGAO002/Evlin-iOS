import XCTest
import UIKit
@testable import Evlin_iOS

final class EvidenceThumbnailCacheTests: XCTestCase {
    private func jpeg(side: CGFloat) -> Data {
        // scale = 1 so `side` means PIXELS — on a 3x simulator the default
        // renderer format would triple every dimension and break the
        // pass-through assertions.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side), format: format
        )
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    func testDownsampleCapsTheLongEdge() throws {
        let big = jpeg(side: 2048)
        let thumb = try XCTUnwrap(EvidenceThumbnailCache.downsample(big))
        let longEdge = max(thumb.size.width * thumb.scale, thumb.size.height * thumb.scale)
        XCTAssertLessThanOrEqual(longEdge, EvidenceThumbnailCache.maxPixel)
        XCTAssertGreaterThan(longEdge, 0)
    }

    func testSmallImagePassesThroughWithoutUpscaling() throws {
        let small = jpeg(side: 200)
        let thumb = try XCTUnwrap(EvidenceThumbnailCache.downsample(small))
        XCTAssertLessThanOrEqual(max(thumb.size.width * thumb.scale, thumb.size.height * thumb.scale), 200 + 1)
    }

    func testGarbageDataReturnsNilInsteadOfCrashing() {
        XCTAssertNil(EvidenceThumbnailCache.downsample(Data([0x00, 0x01, 0x02])))
    }

    func testFillReusesExistingDecodesAndDropsRemovedPhotos() throws {
        let a = jpeg(side: 300)
        let b = jpeg(side: 400)
        let first = EvidenceThumbnailCache.fill([:], from: [a, b])
        XCTAssertEqual(first.count, 2)
        let reusedA = try XCTUnwrap(first[a])

        // Removing b and re-filling must reuse a's EXACT decoded object and
        // drop b — the cache never grows past the current photo set.
        let second = EvidenceThumbnailCache.fill(first, from: [a])
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(second[a] === reusedA, "existing decode must be reused, not re-decoded")
        XCTAssertNil(second[b])
    }

    /// Pin the view contract: body helpers must never synchronously decode
    /// full-resolution photo data again.
    func testTaskDetailViewNeverDecodesFullResolutionInline() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Evlin iOS/Views/Child/BigKid/BigKidTaskDetailView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            source.contains("UIImage(data:"),
            "decode goes through EvidenceThumbnailCache, once, off-main"
        )
        XCTAssertTrue(source.contains("EvidenceThumbnailCache.fill"))
    }
}
