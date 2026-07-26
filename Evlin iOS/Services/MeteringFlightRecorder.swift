import Foundation

/// A3 — the metering engine's flight recorder.
///
/// Every judgement point in the metering chain (callback arrival → guard
/// verdict → sample → re-arm → coverage → rollover) funnels through here and
/// lands in the SAME App-Group ring buffer + os_log the A0 `ScreenTimeEvent`
/// pipeline already owns, so the A1 `ScreenTimeEventUploader` ships them to the
/// backend timeline with no new transport. This is deliberately NOT a new
/// logging system — it is a typed, wire-safe front door onto `ScreenTimeEventLog`.
///
/// Why it exists: until now every dropped callback, wedged queue and coverage
/// flip was silent. `evlin.metering.lastV2ThresholdOutcome` keeps only the LAST
/// line, so the one drop that mattered was always already overwritten by the
/// time anyone looked. Events are additive — the three legacy debug defaults
/// keys are untouched.
///
/// ## Wire safety (load-bearing)
/// The backend rejects an over-long field with a 422 for the WHOLE batch, and
/// the uploader only advances its watermark when every POST succeeded — so one
/// 300-character `reason` would permanently stall the upload of every other
/// event on the device. Every string that leaves this type is therefore
/// truncated to the backend's column width before it is written:
///   `kind` ≤ 16 (enforced by `ScreenTimeEvent.Kind`'s raw values),
///   `reason` ≤ 64, `app` ≤ 255, `corr_id` ≤ 64.
///
/// Membership: this file MUST be in every target that links
/// `DeviceEpochStore` — `Evlin iOS`, `EvlinDeviceActivityMonitor` AND
/// `EvlinPushApplier` — because the store emits from whichever process the
/// callback landed in. (That is also why the day key is derived from
/// `MeteringEpochContract` instead of `EarnedTimeStore`: the push applier does
/// not link the earned-time store.)
nonisolated enum MeteringFlightRecorder {

    // MARK: - Backend column widths (see Evlin-Backend
    // `app/schemas/screen_time_events.py` + `db/models/screen_time_event.py`)

    static let reasonLimit = 64
    static let detailLimit = 255
    static let corrIDLimit = 64

    static let suiteName = "group.com.evlin.ios"

#if DEBUG
    /// Test-only sink. When set, events go here INSTEAD of the shared ring
    /// buffer, so a unit test can assert on emissions without racing another
    /// test through the App-Group defaults. Production never sets it (and it
    /// does not exist in Release).
    nonisolated(unsafe) static var testSink: ((ScreenTimeEvent) -> Void)?
#endif

    /// Truncates to a byte-safe prefix. Never returns more than `limit`
    /// characters, and marks the cut with `~` so a truncated line is obvious in
    /// the timeline instead of silently looking complete.
    static func clamp(_ value: String, to limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "~"
    }

    /// `"k=v k=v"` — the same shape the repo already writes into its
    /// `evlin.*` diagnostic defaults, so timeline and defaults read alike.
    /// Empty values are dropped rather than emitted as `k=`.
    static func detail(_ pairs: [(String, String)]) -> String {
        clamp(
            pairs
                .filter { !$0.1.isEmpty }
                .map { "\($0.0)=\($0.1)" }
                .joined(separator: " "),
            to: detailLimit
        )
    }

    /// First 8 hex characters of a UUID — enough to correlate a route/work item
    /// by eye in a log without eating the 255-character detail budget.
    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    static func shortID(_ id: UUID?) -> String {
        id.map(shortID) ?? "nil"
    }

    /// Collapses an error into one short, greppable token.
    static func describe(_ error: any Error) -> String {
        String(describing: error)
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Emission

    /// Emit one metering event.
    ///
    /// - Parameters:
    ///   - kind: the leg of the chain this event belongs to.
    ///   - source: which authority the event is about (defaults to the earned
    ///     pool, which is what the v2 metering engine meters).
    ///   - site: WHERE — a stable dotted identifier for the emission point
    ///     (`"store.callback"`, `"watchdog.selfcheck"`). Goes into `app`
    ///     together with `detail`, so a query can group by site.
    ///   - verdict: WHY — the short outcome word that lands in `reason`.
    ///   - detail: self-describing `k=v` pairs; see `detail(_:)`.
    ///   - nums: the numbers that made the decision (base / raw / threshold …).
    ///   - corrID: correlation id — route id or work id, so one rung's
    ///     callback → guard → sample legs join up.
    static func emit(
        kind: ScreenTimeEvent.Kind,
        source: ScreenTimeEvent.Source? = .earnedPool,
        site: String,
        verdict: String,
        detail: String = "",
        nums: ScreenTimeEvent.Nums? = nil,
        corrID: UUID? = nil,
        transition: ScreenTimeEvent.Transition? = nil
    ) {
        let event = makeEvent(
            kind: kind,
            source: source,
            site: site,
            verdict: verdict,
            detail: detail,
            nums: nums,
            corrID: corrID,
            transition: transition
        )
#if DEBUG
        if let testSink {
            testSink(event)
            return
        }
#endif
        for durable in suppressor.admit(event, now: Date()) {
            ScreenTimeEventLog.emit(durable)
        }
    }

    /// Callback arrival is useful diagnostic evidence, but it must not load and
    /// rewrite the full App-Group event ring before the constrained extension
    /// has persisted the sample. The completed verdict remains a durable event.
    static func emitCallbackArrival(
        site: String,
        detail: String = "",
        nums: ScreenTimeEvent.Nums? = nil,
        corrID: UUID? = nil
    ) {
        let event = makeEvent(
            kind: .meteringCallback,
            source: .earnedPool,
            site: site,
            verdict: "arrived",
            detail: detail,
            nums: nums,
            corrID: corrID,
            transition: nil
        )
#if DEBUG
        if let testSink {
            testSink(event)
            return
        }
#endif
        ScreenTimeEventLog.emitExtensionBreadcrumb(event)
    }

    private static func makeEvent(
        kind: ScreenTimeEvent.Kind,
        source: ScreenTimeEvent.Source?,
        site: String,
        verdict: String,
        detail: String,
        nums: ScreenTimeEvent.Nums?,
        corrID: UUID?,
        transition: ScreenTimeEvent.Transition?
    ) -> ScreenTimeEvent {
        let app = detail.isEmpty ? site : "\(site) \(detail)"
        return ScreenTimeEvent(
            ts: ISO8601DateFormatter().string(from: Date()),
            emitter: currentEmitter(),
            deviceID: currentDeviceID(),
            dayKey: currentDayKey(),
            kind: kind,
            source: source,
            app: clamp(app, to: detailLimit),
            reason: clamp(verdict, to: reasonLimit),
            nums: nums,
            transition: transition,
            policyGen: nil,
            corrID: corrID.map { clamp($0.uuidString, to: corrIDLimit) }
        )
    }

    /// Guards the shared ring buffer against a single repeating line erasing the
    /// evidence around it. Process-local: the flood this exists for is one
    /// process retrying the same work item.
    nonisolated(unsafe) private static let suppressorStorage = MeteringFlightRecorderSuppressor()

    static var suppressor: MeteringFlightRecorderSuppressor { suppressorStorage }

    /// Convenience for the "a `catch` used to be silent here" conversions.
    /// The `print`/`NSLog` at each site is deliberately KEPT — this only adds
    /// the durable, uploadable copy.
    static func emitError(
        site: String,
        error: any Error,
        detail: String = "",
        corrID: UUID? = nil
    ) {
        let errorPart = "err=\(describe(error))"
        emit(
            kind: .meteringError,
            site: site,
            verdict: "error",
            detail: clamp(detail.isEmpty ? errorPart : "\(detail) \(errorPart)", to: detailLimit),
            corrID: corrID
        )
    }

    /// Same as `emitError` but for a failure that is not an `Error` value
    /// (a rejected enum case, a `false` return, a stringly-typed report).
    static func emitFailure(
        site: String,
        verdict: String,
        detail: String = "",
        corrID: UUID? = nil
    ) {
        emit(kind: .meteringError, site: site, verdict: verdict, detail: detail, corrID: corrID)
    }

    // MARK: - Ambient context

    /// `.appex` bundles are the DeviceActivityMonitor extension; everything
    /// else running this code is the kid app. (The parent app never meters.)
    static func currentEmitter() -> ScreenTimeEvent.Emitter {
        Bundle.main.bundleURL.pathExtension == "appex" ? .kidExtension : .kidApp
    }

    private static var groupDefaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func currentDeviceID() -> String? {
        groupDefaults?.string(forKey: "evlin.childDeviceID")
            ?? UserDefaults.standard.string(forKey: "evlin.childDeviceID")
    }

    /// `"<yyyy-MM-dd>@<tz>"` in the backend policy timezone, matching what
    /// `EarnedTimeStore.currentPolicyDateContext()` produces.
    ///
    /// Deliberately derived from the App-Group key + `MeteringEpochContract`
    /// rather than from `EarnedTimeStore`: this file is compiled into the
    /// `EvlinPushApplier` extension too (it carries `DeviceEpochStore`), and
    /// that target must not have to link the whole earned-time store just to
    /// stamp a day key.
    static func currentDayKey() -> String {
        let timezoneIdentifier = groupDefaults?
            .string(forKey: "earned.runtimeTimezoneIdentifier")
            .flatMap { TimeZone(identifier: $0) == nil ? nil : $0 }
            ?? TimeZone.current.identifier
        let usageDate = MeteringEpochContract.canonicalUsageDate(
            at: Date(),
            timezoneIdentifier: timezoneIdentifier
        ) ?? "unknown"
        return "\(usageDate)@\(timezoneIdentifier)"
    }
}

/// Collapses byte-identical repeats so a stuck retry loop cannot erase the ring
/// buffer around it.
///
/// Measured on iPhone 2026-07-25: three install work items each re-recorded
/// `installer.install deferred:registrationRequired` every ~3 s — about 6 lines
/// a second — and filled all 2000 slots in 5.5 minutes. The day-rollover yield
/// and the tombstoning of a healthy route were pushed out of the buffer before
/// anyone could read them, so the recorder destroyed exactly the evidence it
/// exists to keep.
///
/// Contract:
///   * the FIRST occurrence of any content is always written immediately;
///   * identical repeats inside `window` are counted, not written;
///   * when the window closes, the next repeat is written once carrying
///     `repeat=N` — the count of everything collapsed into it, including
///     itself — and a new window opens;
///   * a change of content writes immediately and flushes the previous run's
///     tail summary first, so nothing is lost by ending a burst.
///
/// Never suppressed, whatever the rate:
///   * `.meteringError` — the lines that explain a failure;
///   * anything carrying a `transition` — a state jump is by definition news.
///
/// Suppression is keyed on the full content (kind, source, app, reason, numbers,
/// correlation id), so two work items that differ only by their id are two
/// independent runs, not one.
nonisolated final class MeteringFlightRecorderSuppressor: @unchecked Sendable {
    /// How long identical repeats collapse for. One minute keeps a stuck loop to
    /// ~1 line/minute (0.03 % of the buffer/hour) while still proving it is
    /// still stuck.
    static let defaultWindow: TimeInterval = 60

    /// Bounds the bookkeeping. Well above the handful of distinct lines any real
    /// loop produces; the oldest run is evicted when exceeded.
    static let maxTrackedRuns = 64

    private struct Run {
        var windowStartedAt: Date
        var lastSeenAt: Date
        var suppressedCount: Int
        var event: ScreenTimeEvent
    }

    private let window: TimeInterval
    private let lock = NSLock()
    private var runs: [String: Run] = [:]

    init(window: TimeInterval = MeteringFlightRecorderSuppressor.defaultWindow) {
        self.window = window
    }

    /// Returns the events that should actually be written — the candidate itself
    /// and/or tail summaries for runs whose window just closed. Empty means the
    /// candidate was collapsed into an open run.
    func admit(_ event: ScreenTimeEvent, now: Date) -> [ScreenTimeEvent] {
        guard isSuppressible(event) else {
            lock.lock()
            let tails = flushExpiredRuns(now: now, excluding: nil)
            lock.unlock()
            return tails + [event]
        }
        let key = signature(of: event)
        lock.lock()
        defer { lock.unlock() }
        var emitted = flushExpiredRuns(now: now, excluding: key)

        guard var run = runs[key] else {
            evictOldestIfNeeded()
            runs[key] = Run(
                windowStartedAt: now,
                lastSeenAt: now,
                suppressedCount: 0,
                event: event
            )
            emitted.append(event)
            return emitted
        }

        if now.timeIntervalSince(run.windowStartedAt) < window {
            run.suppressedCount += 1
            run.lastSeenAt = now
            run.event = event
            runs[key] = run
            return emitted
        }

        // Window closed with this occurrence: one line standing for all of them.
        let collapsed = run.suppressedCount + 1
        emitted.append(annotate(event, repeats: collapsed))
        runs[key] = Run(
            windowStartedAt: now,
            lastSeenAt: now,
            suppressedCount: 0,
            event: event
        )
        return emitted
    }

    /// Drops all bookkeeping. Tests only — production has one long-lived
    /// instance whose whole job is to remember.
    func reset() {
        lock.lock()
        runs.removeAll()
        lock.unlock()
    }

    // MARK: - Internals

    private func isSuppressible(_ event: ScreenTimeEvent) -> Bool {
        event.kind != .meteringError && event.transition == nil
    }

    /// Tail summaries for runs whose window has closed while they still hold
    /// collapsed occurrences. Without this a burst that simply STOPS would leave
    /// its count unrecorded.
    private func flushExpiredRuns(now: Date, excluding key: String?) -> [ScreenTimeEvent] {
        var flushed: [ScreenTimeEvent] = []
        for (runKey, run) in runs {
            guard runKey != key,
                  now.timeIntervalSince(run.windowStartedAt) >= window
            else { continue }
            if run.suppressedCount > 0 {
                flushed.append(annotate(run.event, repeats: run.suppressedCount))
            }
            runs.removeValue(forKey: runKey)
        }
        return flushed.sorted { $0.ts < $1.ts }
    }

    private func evictOldestIfNeeded() {
        guard runs.count >= Self.maxTrackedRuns,
              let oldest = runs.min(by: { $0.value.lastSeenAt < $1.value.lastSeenAt })?.key
        else { return }
        runs.removeValue(forKey: oldest)
    }

    private func annotate(_ event: ScreenTimeEvent, repeats: Int) -> ScreenTimeEvent {
        guard repeats > 1 else { return event }
        var annotated = event
        let base = event.app ?? ""
        annotated.app = MeteringFlightRecorder.clamp(
            base.isEmpty ? "repeat=\(repeats)" : "\(base) repeat=\(repeats)",
            to: MeteringFlightRecorder.detailLimit
        )
        return annotated
    }

    private func signature(of event: ScreenTimeEvent) -> String {
        [
            event.kind.rawValue,
            event.source?.rawValue ?? "",
            event.app ?? "",
            event.reason ?? "",
            event.corrID ?? "",
            event.nums.map { nums in
                [
                    nums.used, nums.budget, nums.poolUsed, nums.poolTotal,
                    nums.cap, nums.remaining, nums.rounded, nums.base,
                    nums.raw, nums.threshold, nums.excluded, nums.count, nums.http,
                ]
                .map { $0.map(String.init) ?? "" }
                .joined(separator: ",")
            } ?? "",
        ].joined(separator: "\u{1F}")
    }
}
