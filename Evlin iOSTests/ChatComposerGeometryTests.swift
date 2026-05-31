import XCTest
@testable import Evlin_iOS

final class ChatComposerGeometryTests: XCTestCase {
    func testKeyboardOverlapUsesCurrentViewFrameNotWholeScreen() {
        let viewFrame = CGRect(x: 0, y: 0, width: 768, height: 600)
        let keyboardFrame = CGRect(x: 0, y: 420, width: 768, height: 300)

        XCTAssertEqual(
            ChatView.keyboardOverlap(keyboardFrameEnd: keyboardFrame, viewFrame: viewFrame),
            180
        )
    }

    func testKeyboardOverlapIsZeroWhenKeyboardDoesNotCoverView() {
        let viewFrame = CGRect(x: 0, y: 0, width: 768, height: 600)
        let keyboardFrame = CGRect(x: 0, y: 620, width: 768, height: 120)

        XCTAssertEqual(
            ChatView.keyboardOverlap(keyboardFrameEnd: keyboardFrame, viewFrame: viewFrame),
            0
        )
    }

    func testComposerBottomInsetWaitsUntilKeyboardReachesComposerBottom() {
        XCTAssertEqual(ChatView.composerBottomInset(keyboardOverlap: 0), EvlinTabBar.visibleHeight)
        XCTAssertEqual(
            ChatView.composerBottomInset(
                keyboardOverlap: EvlinTabBar.visibleHeight - 1,
                tabInset: EvlinTabBar.visibleHeight
            ),
            EvlinTabBar.visibleHeight
        )
        XCTAssertEqual(ChatView.composerBottomInset(keyboardOverlap: 180), 180)
    }

    func testKeyboardLiftDelayMatchesTabInsetShareOfKeyboardTravel() {
        XCTAssertEqual(
            ChatView.keyboardLiftDelay(keyboardOverlap: 200, tabInset: 50, duration: 0.4),
            0.1,
            accuracy: 0.001
        )
        XCTAssertEqual(ChatView.keyboardLiftDelay(keyboardOverlap: 40, tabInset: 50, duration: 0.4), 0)
    }

    func testKeyboardLiftTimingFinishesWithKeyboardAfterDelayedStart() {
        let timing = ChatView.keyboardLiftTiming(keyboardOverlap: 200, tabInset: 50, duration: 0.4)

        XCTAssertEqual(timing.delay, 0.1, accuracy: 0.001)
        XCTAssertEqual(timing.activeDuration, 0.3, accuracy: 0.001)
    }

    func testKeyboardDropTimingOnlyAnimatesWhileKeyboardStillTouchesComposer() {
        let timing = ChatView.keyboardDropTiming(currentKeyboardOverlap: 200, tabInset: 50, duration: 0.4)

        XCTAssertEqual(timing.delay, 0, accuracy: 0.001)
        XCTAssertEqual(timing.activeDuration, 0.3, accuracy: 0.001)
    }

    func testMessageListBottomPaddingClearsComposerPanelAndTabBar() {
        XCTAssertEqual(
            ChatView.messageListBottomPadding(
                composerPanelHeight: 148,
                tabInset: 52,
                extraClearance: 28
            ),
            228
        )
    }
}
