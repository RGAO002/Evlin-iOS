// Evlin iOS/Evlin iOS/Views/Debug/LabelTokenInspectorView.swift
//
// Tests whether `Label(ApplicationToken)` / `Label(ActivityCategoryToken)`
// can be snapshotted via SwiftUI `ImageRenderer` and OCR'd via Vision.
//
// Three-stage signal per row:
//   1. Naked Label(token)      — does iOS even render the name on screen?
//   2. ImageRenderer snapshot  — does the rendered pixel buffer contain the name,
//                                or does Apple privacy-strip it (blank / "App")?
//   3. VNRecognizeTextRequest  — can on-device OCR pull the string out?
//
// If all three light up, we have a viable auto-tagging path that bypasses the
// metadata-starved `localizedDisplayName` problem on this device.
import SwiftUI
import FamilyControls
import ManagedSettings
@preconcurrency import Vision

struct LabelTokenInspectorView: View {
    @EnvironmentObject var screenTimeManager: ScreenTimeManager

    /// Cache of (rowKey → snapshot image) and (rowKey → OCR result text).
    /// rowKey is "<index>_app" or "<index>_cat" — stable as long as the
    /// underlying Set order doesn't shuffle within this view's lifetime.
    @State private var snapshots: [String: UIImage] = [:]
    @State private var ocr: [String: String] = [:]
    /// Stage 4: accessibility-tree probe result per row.
    /// VoiceOver requires a string for blind users — Apple may not redact this.
    @State private var ax: [String: String] = [:]
    @State private var busyKey: String? = nil
    @State private var batchProgress: String = ""

    /// Stage 5: drag-drop / context-menu probe.
    /// User-gesture paths sometimes leak hosted-view content where APIs don't
    /// (PHPicker has had this kind of leak in the past). Render a Label(token)
    /// + TextEditor target — the user manually drags / long-presses, and we
    /// log whatever NSItemProvider data the system attached.
    @State private var dropTextEditor: String = ""
    @State private var dropLog: String = ""
    @State private var pasteboardSnapshot: String = ""

    /// Stage 6: token decoder probe.
    /// Tests whether `String(describing: token)` or PropertyListEncoder's XML
    /// output leaks the bundle ID (claim from another AI). If true, we have a
    /// path that bypasses every other Apple privacy layer. If the dump shows
    /// only opaque bytes, the claim is hallucinated and we keep building lazy
    /// tagging.
    @State private var decoderDump: String = ""

    /// Stage 7: live picker metadata probe.
    /// CRITICAL: every previous test read `screenTimeManager.selectedApps`,
    /// which is plist-round-tripped (`applications` + `categories` arrays
    /// become empty by design, see ScreenTimeManager.swift line 49). So we've
    /// never seen what Apple's picker actually returns *at the moment it
    /// closes*. This probe binds an isolated FamilyActivitySelection to a
    /// fresh picker and dumps its `.applications` / `.categories` arrays the
    /// instant the picker dismisses — before any plist serialization touches
    /// it. If metadata is non-nil here, the bug is in our restore path, not
    /// Apple. If it's still nil, this device truly is metadata-starved.
    /// Match production picker init in HomeSettingsSheet / ScreenTimeManager —
    /// without `includeEntireCategory: true` the picker treats category-row taps
    /// as "tap each app in this category", not "select the whole category". So
    /// the category-token results from the previous build were not apples-to-apples
    /// with what the real Managed Apps flow produces.
    @State private var livePickerSelection = FamilyActivitySelection(includeEntireCategory: true)
    @State private var livePickerOpen = false
    @State private var livePickerDump: String = ""

    /// Stage 8: drawHierarchy probe — tests whether composited framebuffer
    /// pixels (already on screen) survive `drawHierarchy(in:afterScreenUpdates:)`,
    /// vs ImageRenderer's from-scratch render which strips privacy content.
    /// System screenshots preserve Label(token) content because they read the
    /// composited framebuffer. drawHierarchy may do the same.
    @State private var drawHierarchyResult: String = ""
    @State private var drawHierarchyImage: UIImage? = nil

