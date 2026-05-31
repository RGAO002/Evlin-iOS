import DeviceActivity
import FamilyControls
import ManagedSettings
import PhotosUI
import SwiftUI
import UIKit
import Vision

private extension DeviceActivityReport.Context {
    static let evlinQrSpike = Self("evlin.qrSpike")
}

struct QrSpikeDebugView: View {
    @State private var status: String = "Tap 'Capture' to begin"
    @State private var capturedImage: UIImage?
    @State private var decodedPayload: String?
    @State private var observationCount: Int = 0
    @State private var selectedScreenshot: PhotosPickerItem?
    @State private var decodedTokenPayload: QrImportedAppToken?
    @State private var decodedAppToken: ApplicationToken?
    @State private var shieldStatus: String = "No decoded app token yet"
    @State private var refreshID = UUID()

    private let debugShieldStore = ManagedSettingsStore()

    private var filter: DeviceActivityFilter {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end)
            ?? end.addingTimeInterval(-7 * 24 * 3_600)
        return DeviceActivityFilter(
            segment: .daily(during: DateInterval(start: start, end: end)),
            devices: .all
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("QR-over-pixel DAR spike")
                    .font(.headline)

                Text("Expected payload:")
                    .font(.caption)
                Text("evlin_app_token_v1 JSON from best non-Evlin app in DAR report")
                    .font(.caption.monospaced())
                    .padding(6)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                DeviceActivityReport(.evlinQrSpike, filter: filter)
                    .id(refreshID)
                    .frame(width: 320, height: 360)
                    .background(Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    refreshID = UUID()
                    resetDecodeState(keepImage: false)
                    status = "Report refreshed with all-activity no-users filter"
                } label: {
                    Label("Refresh QR report", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button("Capture and decode") {
                    runCapture()
                }
                .buttonStyle(.borderedProminent)

                PhotosPicker(selection: $selectedScreenshot, matching: .images) {
                    Label("Import system screenshot and decode", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)

                if let tokenPayload = decodedTokenPayload {
                    GroupBox("Decoded app token") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Display: \(tokenPayload.displayName)")
                            Text("Bundle: \(tokenPayload.bundleID.isEmpty ? "<empty>" : tokenPayload.bundleID)")
                            Text("Token b64 chars: \(tokenPayload.tokenB64.count)")
                            Text("Token decode: \(decodedAppToken == nil ? "failed" : "ok")")
                            Text("Shield: \(shieldStatus)")
                                .foregroundStyle(decodedAppToken == nil ? .orange : .secondary)
                            HStack {
                                Button("Shield decoded app for 1 min") {
                                    shieldDecodedToken()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(decodedAppToken == nil)

                                Button("Clear QR shield") {
                                    clearQrShield()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let img = capturedImage {
                    Text("Image under test:")
                        .font(.caption)
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 360)
                        .border(Color.red, width: 1)
                }

                GroupBox("Result") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Barcode observations: \(observationCount)")
                        Text("Decoded: \(decodedPayload ?? "<nil>")")
                            .textSelection(.enabled)
                        Text("Status: \(status)")
                        resultLabel
                    }
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle("QR Spike")
        .onChange(of: selectedScreenshot) { _, item in
            guard let item else { return }
            importAndDecode(item)
        }
    }

    @ViewBuilder
    private var resultLabel: some View {
        if decodedAppToken != nil {
            Text("PASS - app token decoded")
                .foregroundColor(.green)
                .bold()
        } else if decodedTokenPayload != nil {
            Text("DECODED JSON BUT TOKEN FAILED")
                .foregroundColor(.orange)
                .bold()
        } else if decodedPayload != nil {
            Text("DECODED NON-TOKEN PAYLOAD")
                .foregroundColor(.orange)
                .bold()
        } else {
            Text("FAIL")
                .foregroundColor(.red)
                .bold()
        }
    }

    private func runCapture() {
        status = "Waiting 1.5s for DAR to render..."
        resetDecodeState(keepImage: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            capture()
        }
    }

    private func capture() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else {
            status = "No key window"
            return
        }

        let renderer = UIGraphicsImageRenderer(size: window.bounds.size)
        let img = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        capturedImage = img
        decode(img, source: "framebuffer capture")
    }

    private func importAndDecode(_ item: PhotosPickerItem) {
        status = "Loading selected screenshot..."
        resetDecodeState(keepImage: false)
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let img = UIImage(data: data) else {
                    await MainActor.run {
                        status = "Selected item was not image data"
                    }
                    return
                }
                await MainActor.run {
                    capturedImage = img
                    decode(img, source: "imported screenshot")
                }
            } catch {
                await MainActor.run {
                    status = "Photo import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func decode(_ image: UIImage, source: String) {
        guard let cg = image.cgImage else {
            status = "\(source) UIImage had no cgImage"
            return
        }

        let request = VNDetectBarcodesRequest { req, err in
            DispatchQueue.main.async {
                if let err {
                    status = "Vision error: \(err.localizedDescription)"
                    return
                }
                let obs = (req.results as? [VNBarcodeObservation]) ?? []
                observationCount = obs.count
                if let qrObs = obs.first(where: { $0.symbology == .qr }),
                   let payload = qrObs.payloadStringValue {
                    decodedPayload = payload
                    parseDecodedPayload(payload)
                    status = "Decoded \(payload.count) chars from \(source)"
                } else if !obs.isEmpty {
                    status = "Found \(obs.count) non-QR barcodes - QR not detected"
                } else {
                    status = "QR not detected in \(source)"
                }
            }
        }
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    status = "Vision perform failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func parseDecodedPayload(_ payload: String) {
        decodedTokenPayload = nil
        decodedAppToken = nil
        shieldStatus = "Decoded payload is not an app token JSON"

        guard let data = payload.data(using: .utf8),
              let tokenPayload = try? JSONDecoder().decode(QrImportedAppToken.self, from: data),
              tokenPayload.kind == "evlin_app_token_v1" else {
            return
        }
        decodedTokenPayload = tokenPayload
        guard let tokenData = Data(base64Encoded: tokenPayload.tokenB64) else {
            shieldStatus = "token_b64 base64 decode failed"
            return
        }
        if let token = try? JSONDecoder().decode(ApplicationToken.self, from: tokenData) {
            decodedAppToken = token
            shieldStatus = "ApplicationToken decoded via JSON"
        } else if let token = try? PropertyListDecoder().decode(ApplicationToken.self, from: tokenData) {
            decodedAppToken = token
            shieldStatus = "ApplicationToken decoded via plist"
        } else {
            shieldStatus = "ApplicationToken decode failed"
        }
    }

    private func shieldDecodedToken() {
        guard AuthorizationCenter.shared.authorizationStatus == .approved else {
            shieldStatus = "Screen Time authorization is not approved"
            return
        }
        guard let token = decodedAppToken else {
            shieldStatus = "No decoded token to shield"
            return
        }
        debugShieldStore.shield.applications = [token]
        let name = decodedTokenPayload?.displayName ?? "decoded app"
        shieldStatus = "Shield applied to \(name). Physically open the app to verify shield UI."
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            debugShieldStore.shield.applications = nil
            shieldStatus = "Auto-cleared QR spike shield after 1 min"
        }
    }

    private func clearQrShield() {
        debugShieldStore.shield.applications = nil
        shieldStatus = "QR spike shield cleared"
    }

    private func resetDecodeState(keepImage: Bool) {
        if !keepImage {
            capturedImage = nil
        }
        decodedPayload = nil
        decodedTokenPayload = nil
        decodedAppToken = nil
        observationCount = 0
        shieldStatus = "No decoded app token yet"
    }
}

private struct QrImportedAppToken: Codable {
    let kind: String
    let displayName: String
    let bundleID: String
    let tokenB64: String
}

#Preview {
    NavigationStack {
        QrSpikeDebugView()
    }
}
