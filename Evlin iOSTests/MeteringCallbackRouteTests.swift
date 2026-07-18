import XCTest
@testable import Evlin_iOS

final class MeteringCallbackRouteTests: XCTestCase {
    private let routeID = UUID(uuidString: "12345678-1234-5678-9abc-def012345678")!

    func testNamesUseTheExactV2NamespaceAndLowercaseRouteUUID() {
        XCTAssertEqual(
            MeteringRouteNamespace.activityName(routeID: routeID),
            "evlin.earned.v2.12345678-1234-5678-9abc-def012345678"
        )
        XCTAssertEqual(
            MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: 15),
            "evlin.earned.v2.12345678-1234-5678-9abc-def012345678.t15"
        )
    }

    func testParserAcceptsOnlyMatchingStrictRouteNames() {
        let activity = MeteringRouteNamespace.activityName(routeID: routeID)
        let event = MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: 15)

        XCTAssertEqual(
            MeteringRouteNamespace.parse(activityName: activity, eventName: event),
            ParsedMeteringRouteName(routeID: routeID, thresholdMinutes: 15)
        )
    }

    func testParserRejectsMalformedRouteMismatchedRouteExtraSegmentsAndInvalidThresholds() {
        let activity = MeteringRouteNamespace.activityName(routeID: routeID)
        let rejectedPairs = [
            ("evlin.earned.v2.not-a-uuid", "evlin.earned.v2.not-a-uuid.t5"),
            (activity, "evlin.earned.v2.aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.t5"),
            ("\(activity).extra", "\(activity).t5"),
            (activity, "\(activity).t5.extra"),
            (activity, "\(activity).t0"),
            (activity, "\(activity).t-1"),
            (activity, "\(activity).t01"),
            (activity, "\(activity).tfoo"),
            ("evlin.earned.v2.12345678-1234-5678-9ABC-DEF012345678", "evlin.earned.v2.12345678-1234-5678-9ABC-DEF012345678.t5"),
            (activity, "\(activity).t١"),
            (activity, "evlin.earned.v1.12345678-1234-5678-9abc-def012345678.t5"),
            (activity, "other.earned.v2.12345678-1234-5678-9abc-def012345678.t5"),
        ]

        for (invalidActivity, invalidEvent) in rejectedPairs {
            XCTAssertNil(
                MeteringRouteNamespace.parse(activityName: invalidActivity, eventName: invalidEvent),
                "\(invalidActivity) / \(invalidEvent)"
            )
        }
    }
}
