// Evlin iOS/Evlin iOS/Views/Debug/TokenScreenshotImportView.swift
//
// Auto-tag flow that bypasses Apple's `Label(token)` privacy strip by
// routing through the **system screenshot** pipeline:
//
//   1. Render every selected ApplicationToken as a numbered capsule on screen.
//      `[<index>]  <icon> <name>` — index is the trick that lets us re-bind
//      OCR text to the right token without coordinate alignment.
//   2. Parent takes iOS system screenshots (Volume+Power) covering the list.
//      Those screenshots write **real pixels** to the Photos library —
//      `Label(token)` is rendered by the FamilyControls daemon onto the
//      compositor's framebuffer, and system screenshot reads the framebuffer
//      directly (it's not in the redacted in-process readback path).
//   3. Parent imports the screenshots back via PHPicker.
//   4. Vision `VNRecognizeTextRequest` (free, on-device) reads each one,
//      regex-extracts `[<index>] <name>` rows.
//   5. We map index → token and persist via `LocalAliasStore.saveApplicationAliases`.
import SwiftUI
import FamilyControls
import ManagedSettings
import PhotosUI
@preconcurrency import Vision

struct TokenScreenshotImportView: View {
    @EnvironmentObject var screenTimeManager: ScreenTimeManager

    /// Captured at view-appear so the index binding is stable for the whole flow.
    /// Set ordering is non-deterministic across launches but stable within a launch.
    @State private var orderedApps: [ApplicationToken] = []

    /// User-visible status counters.
    @State private var screenshotsTaken: Int = 0
    @State private var pickerOpen: Bool = false
    @State private var pickedImages: [UIImage] = []
    @State private var processing: Bool = false
    @State private var taggedPairs: [(index: Int, name: String, token: ApplicationToken)] = []
    @State private var statusMessage: String = ""

    /// Diagnostic: every line Vision found in the imported screenshots, in order.
    /// If this is empty when imported images are non-empty, OCR never engaged
    /// (image was redacted, format failed, etc). If this is full but
    /// `taggedPairs` is empty, regex didn't match what was read.
    @State private var rawOCRLines: [String] = []
    @State private var diagnosticVisible: Bool = false

