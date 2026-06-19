import Foundation

@MainActor
enum KeyboardDismissGate {
    private static var suppressRootTapDismissalUntil: Date?

    static func suppressNextRootTapDismissal(
        for seconds: TimeInterval = 0.5,
        now: Date = Date()
    ) {
        suppressRootTapDismissalUntil = now.addingTimeInterval(seconds)
    }

    static func shouldDismissKeyboardForRootTap(now: Date = Date()) -> Bool {
        defer { suppressRootTapDismissalUntil = nil }
        guard let suppressRootTapDismissalUntil else { return true }
        return now > suppressRootTapDismissalUntil
    }

    #if DEBUG
    static func resetForTesting() {
        suppressRootTapDismissalUntil = nil
    }
    #endif
}
