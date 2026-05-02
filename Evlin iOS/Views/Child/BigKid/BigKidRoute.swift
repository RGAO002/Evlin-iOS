import Foundation

enum BigKidRoute: Equatable {
    case home
    case homeReflectionA       // reflection in progress (stepsCompleted < 3)
    case homeReflectionB       // reflection 3/3 done, awaiting parent
    case complete              // reflection approved by parent, awaiting kid ack
    case dailyComplete
    case screenTimeFinished
}

enum BigKidRouter {
    /// Pure routing decision per spec §5. Inputs are server-mirrored fields
    /// from `BigKidState`; nothing local.
    static func route(_ s: BigKidState) -> BigKidRoute {
        if let req = s.reflectionRequest, req.status == .approved {
            return .complete
        }
        if let req = s.reflectionRequest {
            return req.stepsCompleted.count >= 3 ? .homeReflectionB : .homeReflectionA
        }
        if s.allTasksDone, s.minutesLeft <= 0, !s.screenTimeFinishedAcknowledged {
            return .screenTimeFinished
        }
        if s.allTasksDone, !s.dailyCompleteAcknowledged {
            return .dailyComplete
        }
        return .home
    }
}
