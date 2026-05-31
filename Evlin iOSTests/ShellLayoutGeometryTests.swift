import XCTest
@testable import Evlin_iOS

final class ShellLayoutGeometryTests: XCTestCase {
    func testNonChatContentInsetMatchesVisibleTabBarHeight() {
        XCTAssertEqual(
            ParentRootView.nonChatContentBottomInset,
            EvlinTabBar.visibleHeight
        )
    }

    func testTabIndicatorHasNoTopInsetInsideTabBar() {
        XCTAssertEqual(EvlinTabBar.indicatorTopInset, 0)
    }
}
