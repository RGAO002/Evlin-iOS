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
import ReplayKit
import CoreImage
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

    /// Font size of each chip's text. Smaller = more chips per screen = fewer
    /// screenshots, but below ~8pt Vision starts SILENTLY dropping names (a
    /// dropped name = a token with no mapping). Tunable live so you can find the
    /// smallest size that still OCRs cleanly on this device.
    @State private var chipFontSize: Double = 9
    /// Horizontal/vertical gap between chips. Too tight = Vision merges adjacent
    /// names into garbage; too loose = wasted space. Tunable live.
    @State private var chipSpacing: Double = 7

    /// Full-screen clean capture mode: shows ONLY the chips (no instructions,
    /// nav bar, controls, or diagnostics) so the system screenshot contains no
    /// stray text the parser could mistake for an "idx." marker. This is the fix
    /// for OCR picking up the numbered instructions / footer chrome.
    @State private var captureMode = false

    var body: some View {
        VStack(spacing: 0) {
            instructionsBar
            list
            controls
        }
        .navigationTitle("Auto-tag (screenshot)")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $captureMode) { captureScreen }
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
            Text("Tap **Open clean capture screen**, screenshot the chips there (Volume+Power or Back Tap), tap Done, then **Import screenshots**. Capture mode hides all text except the app chips so OCR can't pick up stray markers. Tune Font/Gap to pack more per screen.")
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
            // Flowing layout: chips packed left-to-right, wrapping when full —
            // many per visual row instead of one row each. White background so
            // the system screenshot has clean high-contrast pixels for OCR.
            FlowLayout(spacing: chipSpacing) {
                ForEach(Array(orderedApps.enumerated()), id: \.offset) { idx, tok in
                    compactChip(idx: idx, token: tok)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
        }
    }

    private func compactChip(idx: Int, token: ApplicationToken) -> some View {
        // `idx.` is the correlation anchor (maps OCR text → token). NO icon
        // (.titleOnly) — the icon wastes width and is useless for OCR. Each chip
        // is its own natural-width unit so long names don't truncate; FlowLayout
        // wraps them. Small gap inside so Vision reads "idx." + name together.
        HStack(spacing: 1) {
            Text("\(idx).")
                .font(.system(size: chipFontSize, weight: .heavy, design: .monospaced))
                .foregroundStyle(.black)
            Label(token)
                .labelStyle(.titleOnly)
                .font(.system(size: chipFontSize, weight: .semibold))
                .foregroundStyle(.black)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Clean full-screen capture surface: ONLY chips on white. No numbered
    /// instructions, no nav bar, no footer/steppers, no diagnostic echo — so a
    /// system screenshot here contains nothing the parser can mistake for a
    /// marker. The only chrome is a "Done" button (no digits → parser-safe).
    private var captureScreen: some View {
        ZStack(alignment: .topTrailing) {
            Color.white.ignoresSafeArea()
            ScrollView {
                FlowLayout(spacing: chipSpacing) {
                    ForEach(Array(orderedApps.enumerated()), id: \.offset) { idx, tok in
                        compactChip(idx: idx, token: tok)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Done") { captureMode = false }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            // Live density tuning. Smaller font + tighter gap = fewer
            // screenshots, but watch the diagnostic: if names start dropping or
            // garbling after Import, you've gone past this device's OCR floor.
            HStack(spacing: 16) {
                Stepper("Font \(Int(chipFontSize))pt", value: $chipFontSize, in: 5...18, step: 1)
                    .font(.caption)
                Stepper("Gap \(Int(chipSpacing))", value: $chipSpacing, in: 2...16, step: 1)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            Button {
                captureMode = true
            } label: {
                Label("Open clean capture screen → screenshot there", systemImage: "rectangle.dashed")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)

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
        // Stream parser. Join all OCR lines, then find every "<digits><delim>"
        // marker. A chip renders as "idx.name"; in dense flow mode Vision often
        // packs several chips into ONE observation ("1.Insta 2.TikTok 3.Roblox"),
        // and in sparse mode it may fragment one chip across lines. Joining +
        // scanning for markers handles BOTH: each marker's name = the text
        // between it and the next marker. Requiring a delimiter right after the
        // digits avoids matching digits embedded in a name (e.g. "1Password").
        let text = lines.joined(separator: " ")
        // Delimiter restricted to "." / ")" / "]" — chips render "idx." so "."
        // is the real one; ")" "]" tolerate OCR misreads. Deliberately NOT ":"
        // (the status-bar clock "9:41" would otherwise register as marker 9) and
        // NOT bare whitespace (battery "47" etc.).
        guard let re = try? NSRegularExpression(pattern: #"(\d{1,3})\s*[.)\]]"#) else {
            return []
        }
        let ns = text as NSString
        let markers = re.matches(in: text, range: NSRange(location: 0, length: ns.length))

        var out: [(Int, String)] = []
        var seen = Set<Int>()
        for (i, m) in markers.enumerated() {
            guard let idx = Int(ns.substring(with: m.range(at: 1))),
                  idx >= 0, idx < orderedApps.count, !seen.contains(idx) else { continue }
            let nameStart = m.range.location + m.range.length
            let nameEnd = (i + 1 < markers.count) ? markers[i + 1].range.location : ns.length
            guard nameEnd > nameStart else { continue }
            var name = ns.substring(with: NSRange(location: nameStart, length: nameEnd - nameStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            name = stripLeadingIconGlyph(name)
            // Guard against OCR merging trailing chrome into the last name.
            if name.count > 40 {
                name = String(name.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !name.isEmpty else { continue }
            seen.insert(idx)
            out.append((idx, name))
        }
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
        // Two levers that lower the readable-font floor without changing layout:
        //   1. Upscale the screenshot ~2x before OCR — Vision's recognizer does
        //      measurably better on larger glyphs, recovering misreads like
        //      "iTunes" → "¡Tunes" that happen at tiny sizes.
        //   2. minimumTextHeight ≈ 0 so Vision doesn't SKIP small text outright
        //      (its default threshold drops text below ~1/32 of image height).
        let prepared = upscaledForOCR(image)
        guard let cg = prepared.cgImage else { return [] }
        return await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            let req = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                cont.resume(returning: lines)
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            req.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]
            req.minimumTextHeight = 0.005
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

    /// Upscale a screenshot ~2x (high interpolation, capped for memory) before
    /// OCR. No new real detail, but Vision recognizes larger glyphs better, which
    /// lifts accuracy on very small fonts.
    private func upscaledForOCR(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let srcW = CGFloat(cg.width)
        let srcH = CGFloat(cg.height)
        let factor = min(2.0, 4096.0 / max(srcW, srcH))
        guard factor > 1.05 else { return image }
        let size = CGSize(width: srcW * factor, height: srcH * factor)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            ctx.cgContext.interpolationQuality = .high
            image.draw(in: CGRect(origin: .zero, size: size))
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