    /// Pixel size of each capsule row when rendered. Tightening helps fit more
    /// per screen — fewer screenshots — at the cost of OCR confidence.
    private let rowFontSize: CGFloat = 16
    private let rowVerticalPadding: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            instructionsBar
            list
            controls
        }
        .navigationTitle("Auto-tag (screenshot)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { snapshotOrdering() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.userDidTakeScreenshotNotification
        )) { _ in
            screenshotsTaken += 1
        }
        .sheet(isPresented: $pickerOpen) {
            ScreenshotPicker(images: $pickedImages, onClose: {
                pickerOpen = false
                Task { await processPickedImages() }
            })
        }
    }

    // MARK: - UI sub-views

    private var instructionsBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Auto-tag via system screenshots")
                .font(.headline)
            Text("1. Scroll through the list below.\n2. Take iOS screenshots (Volume + Power) covering every row.\n3. Tap **Import screenshots** to OCR them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Label("\(screenshotsTaken) screenshots taken", systemImage: "camera.fill")
                    .font(.caption)
                    .foregroundStyle(Color.evSecondary)
                Spacer()
                Text("\(orderedApps.count) tokens to tag")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(Array(orderedApps.enumerated()), id: \.offset) { idx, tok in
                    capsule(idx: idx, token: tok)
                        .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func capsule(idx: Int, token: ApplicationToken) -> some View {
        // Tight layout: idx + icon + name visually packed so Vision merges
        // them into ONE text observation. Wide gaps cause Vision to fragment
        // — empirically `[2]` ended up on its own line, name on next.
        // Format `idx.` (period) is OCR-safer than `[idx]` (Vision often eats
        // brackets) but the parser is format-agnostic anyway via state machine.
        HStack(spacing: 6) {
            Text("\(idx).")
                .font(.system(size: rowFontSize, weight: .heavy, design: .monospaced))
                .foregroundStyle(.black)
            Label(token)
                .labelStyle(.titleAndIcon)
                .font(.system(size: rowFontSize, weight: .semibold))
                .foregroundStyle(.black)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, rowVerticalPadding)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if processing {
                ProgressView("Running OCR…")
                    .padding(.vertical, 6)
            }
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            if !taggedPairs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(taggedPairs, id: \.index) { p in
                            Text("[\(p.index)] → \"\(p.name)\"")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                }
                .frame(maxHeight: 140)
            }

            // Diagnostics: show what we actually got from PHPicker + Vision.
            // If the imported image looks redacted (yellow boxes), Apple is
            // re-stripping at PHPicker. If image looks fine but rawOCRLines
            // is empty, Vision misfired. If lines are full but no tags, regex.
            if diagnosticVisible {
                DisclosureGroup("Diagnostics") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !pickedImages.isEmpty {
                            Text("Imported image[0] preview:")
                                .font(.caption.bold())
                            ScrollView(.horizontal) {
                                Image(uiImage: pickedImages[0])
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 240)
                            }
                            .border(Color.gray.opacity(0.3))
                            Text("size = \(Int(pickedImages[0].size.width))×\(Int(pickedImages[0].size.height)) pt, scale=\(pickedImages[0].scale)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text("Raw OCR output (\(rawOCRLines.count) lines):")
                            .font(.caption.bold())
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(rawOCRLines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                        .border(Color.gray.opacity(0.3))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .padding(.horizontal, 12)
            }
            HStack {
                Button {
                    pickedImages = []
                    pickerOpen = true
                } label: {
                    Label("Import screenshots", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(processing)

                if !taggedPairs.isEmpty {
                    Button("Save aliases") {
                        saveAliases()
                    }
                    .buttonStyle(.bordered)
                    .disabled(processing)
                }
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Logic

    private func snapshotOrdering() {
        guard orderedApps.isEmpty else { return }
        // Sort by hashValue for deterministic-within-launch ordering, so two
        // visits during one session produce the same [idx] mapping.
        orderedApps = Array(screenTimeManager.selectedApps.applicationTokens)
            .sorted { $0.hashValue < $1.hashValue }
    }

    @MainActor
    private func processPickedImages() async {
        guard !pickedImages.isEmpty else { return }
        processing = true
        defer { processing = false }

        statusMessage = "OCR'ing \(pickedImages.count) screenshot\(pickedImages.count == 1 ? "" : "s")…"
        var foundByIndex: [Int: String] = [:]
        rawOCRLines = []

        for (i, img) in pickedImages.enumerated() {
            statusMessage = "Image \(i + 1) / \(pickedImages.count)… size=\(Int(img.size.width))×\(Int(img.size.height))"
            let lines = await ocrLines(in: img)
            rawOCRLines.append("--- image \(i + 1) (\(lines.count) lines) ---")
            rawOCRLines.append(contentsOf: lines)
            for (idx, name) in parsePairs(from: lines) where !name.isEmpty {
                foundByIndex[idx] = name
            }
        }
        diagnosticVisible = true

        var pairs: [(Int, String, ApplicationToken)] = []
        for (idx, name) in foundByIndex.sorted(by: { $0.key < $1.key }) {
            guard idx >= 0 && idx < orderedApps.count else { continue }
            pairs.append((idx, name, orderedApps[idx]))
        }
        taggedPairs = pairs

        if pairs.isEmpty {
            statusMessage = "OCR found no \"[N] Name\" rows. The screenshot may not contain this list, or text may be too small."
        } else {
            statusMessage = "Found \(pairs.count) tags. Review below — tap **Save aliases** to persist."
        }
    }

    private func saveAliases() {
        let store = LocalAliasStore.shared
        for p in taggedPairs {
            store.saveApplicationAliases(
                token: p.token,
                displayName: p.name,
                bundleIdentifier: nil
            )
        }
        statusMessage = "Saved \(taggedPairs.count) aliases to LocalAliasStore."
    }

    /// Parse Vision text lines using a state machine that survives Vision
    /// fragmenting one row across multiple observations.
    ///
    /// Vision sometimes emits a row as one line (`0. @ Hiya`), sometimes as
    /// three (`[2]` / `in` / `LinkedIn`). Both must collapse to the same
    /// `(idx, name)` pair. Algorithm:
    ///
    ///   1. Walk lines top-to-bottom.
    ///   2. A line whose **leading non-whitespace token is a 1-3 digit number**
    ///      starts a new row, flushing the previous one.
    ///   3. Subsequent lines without leading digits append to the current row.
    ///   4. On flush, strip a leading 1-2 char "icon glyph" if followed by a
    ///      longer real word (e.g. `"G Google"` → `"Google"`, `"in LinkedIn"`
    ///      → `"LinkedIn"`).
    private func parsePairs(from lines: [String]) -> [(Int, String)] {
        // Match leading digits with any wrapping punctuation: `[12]`, `(12)`,
        // `12.`, `12:`, `12)`, `12]`, or just `12 Foo`. Capture digits + tail.
        let leadDigits = try? NSRegularExpression(
            pattern: #"^[\[\(\{\s]*(\d{1,3})[\]\)\}\.\:\;,\s]*(.*)$"#
        )

        var out: [(Int, String)] = []
        var seen = Set<Int>()
        var currentIdx: Int? = nil
        var currentParts: [String] = []

        func flush() {
            defer { currentIdx = nil; currentParts = [] }
            guard let idx = currentIdx, !seen.contains(idx) else { return }
            let combined = currentParts.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = stripLeadingIconGlyph(combined)
            guard !cleaned.isEmpty else { return }
            seen.insert(idx)
            out.append((idx, cleaned))
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let range = NSRange(line.startIndex..., in: line)
            if let re = leadDigits,
               let m = re.firstMatch(in: line, range: range),
               m.numberOfRanges == 3,
               let idxR = Range(m.range(at: 1), in: line),
               let restR = Range(m.range(at: 2), in: line),
               let idx = Int(line[idxR]),
               idx < orderedApps.count {
                flush()
                currentIdx = idx
                let rest = String(line[restR]).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { currentParts.append(rest) }
            } else if currentIdx != nil {
                currentParts.append(line)
            }
            // else: header / footer / unrelated chrome — ignore.
        }
        flush()

        return out.sorted { $0.0 < $1.0 }
    }

    /// `"G Google"` → `"Google"`. `"in LinkedIn"` → `"LinkedIn"`. `"Hiya"` → unchanged.
    private func stripLeadingIconGlyph(_ s: String) -> String {
        let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return s }
        let head = String(parts[0])
        let tail = String(parts[1]).trimmingCharacters(in: .whitespaces)
        guard head.count <= 2, tail.count >= 2 else { return s }
        let tailHasLetters = tail.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        return tailHasLetters ? tail : s
    }

    private func ocrLines(in image: UIImage) async -> [String] {
        guard let cg = image.cgImage else { return [] }
        return await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            let req = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                cont.resume(returning: lines)
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            req.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]
            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do {
                    try handler.perform([req])
                } catch {
                    cont.resume(returning: [])
                }
            }
        }
    }
}

// MARK: - PHPicker wrapper

/// PHPicker filtered to the user's screenshot album, multi-select.
private struct ScreenshotPicker: UIViewControllerRepresentable {
    @Binding var images: [UIImage]
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .screenshots
        config.selectionLimit = 0
        config.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coord { Coord(parent: self) }

    final class Coord: NSObject, PHPickerViewControllerDelegate {
        let parent: ScreenshotPicker
        init(parent: ScreenshotPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Drain results sequentially — preserve picker order for status display.
            let group = DispatchGroup()
            var collected: [(Int, UIImage)] = []
            for (i, r) in results.enumerated() {
                guard r.itemProvider.canLoadObject(ofClass: UIImage.self) else { continue }
                group.enter()
                r.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                    if let img = obj as? UIImage {
                        collected.append((i, img))
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let sorted = collected.sorted { $0.0 < $1.0 }.map { $0.1 }
                self.parent.images = sorted
                self.parent.onClose()
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        TokenScreenshotImportView()
            .environmentObject(ScreenTimeManager.shared)
    }
}
#endif