    private var apps: [ApplicationToken] {
        Array(screenTimeManager.selectedApps.applicationTokens)
    }
    private var categories: [ActivityCategoryToken] {
        Array(screenTimeManager.selectedApps.categoryTokens)
    }

    var body: some View {
        List {
            Section {
                Text(
                    """
                    Renders `Label(token)` for the current Managed Apps selection. \
                    Each row has three checks:

                    1. Naked Label rendered on screen — visible name?
                    2. ImageRenderer snapshot — does pixel buffer keep the name?
                    3. Vision OCR — can code read it back?

                    If #2 is blank / shows a placeholder, Apple privacy-strips at \
                    snapshot time and OCR-tagging is a dead end on this device.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Stage 7: LIVE picker — bypasses our plist-round-trip code path
            // entirely. Opens a fresh picker, dumps metadata the instant it
            // closes. This is the only test that reflects what Apple
            // *actually* returns at picker time on this device.
            Section("LIVE picker metadata probe (Stage 7)") {
                Text("Opens an isolated picker (does NOT touch screenTimeManager.selectedApps). Pick a few apps + categories, then dismiss. We dump live metadata before any persistence touches it. If names show here, our previous tests were measuring the wrong thing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    // Reset with the same `includeEntireCategory: true` flag
                    // production uses — see HomeSettingsSheet / ScreenTimeManager.
                    livePickerSelection = FamilyActivitySelection(includeEntireCategory: true)
                    livePickerOpen = true
                } label: {
                    Label("Open fresh picker → dump live metadata", systemImage: "scope")
                }
                .buttonStyle(.borderedProminent)

                if !livePickerDump.isEmpty {
                    ScrollView(.horizontal) {
                        Text(livePickerDump)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .textSelection(.enabled)
                    }
                }
            }

            // Stage 6: token decoder probe — verify two claims from another AI
            // about leaking bundle ID via String(describing:) or XML plist.
            if !apps.isEmpty || !categories.isEmpty {
                Section("Token decoder probe") {
                    Text("Tests whether `String(describing: token)` or PropertyListEncoder XML output leaks the bundle ID. If yes, the dump below contains \"com.burbn.instagram\" (or similar). If no, you'll see opaque bytes only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        runDecoderProbe()
                    } label: {
                        Label("Dump first app + category token", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)

                    if !decoderDump.isEmpty {
                        ScrollView(.horizontal) {
                            Text(decoderDump)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            // Stage 8: drawHierarchy probe — captures composited framebuffer
            // (what's actually on screen) instead of re-rendering from scratch.
            // System screenshots work because they read the framebuffer where
            // FamilyControls daemon has already written the Label(token) pixels.
            // drawHierarchy(in:afterScreenUpdates:) may follow the same path.
            if !apps.isEmpty {
                Section("drawHierarchy probe (Stage 8)") {
                    Text(
                        "ImageRenderer re-renders → Apple strips. System screenshots read framebuffer → name visible. This tests whether `drawHierarchy(in:afterScreenUpdates:)` on the active window captures the already-composited Label(token) pixels, or also strips them."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button {
                        runDrawHierarchyProbe()
                    } label: {
                        Label("Capture window + OCR", systemImage: "rectangle.portrait.on.rectangle.portrait")
                    }
                    .buttonStyle(.borderedProminent)

                    if !drawHierarchyResult.isEmpty {
                        Text(drawHierarchyResult)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(drawHierarchyResult.hasPrefix("PASS") ? .green : .orange)
                            .padding(8)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    if let img = drawHierarchyImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            if let firstApp = apps.first {
                Section("Drop / paste / long-press probe") {
                    Text(
                        "Try every gesture you can think of. Long-press the Label below for a context menu. Try to drag it down into the editor. Try select-all + copy then paste."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    // The Label, dressed up to be drag-source-y. Wrapped in a
                    // contextMenu so iOS will show "Copy" if any text rep exists.
                    // No custom contextMenu — let iOS surface any system menu
                    // that may exist for Label(token). No onDrag with crafted
                    // NSItemProvider — we want to observe what iOS attaches
                    // automatically (if anything). Both wrappers were polluting
                    // earlier results.
                    HStack {
                        Spacer()
                        Label(firstApp)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 22, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)

                    Text("Drop / paste here:")
                        .font(.caption.bold())

                    TextEditor(text: $dropTextEditor)
                        .frame(minHeight: 100)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.tertiary))

                    HStack {
                        Button("Clear pasteboard") {
                            UIPasteboard.general.items = []
                            pasteboardSnapshot = "cleared"
                        }
                        .buttonStyle(.bordered)

                        Button("Deep inspect pasteboard") {
                            refreshPasteboardSnapshot()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if !pasteboardSnapshot.isEmpty {
                        Text(pasteboardSnapshot)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(40)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !dropLog.isEmpty {
                        Text(dropLog)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
            }

            if !categories.isEmpty {
                Section("Categories (\(categories.count))") {
                    ForEach(Array(categories.enumerated()), id: \.offset) { idx, tok in
                        categoryRow(idx: idx, token: tok)
                    }
                }
            }

            if !apps.isEmpty {
                Section("Apps (\(apps.count))") {
                    ForEach(Array(apps.enumerated()), id: \.offset) { idx, tok in
                        appRow(idx: idx, token: tok)
                    }
                }
            } else {
                Section("Apps") {
                    Text("No application tokens in current selection. Open Managed Apps & pick some.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Batch") {
                Button {
                    Task { await snapshotAll() }
                } label: {
                    Label(batchProgress.isEmpty ? "Snapshot + OCR all rows" : batchProgress,
                          systemImage: "wand.and.stars")
                }
                .disabled(busyKey != nil)

                Button {
                    Task { await axAll() }
                } label: {
                    Label("AX probe all rows", systemImage: "ear")
                }
                .disabled(busyKey != nil)
            }
        }
        .navigationTitle("Label(token) test")
        .navigationBarTitleDisplayMode(.inline)
        .familyActivityPicker(isPresented: $livePickerOpen, selection: $livePickerSelection)
        .onChange(of: livePickerOpen) { _, isOpen in
            // The picker dismissed — selection binding is now whatever Apple
            // wrote back. Dump every metadata field IMMEDIATELY, no plist round
            // trip, no syncAll, no save. This is the cleanest possible read.
            if !isOpen {
                dumpLivePickerSelection()
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func appRow(idx: Int, token: ApplicationToken) -> some View {
        let key = "\(idx)_app"
        VStack(alignment: .leading, spacing: 8) {
            // Stage 1: naked Label — what your eyes see on screen
            HStack(spacing: 8) {
                Text("[\(idx)]")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Label(token)
                    .labelStyle(.titleAndIcon)
                Spacer()
            }

            // Stage 2: snapshot preview
            if let img = snapshots[key] {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 56)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Stage 3: OCR result
            if let text = ocr[key] {
                ocrLine(text)
            }

            // Stage 4: accessibility-tree probe
            if let text = ax[key] {
                axLine(text)
            }

            HStack {
                Button {
                    Task { await runOne(token: .app(token), key: key) }
                } label: {
                    if busyKey == key {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Snapshot + OCR")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(busyKey != nil)

                Button {
                    Task { await runAX(token: .app(token), key: key) }
                } label: {
                    Text("AX probe")
                }
                .buttonStyle(.bordered)
                .disabled(busyKey != nil)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func categoryRow(idx: Int, token: ActivityCategoryToken) -> some View {
        let key = "\(idx)_cat"
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("[\(idx)]")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Label(token)
                    .labelStyle(.titleAndIcon)
                Spacer()
            }

            if let img = snapshots[key] {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 56)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let text = ocr[key] {
                ocrLine(text)
            }

            if let text = ax[key] {
                axLine(text)
            }

            HStack {
                Button {
                    Task { await runOne(token: .category(token), key: key) }
                } label: {
                    if busyKey == key {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Snapshot + OCR")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(busyKey != nil)

                Button {
                    Task { await runAX(token: .category(token), key: key) }
                } label: {
                    Text("AX probe")
                }
                .buttonStyle(.bordered)
                .disabled(busyKey != nil)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func axLine(_ text: String) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("AX:")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(trimmed.isEmpty ? "<empty>" : trimmed)
                .font(.caption.monospaced())
                .foregroundStyle(trimmed.isEmpty ? .red : .green)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func ocrLine(_ text: String) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("OCR:")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(trimmed.isEmpty ? "<empty>" : "\"\(trimmed)\"")
                .font(.caption.monospaced())
                .foregroundStyle(trimmed.isEmpty ? .red : .green)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Snapshot + OCR pipeline

    private enum Subject {
        case app(ApplicationToken)
        case category(ActivityCategoryToken)
    }

    @MainActor
    private func runOne(token: Subject, key: String) async {
        busyKey = key
        defer { busyKey = nil }
        let img = await snapshot(of: token)
        snapshots[key] = img
        if let img {
            ocr[key] = await recognizeText(in: img) ?? ""
        } else {
            ocr[key] = ""
        }
    }

    @MainActor
    private func snapshotAll() async {
        var done = 0
        let total = apps.count + categories.count
        for (i, tok) in categories.enumerated() {
            batchProgress = "Cat \(i + 1)/\(categories.count)…"
            await runOne(token: .category(tok), key: "\(i)_cat")
            done += 1
        }
        for (i, tok) in apps.enumerated() {
            batchProgress = "App \(i + 1)/\(apps.count)…"
            await runOne(token: .app(tok), key: "\(i)_app")
            done += 1
        }
        batchProgress = "Done — \(done)/\(total)"
    }

    /// Render a Label view containing the token to a UIImage. Fixed size so OCR
    /// gets predictable input. White background — Vision struggles with system
    /// chrome bleed-through on transparent renders.
    @MainActor
    private func snapshot(of subject: Subject) async -> UIImage? {
        let content = Group {
            switch subject {
            case .app(let t):
                Label(t).labelStyle(.titleAndIcon)
            case .category(let t):
                Label(t).labelStyle(.titleAndIcon)
            }
        }
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 360, height: 64, alignment: .leading)
        .background(Color.white)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 3.0
        renderer.proposedSize = ProposedViewSize(width: 360, height: 64)

        // Brief yield — ImageRenderer pulls synchronously but FamilyControls
        // Label may need a runloop tick to resolve icon/name.
        try? await Task.sleep(nanoseconds: 30_000_000)
        return renderer.uiImage
    }

    private func recognizeText(in image: UIImage) async -> String? {
        guard let cg = image.cgImage else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let req = VNRecognizeTextRequest { request, _ in
                let parts = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                cont.resume(returning: parts.joined(separator: " "))
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do {
                    try handler.perform([req])
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Stage 7: live picker metadata dump

    private func dumpLivePickerSelection() {
        var lines: [String] = []
        let s = livePickerSelection
        lines.append("=== Live picker selection ===")
        lines.append("includeEntireCategory = \(s.includeEntireCategory)")
        lines.append("applicationTokens.count = \(s.applicationTokens.count)")
        lines.append("categoryTokens.count = \(s.categoryTokens.count)")
        lines.append("webDomainTokens.count = \(s.webDomainTokens.count)")
        lines.append("applications.count = \(s.applications.count)")
        lines.append("categories.count = \(s.categories.count)")
        lines.append("")
        lines.append("--- Applications metadata ---")
        if s.applications.isEmpty {
            lines.append("(empty array — picker did not return any Application rows)")
        } else {
            for (i, app) in s.applications.enumerated() {
                let bid = app.bundleIdentifier ?? "<nil>"
                let name = app.localizedDisplayName ?? "<nil>"
                let hasTok = app.token != nil ? "✓" : "✗"
                lines.append("[\(i)] tok=\(hasTok) bundleID=\(bid) name=\(name)")
            }
        }
        lines.append("")
        lines.append("--- Categories metadata ---")
        if s.categories.isEmpty {
            lines.append("(empty array — picker did not return any Category rows)")
        } else {
            for (i, cat) in s.categories.enumerated() {
                let name = cat.localizedDisplayName ?? "<nil>"
                let hasTok = cat.token != nil ? "✓" : "✗"
                lines.append("[\(i)] tok=\(hasTok) name=\(name)")
            }
        }
        livePickerDump = lines.joined(separator: "\n")
    }

    // MARK: - Stage 6: token decoder probe

    private func runDecoderProbe() {
        var lines: [String] = []
        lines.append("=== Token decoder probe ===\n")

        if let app = apps.first {
            lines.append("--- App token [0] ---")
            lines.append("String(describing:): \(String(describing: app))")
            lines.append("type: \(type(of: app))")
            // PropertyListEncoder XML
            let xmlEnc = PropertyListEncoder()
            xmlEnc.outputFormat = .xml
            if let data = try? xmlEnc.encode(app) {
                let xml = String(data: data, encoding: .utf8) ?? "<not utf8>"
                lines.append("XML plist (\(data.count) bytes):")
                lines.append(xml)
                // Look for plaintext bundle ID heuristics
                if xml.contains("com.") || xml.contains("Instagram") {
                    lines.append("⚠ Found potential plaintext (com.* or 'Instagram') — DEEPSEEK MIGHT BE RIGHT")
                } else {
                    lines.append("(no `com.*` plaintext, no recognizable app name in XML)")
                }
            } else {
                lines.append("XML plist encode FAILED")
            }
            // Binary plist for comparison
            let binEnc = PropertyListEncoder()
            binEnc.outputFormat = .binary
            if let bin = try? binEnc.encode(app) {
                let hex = bin.prefix(64).map { String(format: "%02x", $0) }.joined()
                lines.append("Binary plist (\(bin.count) bytes), first 64: \(hex)")
            }
            // JSON for completeness
            if let json = try? JSONEncoder().encode(app),
               let s = String(data: json, encoding: .utf8) {
                lines.append("JSON: \(s)")
            }
            lines.append("")
        }

        if let cat = categories.first {
            lines.append("--- Category token [0] ---")
            lines.append("String(describing:): \(String(describing: cat))")
            lines.append("type: \(type(of: cat))")
            let xmlEnc = PropertyListEncoder()
            xmlEnc.outputFormat = .xml
            if let data = try? xmlEnc.encode(cat) {
                let xml = String(data: data, encoding: .utf8) ?? "<not utf8>"
                lines.append("XML plist (\(data.count) bytes):")
                lines.append(xml)
                if xml.contains("social") || xml.contains("games") || xml.contains("Social") {
                    lines.append("⚠ Found potential plaintext category name in XML")
                } else {
                    lines.append("(no recognizable category name in XML)")
                }
            }
            lines.append("")
        }

        decoderDump = lines.joined(separator: "\n")
    }

    // MARK: - Stage 5 helper: pasteboard inspection

    private func refreshPasteboardSnapshot() {
        let pb = UIPasteboard.general
        var lines: [String] = []
        lines.append("=== UIPasteboard.general ===")
        lines.append("changeCount = \(pb.changeCount)")
        lines.append("numberOfItems = \(pb.numberOfItems)")
        lines.append("hasStrings=\(pb.hasStrings) hasImages=\(pb.hasImages) hasURLs=\(pb.hasURLs)")
        lines.append("aggregate types = \(pb.types)")

        if let s = pb.string {
            lines.append("aggregate .string = \"\(s)\" (len=\(s.count))")
        } else {
            lines.append("aggregate .string = <nil>")
        }

        // pb.items is the authoritative dump — array of [type:Any] dictionaries.
        // Each Any is usually Data, NSString, NSURL, UIImage, or some platform
        // type. We dump everything we can extract, including hex preview of
        // raw bytes per type.
        for (i, item) in pb.items.enumerated() {
            lines.append("--- item[\(i)] (\(item.count) types) ---")
            for (key, value) in item {
                let cls = String(describing: type(of: value))
                if let d = value as? Data {
                    let hex = d.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
                    let asUTF8 = String(data: d, encoding: .utf8)
                    lines.append("  [\(key)] Data(\(d.count) bytes)")
                    lines.append("    hex: \(hex)\(d.count > 32 ? " …" : "")")
                    if let s = asUTF8, !s.isEmpty {
                        lines.append("    utf8: \"\(s)\"")
                    }
                } else if let s = value as? String {
                    lines.append("  [\(key)] String: \"\(s)\"")
                } else if let n = value as? NSString {
                    lines.append("  [\(key)] NSString: \"\(n)\"")
                } else if let u = value as? URL {
                    lines.append("  [\(key)] URL: \(u.absoluteString)")
                } else {
                    lines.append("  [\(key)] \(cls): \(String(describing: value).prefix(80))")
                }
            }
        }

        // Also try data(forPasteboardType:) for every advertised aggregate type
        // — the items dump above usually covers this, but Apple sometimes
        // routes data through this accessor only.
        for type in pb.types {
            if let d = pb.data(forPasteboardType: type) {
                let hex = d.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
                lines.append("data(forPasteboardType: \"\(type)\") -> \(d.count) bytes")
                lines.append("  hex: \(hex)\(d.count > 32 ? " …" : "")")
                if let s = String(data: d, encoding: .utf8), !s.isEmpty {
                    lines.append("  utf8: \"\(s)\"")
                }
            } else {
                lines.append("data(forPasteboardType: \"\(type)\") -> <nil>")
            }
        }

        pasteboardSnapshot = lines.joined(separator: "\n")
    }

    // MARK: - Stage 4: Accessibility-tree probe
    //
    // Theory: VoiceOver legally must read "Instagram" to blind users, so the
    // accessibility property tree on the underlying UIView likely carries the
    // string even when the rendering pipeline redacts it. Hosts the Label in
    // an off-screen UIWindow, walks the resulting view hierarchy, and reports
    // every accessibilityLabel / accessibilityValue / accessibilityIdentifier.

    @MainActor
    private func runAX(token subject: Subject, key: String) async {
        busyKey = key
        defer { busyKey = nil }
        let result = await probeAccessibility(of: subject)
        ax[key] = result ?? ""
    }

    @MainActor
    private func axAll() async {
        for (i, t) in categories.enumerated() {
            batchProgress = "AX cat \(i + 1)/\(categories.count)…"
            await runAX(token: .category(t), key: "\(i)_cat")
        }
        for (i, t) in apps.enumerated() {
            batchProgress = "AX app \(i + 1)/\(apps.count)…"
            await runAX(token: .app(t), key: "\(i)_app")
        }
        batchProgress = "Done"
    }

    @MainActor
    private func probeAccessibility(of subject: Subject) async -> String? {
        // Active foreground scene needed to attach a UIWindow that actually
        // runs layout + accessibility passes.
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return nil }

        let host: UIHostingController<AnyView>
        switch subject {
        case .app(let t):
            host = UIHostingController(rootView: AnyView(
                Label(t).labelStyle(.titleAndIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .padding()
            ))
        case .category(let t):
            host = UIHostingController(rootView: AnyView(
                Label(t).labelStyle(.titleAndIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .padding()
            ))
        }

        // Off-screen window. Must not be hidden — UIKit skips layout / a11y
        // tree generation on hidden windows. Tiny alpha keeps it invisible.
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: -2000, y: -2000, width: 360, height: 64)
        window.windowLevel = .alert + 1
        window.rootViewController = host
        window.alpha = 0.01
        window.isHidden = false

        host.view.frame = CGRect(x: 0, y: 0, width: 360, height: 64)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        // Two runloop ticks — first paint, then a11y propagation.
        try? await Task.sleep(nanoseconds: 150_000_000)

        let collected = walkAX(host.view)

        window.isHidden = true
        window.rootViewController = nil

        if collected.isEmpty { return nil }
        return collected.joined(separator: " | ")
    }

    /// Recursive walk gathering every non-empty a11y string with a tag of
    /// where it came from, so we can tell what part of the tree leaked the
    /// name (or whether all came back empty).
    private func walkAX(_ view: UIView) -> [String] {
        var out: [String] = []

        if let s = view.accessibilityLabel, !s.isEmpty {
            out.append("L=\"\(s)\"")
        }
        if let s = view.accessibilityValue, !s.isEmpty {
            out.append("V=\"\(s)\"")
        }
        if let s = view.accessibilityIdentifier, !s.isEmpty {
            out.append("ID=\"\(s)\"")
        }

        if let elems = view.accessibilityElements {
            for el in elems {
                if let v = el as? UIView {
                    out.append(contentsOf: walkAX(v))
                } else {
                    let obj = el as AnyObject
                    if let s = obj.accessibilityLabel, let s, !s.isEmpty {
                        out.append("eL=\"\(s)\"")
                    }
                    if let s = obj.accessibilityValue, let s, !s.isEmpty {
                        out.append("eV=\"\(s)\"")
                    }
                }
            }
        }

        for sub in view.subviews {
            out.append(contentsOf: walkAX(sub))
        }
        return out
    }

    // MARK: - Stage 8: drawHierarchy probe

    /// Captures the active window's framebuffer pixels via
    /// `drawHierarchy(in:afterScreenUpdates:)`. Unlike `ImageRenderer` which
    /// re-renders from scratch (invoking Apple's privacy strip), this reads
    /// the already-composited pixels — the same source as a system screenshot.
    /// If Label(token) name survives, we have a programmatic bulk-snapshot
    /// + OCR path that doesn't require manual screenshots.
    @MainActor
    private func runDrawHierarchyProbe() {
        drawHierarchyResult = ""
        drawHierarchyImage = nil

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else {
            drawHierarchyResult = "FAIL: no active window scene"
            return
        }

        guard let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else {
            drawHierarchyResult = "FAIL: no window"
            return
        }

        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)

        let image = renderer.image { ctx in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }

        drawHierarchyImage = image

        guard let cg = image.cgImage else {
            drawHierarchyResult = "FAIL: no CGImage"
            return
        }

        // OCR
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([req])
        } catch {
            drawHierarchyResult = "FAIL: OCR error \(error.localizedDescription)"
            return
        }

        let lines = (req.results as? [VNRecognizedTextObservation])?
            .compactMap { $0.topCandidates(1).first?.string } ?? []

        // Quick heuristic: does any known app name or bundle pattern appear?
        let hasCom = lines.contains { $0.contains("com.") }
        let partsJoined = lines.joined(separator: "\n")

        if hasCom || !lines.isEmpty {
            drawHierarchyResult = lines.isEmpty
                ? "PASS: image captured (\(image.size.width)x\(image.size.height)) but no text detected"
                : "PASS: OCR found \(lines.count) text lines\n\(partsJoined.prefix(500))"
        } else {
            drawHierarchyResult = "UNKNOWN: \(image.size.width)x\(image.size.height) image, 0 OCR lines. Check snapshot image below — if Label(token) is visually present but OCR found nothing, text rendering may be in a protected layer."
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        LabelTokenInspectorView()
            .environmentObject(ScreenTimeManager.shared)
    }
}
#endif
