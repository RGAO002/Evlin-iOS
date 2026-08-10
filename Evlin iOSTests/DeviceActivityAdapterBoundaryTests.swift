import Foundation
import XCTest

/// Static guardrail for the DeviceActivity boundary.
///
/// Constructing `DeviceActivityCenter()` outside an adapter bypasses both the
/// off-main gateway and the main-thread audit at once, which is exactly how the
/// blocking surface grew to roughly twenty sites without anyone noticing. Three
/// of them were invisible to a `startMonitoring` grep because they read like
/// property access (`activities`, `schedule(for:)`, `events(for:)`), and two more
/// were invisible to a dynamic sweep because they only run on paths a test pass
/// never takes.
///
/// This is deliberately a static check rather than a runtime assertion. A trap
/// stops at the first offender and cannot see code that did not run; a scan sees
/// every site every build. Both are kept — the audit finds what actually fires,
/// this finds what could.
///
/// The rule is narrow on purpose: it bans only direct construction of the
/// center. Calling `startMonitoring` on an injected `DeviceActivityScheduling`
/// is the intended pattern and stays legal, and so does the whole
/// `DeviceActivitySchedule` / `DeviceActivityEvent` modelling vocabulary.
final class DeviceActivityAdapterBoundaryTests: XCTestCase {

    /// Files allowed to construct the center. Each one instruments its own calls
    /// with `DeviceActivityMainThreadAudit` — that is the price of being here.
    ///
    /// The DeviceActivityMonitor extension is out of scope entirely: it runs in
    /// its own process, off the main thread, and is not subject to the app's
    /// scene-update watchdog.
    private static let adapters: Set<String> = [
        "DeviceActivitySchedulingPort.swift",   // DeviceActivityCenterScheduler
        "MeteringDeviceActivityCenter.swift",   // SystemMeteringDeviceActivityCenter
        "BigKidActivityScheduler.swift",
        "EarnedBudgetScheduler.swift",
    ]

    /// Known, accepted exceptions. Each needs a reason, and "it was already like
    /// that" is not one — these are the sites judged not worth routing, not the
    /// ones nobody got round to.
    private static let acceptedExceptions: [String: String] = [
        // Debug-only screens, never on a production path. They are still real
        // blocking calls, so they stay listed rather than silently excluded.
        "WholeDeviceThresholdProbeView.swift": "debug probe screen",
        "AppLimitOneMinuteProbeView.swift": "debug probe screen",
        // Diagnostics reader: a parameter default on a read-only inspector used
        // by the debug screens.
        "MeteringDaemonDiagnostics.swift": "diagnostics reader, debug entry only",
    ]

    func testNoOneConstructsTheCenterOutsideAnAdapter() throws {
        let offenders = try scanAppSources { path, line, text in
            // Only the RAW center. `SystemMeteringDeviceActivityCenter()` is the
            // audited wrapper, so constructing that is the intended pattern —
            // matching on a bare substring flags it and buries the real hits.
            guard Self.constructsRawCenter(text) else { return nil }
            let file = path.lastPathComponent
            guard !Self.adapters.contains(file) else { return nil }
            guard Self.acceptedExceptions[file] == nil else { return nil }
            return "\(file):\(line)  \(text.trimmingCharacters(in: .whitespaces))"
        }
        XCTAssertEqual(
            offenders,
            [],
            """
            DeviceActivityCenter is constructed outside an adapter. Every one of \
            these is a synchronous XPC call that bypasses both the off-main \
            gateway and the main-thread audit — the shape that got the app killed \
            by the watchdog on 2026-08-08.

            Either take an injected `DeviceActivityScheduling` /
            `MeteringDeviceActivityCenter`, or — if this really is a new adapter \
            — add its `DeviceActivityMainThreadAudit.noteIfOnMainThread` calls and \
            list it in `adapters` above.

            Offenders:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Every adapter has to actually audit itself, or being on the allowlist is
    /// just a hole with paperwork.
    func testEveryAdapterAuditsItself() throws {
        let root = Self.appSourceRoot()
        var missing: [String] = []
        for adapter in Self.adapters.sorted() {
            guard let url = try Self.find(adapter, under: root) else {
                missing.append("\(adapter) (not found — renamed or deleted?)")
                continue
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            if !text.contains("DeviceActivityMainThreadAudit.noteIfOnMainThread") {
                missing.append("\(adapter) (no audit calls)")
            }
        }
        XCTAssertEqual(
            missing,
            [],
            "allowlisted adapters that do not audit their own calls: \(missing)"
        )
    }

    /// True when `text` constructs `DeviceActivityCenter` itself, as opposed to
    /// one of the wrappers whose names end in it.
    private static func constructsRawCenter(_ text: String) -> Bool {
        let needle = "DeviceActivityCenter("
        var search = text[...]
        while let range = search.range(of: needle) {
            let identifierStart = range.lowerBound
            let precededByIdentifier: Bool
            if identifierStart > text.startIndex {
                let previous = text[text.index(before: identifierStart)]
                precededByIdentifier = previous.isLetter || previous.isNumber || previous == "_"
            } else {
                precededByIdentifier = false
            }
            if !precededByIdentifier { return true }
            search = text[range.upperBound...]
        }
        return false
    }

    // MARK: - Scanning

    private static func appSourceRoot() -> URL {
        // .../Evlin iOSTests/DeviceActivityAdapterBoundaryTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Evlin iOSTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Evlin iOS")
    }

    private static func find(_ name: String, under root: URL) throws -> URL? {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    /// Runs `inspect` over every line of every Swift file in the app target,
    /// skipping `//` comments so a doc comment naming the type is not an
    /// offender.
    private func scanAppSources(
        _ inspect: (URL, Int, String) -> String?
    ) throws -> [String] {
        let root = Self.appSourceRoot()
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("could not walk \(root.path) — has the layout changed?")
            return []
        }
        var findings: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(raw)
                let code = line.components(separatedBy: "//").first ?? line
                if let finding = inspect(url, index + 1, code) {
                    findings.append(finding)
                }
            }
        }
        return findings.sorted()
    }
}
