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
        // `allTasksDone` is `tasks.allSatisfy(...)` which is vacuously TRUE
        // on an empty array. On first render after a mode switch the kid
        // state is still loading: tasks=[] and minutesLeft=0 → would route
        // to .screenTimeFinished and flash "0 of 0" before real data
        // arrives. Gate on minutesMax > 0 (the kid was actually given some
        // time today) to suppress that empty-state flicker.
        if s.allTasksDone, s.minutesMax > 0, s.minutesLeft <= 0,
           !s.screenTimeFinishedAcknowledged {
            return .screenTimeFinished
        }
        // Same vacuous-truth concern: only route to dailyComplete when
        // there was at least one task to complete in the first place.
        if s.allTasksDone, !s.tasks.isEmpty, !s.dailyCompleteAcknowledged {
            return .dailyComplete
        }
        return .home
    }
}
