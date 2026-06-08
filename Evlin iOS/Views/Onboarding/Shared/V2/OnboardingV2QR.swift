import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// Real QR rendering + a live-camera QR scanner for the pairing screens.
//
// The kid's "Show this to your parent" screen renders a REAL, scannable QR
// (`OnboardingV2QRImage`) encoding `evlin-pair:<6-digit code>`. The parent's
// "Scan the kid's code" screen runs a REAL camera (`OnboardingV2QRScanner`)
// and pulls the 6-digit code back out. The typed-code path stays as a fallback.

// MARK: - Pairing payload

enum OnboardingV2PairPayload {
    /// What the kid encodes into the QR — a prefixed, self-identifying payload
    /// so a stray QR in frame is unlikely to be mistaken for a pairing code.
    static func encode(code: String) -> String { "evlin-pair:\(code)" }

    /// Pulls the 6-digit pairing code out of a scanned QR string. Accepts the
    /// `evlin-pair:<code>` form (and a bare code) — requires exactly 6 digits so
    /// unrelated QR codes (URLs, WiFi configs, …) are ignored.
    static func code(from scanned: String) -> String? {
        let digits = scanned.filter(\.isNumber)
        return digits.count == 6 ? digits : nil
    }
}

// MARK: - Real QR image (kid shows this)

/// Renders a real, scannable QR encoding `string`. Replaces the decorative
/// faux-QR placeholder.
struct OnboardingV2QRImage: View {
    let string: String
    var side: CGFloat = 208

    var body: some View {
        Group {
            if let img = Self.makeQR(from: string) {
                Image(uiImage: img)
                    .interpolation(.none) // crisp modules, no blur
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(width: side, height: side)
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static func makeQR(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Live camera QR scanner (parent scans the kid's QR)

/// A live camera preview that scans QR codes and calls `onScan` with each
/// decoded payload. Uses NSCameraUsageDescription (already declared). On a
/// device without a camera (e.g. the simulator) or when access is denied, it
/// shows a hint — the typed-code fallback still works.
struct OnboardingV2QRScanner: View {
    let onScan: (String) -> Void
    var side: CGFloat = 240

    @State private var status: AVAuthorizationStatus =
        AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        ZStack {
            switch status {
            case .authorized:
                QRScannerRepresentable(onScan: onScan)
            case .notDetermined:
                hint("Starting camera…")
                    .task { await requestAccess() }
            default:
                hint("Camera access is off. Turn it on in Settings, or type the 6-digit code below.")
            }

            // White corner reticle (matches the mockup's scan frame).
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.9), lineWidth: 3)
                .padding(18)
                .allowsHitTesting(false)
        }
        .frame(width: side, height: side)
        .background(OnboardingV2Theme.Palette.darkScreen)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func requestAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        status = granted ? .authorized : .denied
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(OnboardingV2Theme.Typography.bodyXS)
            .foregroundStyle(Color.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .padding(24)
    }
}

/// UIKit bridge: an AVCaptureSession driving an AVCaptureVideoPreviewLayer,
/// decoding `.qr` metadata. Fires `onScan` once per distinct payload.
private struct QRScannerRepresentable: UIViewRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.start(in: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onScan: (String) -> Void
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "evlin.qr.session")
        private var lastPayload: String?

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func start(in view: PreviewView) {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                       for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes =
                output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []

            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill
            queue.async { [session] in session.startRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  obj.type == .qr,
                  let payload = obj.stringValue,
                  payload != lastPayload else { return }
            lastPayload = payload
            onScan(payload)
        }

        func stop() {
            queue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
