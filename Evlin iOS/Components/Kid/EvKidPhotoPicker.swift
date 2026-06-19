import SwiftUI
import UIKit

/// Minimal UIImagePickerController wrapper. Camera-only (no library) to match
/// the prototype's "Take a photo" UX. Returns JPEG data via the `onCapture`
/// callback; closes the sheet on success or cancel.
struct EvKidPhotoPicker: UIViewControllerRepresentable {
    let onCapture: (Data?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data?) -> Void
        init(onCapture: @escaping (Data?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let img = info[.originalImage] as? UIImage
            onCapture(img.flatMap { EvKidPhotoPicker.downscaledJPEG($0) })
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }

    /// Downscale to a 2048px long edge before JPEG-encoding. A raw camera frame
    /// is ~12MP (4032×3024); `jpegData` alone only trims quality, leaving each
    /// photo 2–4MB. Evidence submit POSTs every photo in one multipart body, so
    /// on a weak cellular link that payload would stall past the request timeout
    /// and surface as "Could not submit. Check the connection." 2048px keeps the
    /// image sharp enough to pinch-zoom legible detail (e.g. a homework sheet)
    /// while landing each photo near ~400KB.
    static func downscaledJPEG(
        _ image: UIImage,
        maxDimension: CGFloat = 2048,
        quality: CGFloat = 0.8
    ) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else {
            return image.jpegData(compressionQuality: quality)
        }
        let scale = maxDimension / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        // scale = 1 so the renderer outputs exactly `target` pixels — without it,
        // a @3x device would render target×3 and defeat the downscale.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
