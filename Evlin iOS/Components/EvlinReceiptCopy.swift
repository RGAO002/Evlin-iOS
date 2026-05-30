import Foundation

/// Single source of truth for honest receipt + review copy. Confirmations say
/// Evlin applied the rule on the kid device, never that Apple/iOS guaranteed
/// enforcement. Lock Activity Review copy is audit-only, not verification.
enum EvlinReceiptCopy {
    /// Shown under every successful lock receipt.
    static let appliedOnKidDevice = "Evlin applied this lock on Kid's iPhone"

    /// Lock Activity Review disclaimers.
    static let reviewIsBestEffort =
        "Best-effort review. Missing usage data is not proof the app went unused."
    static let reviewUsageDuringWindow =
        "This app may not have been blocked — try refreshing Screen Time control / re-binding the app."
}
