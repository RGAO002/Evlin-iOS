import Foundation

/// Injectable time source so tests never rely on real timers (CI stability).
protocol TypewriterClock { var now: TimeInterval { get } }
struct SystemClock: TypewriterClock {
    var now: TimeInterval { Date().timeIntervalSinceReferenceDate }
}

/// Display-only reveal engine (spec §5.3). REALTIME FIRST: reveal rate =
/// max(base, arrival rate); finalize() must complete within 200 ms. Never
/// buffers arrival — only presentation.
///
/// `nonisolated` opts this class out of the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` default. Without it the class
/// is implicitly `@MainActor`, and its synthesized deinit routes through
/// `swift_task_deinitOnExecutorMainActorBackDeploy`, which double-frees on
/// dealloc under this toolchain (SIGABRT in every test that lets an instance
/// deallocate — see `AppLimitPlanner`/`EvlinPINStore` for the same fix).
/// `@unchecked Sendable` matches those types; a later task binds this engine
/// to a single bubble's view state on the main actor via `onChange`, so the
/// mutable state here is not shared across threads in practice.
nonisolated final class TypewriterEngine: @unchecked Sendable {
    private(set) var revealed: String = ""
    var onChange: ((String) -> Void)?
    private var buffer: String = ""
    private var finalized = false
    private var finalizeTicksRemaining = 0
    private let tickInterval: TimeInterval
    private let clock: TypewriterClock

    var bufferForTesting: String { buffer }

    init(clock: TypewriterClock = SystemClock(), tickInterval: TimeInterval = 0.03) {
        self.clock = clock
        self.tickInterval = tickInterval
    }

    func append(_ text: String) {
        guard !finalized else { return }
        buffer += text
    }

    func finalize(with authoritative: String) {
        finalized = true
        if !authoritative.hasPrefix(revealed) {
            revealed = ""                       // mismatched prefix: envelope wins
        }
        buffer = authoritative
        // Deadline countdown: whatever the backlog, drain it across the
        // remaining ticks so the 200 ms guarantee holds for ANY length.
        finalizeTicksRemaining = max(1, Int((0.2 / tickInterval).rounded(.down)))
    }

    func tick() {
        let backlog = buffer.count - revealed.count
        guard backlog > 0 else { return }
        var step = max(1, Int((Double(backlog) / 6.0).rounded(.up)))
        if finalized {
            let ticks = max(1, finalizeTicksRemaining)
            step = max(step, Int((Double(backlog) / Double(ticks)).rounded(.up)))
            finalizeTicksRemaining = ticks - 1
        }
        let end = buffer.index(buffer.startIndex,
                               offsetBy: min(revealed.count + step, buffer.count))
        revealed = String(buffer[..<end])
        onChange?(revealed)
    }
}
