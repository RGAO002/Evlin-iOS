import Foundation
import ImageIO
import UIKit

/// Downsampled, decode-once previews for the kid's evidence photos.
///
/// `BigKidTaskDetailView` used to call `UIImage(data:)` inside body-computed
/// helpers — the hero, every strip tile, and the post-submit fallback — so a
/// full 2048px JPEG was re-decoded on the MAIN thread on every SwiftUI render
/// (up to 7 decodes x ~12MB of transient bitmap per pass with six photos).
/// That is main-thread stall plus a needless memory spike, and it was the
/// half of Esen's 2026-08-21 photo report that survived verification.
///
/// This decodes each photo ONCE, off-main, through ImageIO's thumbnail path
/// (never inflating the full bitmap), and caches the small result keyed by
/// the photo bytes. Six 640px thumbnails retain ~1.6MB total.
nonisolated enum EvidenceThumbnailCache {
    /// Long-edge pixels for the cached preview. Covers the ~4:3 hero card at
    /// 3x scale; the strip tiles reuse the same image scaled down.
    static let maxPixel: CGFloat = 640

    static func downsample(_ data: Data, maxPixel: CGFloat = maxPixel) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Decode every photo missing from `existing`, off the calling thread's
    /// concern — call from a background task and assign the result to state.
    static func fill(
        _ existing: [Data: UIImage],
        from photos: [Data]
    ) -> [Data: UIImage] {
        var cache: [Data: UIImage] = [:]
        for data in photos {
            if let cached = existing[data] {
                cache[data] = cached
            } else if let image = downsample(data) {
                cache[data] = image
            }
        }
        return cache
    }
}
