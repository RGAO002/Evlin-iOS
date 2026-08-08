import Foundation

enum ParentPINRecovery {
    struct Cursor: Codable, Equatable, Sendable {
        var length: Int
        var next: Int
    }

    enum Outcome: Equatable, Sendable {
        case found(String)
        case exhausted
        case budgetSpent(Cursor)
    }

    nonisolated static let startCursor = Cursor(length: 4, next: 0)
    nonisolated static let autoMaxLength = 6

    nonisolated static func sweep(
        salt: Data,
        digest: Data,
        from cursor: Cursor,
        budget: Int,
        maxLength: Int
    ) -> Outcome {
        var length = cursor.length
        var index = cursor.next
        var spent = 0
        while length <= maxLength {
            let end = powerOfTen(length)
            while index < end {
                if spent >= budget {
                    return .budgetSpent(Cursor(length: length, next: index))
                }
                let raw = String(index)
                let candidate = String(repeating: "0", count: max(0, length - raw.count)) + raw
                if EvlinPINStore.recoveryDigest(salt: salt, candidate: candidate) == digest {
                    return .found(candidate)
                }
                index += 1
                spent += 1
            }
            length += 1
            index = 0
        }
        return .exhausted
    }

    nonisolated private static func powerOfTen(_ exponent: Int) -> Int {
        (0..<exponent).reduce(1) { value, _ in value * 10 }
    }
}
