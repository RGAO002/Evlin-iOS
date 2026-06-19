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

    func testMessageListBottomPaddingDoesNotGrowWithKeyboardWhenScrollViewIsLifted() {
        XCTAssertEqual(
            ChatView.messageListBottomPadding(
                keyboardOverlap: 260,
                composerPanelHeight: 148,
                tabInset: 52,
                extraClearance: 28
            ),
            228
        )
    }

    func testContentChangesOnlyAutoPinWhenUserWasAlreadyNearBottom() {
        XCTAssertTrue(ChatView.shouldAutoPinAfterContentChange(previousBottomDistance: 0))
        XCTAssertTrue(ChatView.shouldAutoPinAfterContentChange(previousBottomDistance: 60))
        XCTAssertFalse(ChatView.shouldAutoPinAfterContentChange(previousBottomDistance: 140))
    }

    func testKeyboardShowDoesNotAutoPinTheScrollPosition() {
        XCTAssertFalse(
            ChatView.shouldAutoPinAfterKeyboardChange(
                previousBottomDistance: 0,
                previousKeyboardOverlap: 0,
                nextKeyboardOverlap: 260
            )
        )
        XCTAssertFalse(
            ChatView.shouldAutoPinAfterKeyboardChange(
                previousBottomDistance: 0,
                previousKeyboardOverlap: 260,
                nextKeyboardOverlap: 0
            )
        )
    }

    func testKeyboardContentLiftMatchesComposerLift() {
        XCTAssertEqual(ChatView.keyboardContentLift(keyboardOverlap: 0, tabInset: 52), 0)
        XCTAssertEqual(ChatView.keyboardContentLift(keyboardOverlap: 40, tabInset: 52), 0)
        XCTAssertEqual(ChatView.keyboardContentLift(keyboardOverlap: 260, tabInset: 52), 208)
    }

    func testBottomDistanceUsesTheActualScrollViewportHeight() {
        XCTAssertEqual(
            ChatView.scrollBottomDistance(contentMaxY: 740, scrollViewportHeight: 600),
            140
        )
        XCTAssertEqual(
            ChatView.scrollBottomDistance(contentMaxY: 480, scrollViewportHeight: 600),
            0
        )
    }

    func testScrollViewBottomDistanceUsesAdjustedBottomInset() {
        XCTAssertEqual(
            ChatView.scrollBottomDistance(
                contentOffsetY: 500,
                contentSizeHeight: 1200,
                viewportHeight: 600,
                adjustedBottomInset: 52
            ),
            152
        )
        XCTAssertEqual(
            ChatView.scrollBottomDistance(
                contentOffsetY: 652,
                contentSizeHeight: 1200,
                viewportHeight: 600,
                adjustedBottomInset: 52
            ),
            0
        )
    }

    func testScrollViewBottomDistanceUsesKeyboardInsetAfterPaddingIsFixed() {
        XCTAssertEqual(
            ChatView.scrollBottomDistance(
                contentOffsetY: 600,
                contentSizeHeight: 1200,
                viewportHeight: 600,
                adjustedBottomInset: 320
            ),
            320
        )
        XCTAssertEqual(
            ChatView.scrollBottomDistance(
                contentOffsetY: 920,
                contentSizeHeight: 1200,
                viewportHeight: 600,
                adjustedBottomInset: 320
            ),
            0
        )
    }

    func testScrollToBottomTargetUsesExactScrollableRange() {
        XCTAssertEqual(
            ChatView.scrollTargetOffsetY(
                contentSizeHeight: 1200,
                viewportHeight: 600,
                adjustedTopInset: 0,
                adjustedBottomInset: 52
            ),
            652
        )
        XCTAssertEqual(
            ChatView.scrollTargetOffsetY(
                contentSizeHeight: 420,
                viewportHeight: 600,
                adjustedTopInset: 12,
                adjustedBottomInset: 52
            ),
            -12
        )
    }

    func testScrollToBottomTargetUsesKeyboardInsetAfterPaddingIsFixed() {
        XCTAssertEqual(
            ChatView.scrollTargetOffsetY(
                contentSizeHeight: 1200,
                viewportHeight: 600,
                adjustedTopInset: 0,
                adjustedBottomInset: 320
            ),
            920
        )
    }

    func testAnimatedScrollToBottomSettlesAfterLayoutChanges() {
        XCTAssertEqual(ChatView.scrollToBottomSettleDelays(animated: false), [0])
        XCTAssertEqual(ChatView.scrollToBottomSettleDelays(animated: true), [0, 0.08, 0.18, 0.32])
    }

    func testScrollToBottomButtonAppearsOnlyAfterMeaningfulUpScroll() {
        XCTAssertFalse(ChatView.shouldShowScrollToBottomButton(bottomDistance: 0))
        XCTAssertFalse(ChatView.shouldShowScrollToBottomButton(bottomDistance: 60))
        XCTAssertFalse(ChatView.shouldShowScrollToBottomButton(bottomDistance: 140))
        XCTAssertTrue(ChatView.shouldShowScrollToBottomButton(bottomDistance: 220))
    }

    func testScrollToBottomButtonRestoresComposerFocusWhenKeyboardIsOpen() {
        XCTAssertTrue(
            ChatView.shouldRestoreComposerFocusAfterScrollToBottom(
                wasComposerFocused: false,
                keyboardOverlap: 260
            )
        )
        XCTAssertTrue(
            ChatView.shouldRestoreComposerFocusAfterScrollToBottom(
                wasComposerFocused: true,
                keyboardOverlap: 0
            )
        )
        XCTAssertFalse(
            ChatView.shouldRestoreComposerFocusAfterScrollToBottom(
                wasComposerFocused: false,
                keyboardOverlap: 0
            )
        )
    }

    @MainActor
    func testKeyboardDismissGateSuppressesOnlyTheNextRootTap() {
        let now = Date()
        KeyboardDismissGate.resetForTesting()

        KeyboardDismissGate.suppressNextRootTapDismissal(for: 0.5, now: now)

        XCTAssertFalse(KeyboardDismissGate.shouldDismissKeyboardForRootTap(now: now.addingTimeInterval(0.1)))
        XCTAssertTrue(KeyboardDismissGate.shouldDismissKeyboardForRootTap(now: now.addingTimeInterval(0.2)))
    }

    @MainActor
    func testKeyboardDismissGateExpires() {
        let now = Date()
        KeyboardDismissGate.resetForTesting()

        KeyboardDismissGate.suppressNextRootTapDismissal(for: 0.5, now: now)

        XCTAssertTrue(KeyboardDismissGate.shouldDismissKeyboardForRootTap(now: now.addingTimeInterval(0.6)))
    }
}
