import PhotosUI
import SwiftUI
import UIKit

// I1: a real, tappable avatar picker for the parent + child profile steps.
// Tapping opens a confirmationDialog (Take Photo / Choose from Library). The
// picked image shows locally (backend photo upload is still DEFERRED). When no
// photo is picked, it falls back to the SAME initials letter-avatar the
// parent-side Home uses (EvlinAvatarView) — NOT an emoji.

struct OnboardingV2PhotoAvatarPicker: View {
    /// Drives the initials fallback (first letter). Pass the live name binding
    /// so the letter updates as the user types.
    let name: String
    @Binding var pickedImage: UIImage?
    var size: CGFloat = 66
    var accent: Color = OnboardingV2Theme.Palette.primary

    @State private var showDialog = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var libraryItem: PhotosPickerItem?

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        Button { showDialog = true } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let pickedImage {
                        Image(uiImage: pickedImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                    } else {
                        // Reuse the exact Home initials fallback (letter avatar).
                        EvlinAvatarView(url: nil, name: name.isEmpty ? "?" : name, size: size)
                    }
                }
                // "+" add badge.
                Image(systemName: "plus")
                    .font(.system(size: size * 0.18, weight: .bold))
                    .foregroundStyle(OnboardingV2Theme.Palette.onPrimary)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .background(Circle().fill(accent))
                    .overlay(Circle().stroke(OnboardingV2Theme.Palette.surface, lineWidth: 2))
            }
        }
        .buttonStyle(.plain)
        .confirmationDialog("Add a photo", isPresented: $showDialog, titleVisibility: .visible) {
            if cameraAvailable {
                Button("Take Photo") { showCamera = true }
            }
            Button("Choose from Library") { showLibrary = true }
            if pickedImage != nil {
                Button("Remove Photo", role: .destructive) { pickedImage = nil }
            }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showLibrary, selection: $libraryItem, matching: .images)
        .sheet(isPresented: $showCamera) {
            OnboardingV2CameraPicker(image: $pickedImage)
                .ignoresSafeArea()
        }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run { pickedImage = img }
                }
            }
        }
    }
}

/// Downscale + JPEG-encode a picked avatar for upload (keeps it small + fast).
func evlinAvatarJPEG(_ image: UIImage, maxDim: CGFloat = 512) -> Data? {
    let longest = max(image.size.width, image.size.height)
    let scale = longest > maxDim ? maxDim / longest : 1
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: size)
    let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    return resized.jpegData(compressionQuality: 0.7)
}

/// UIKit camera bridge (PhotosPicker has no camera capture). Uses the existing
/// NSCameraUsageDescription. Camera is unavailable on the Simulator, so callers
/// guard on `UIImagePickerController.isSourceTypeAvailable(.camera)`.
private struct OnboardingV2CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: OnboardingV2CameraPicker
        init(_ parent: OnboardingV2CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.image = img }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
