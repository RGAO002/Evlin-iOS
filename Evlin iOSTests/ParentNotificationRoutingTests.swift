import XCTest
@testable import Evlin_iOS

final class ParentNotificationRoutingTests: XCTestCase {
    private let child = ChildProfile(
        id: "11111111-1111-1111-1111-111111111111",
        name: "Liam",
        age: 9,
        avatarURL: nil,
        accentColor: .evPrimary,
        status: .unlocked,
        timeLeft: "2h",
        timePct: 1,
        subtitle: ""
    )

    func testNotificationTapExtractsNestedEventIDFromAPNsPayload() {
        let eventID = "22222222-2222-2222-2222-222222222222"

        let extracted = AppDelegate.notificationEventID(from: [
            "aps": ["alert": "Reflection submitted"],
            "evlin": ["kind": "notification_alert", "event_id": eventID],
        ])

        XCTAssertEqual(extracted, eventID)
    }

    func testReflectionCompletedNotificationRoutesDirectlyToReflectionTab() {
        let eventID = "33333333-3333-3333-3333-333333333333"
        let notification = makeNotification(
            eventID: eventID,
            childProfileId: child.id,
            type: "reflection_completed"
        )

        let route = ParentNotificationRouteResolver.route(
            for: notification,
            children: [child]
        )

        guard case .appRoute(.profileReflection(let routedChild, let reflectionID)) = route else {
            return XCTFail("Expected profileReflection route, got \(String(describing: route))")
        }
        XCTAssertEqual(routedChild.id, child.id)
        XCTAssertEqual(reflectionID.uuidString.lowercased(), eventID)
    }

    func testKidNudgeNotificationRoutesDirectlyToReflectionTab() {
        let eventID = "44444444-4444-4444-4444-444444444444"
        let notification = makeNotification(
            eventID: eventID,
            childProfileId: child.id,
            type: "kid_nudged_parent"
        )

        let route = ParentNotificationRouteResolver.route(
            for: notification,
            children: [child]
        )

        guard case .appRoute(.profileReflection(let routedChild, let reflectionID)) = route else {
            return XCTFail("Expected profileReflection route, got \(String(describing: route))")
        }
        XCTAssertEqual(routedChild.id, child.id)
        XCTAssertEqual(reflectionID.uuidString.lowercased(), eventID)
    }

    func testPlainChildDeepLinkRoutesToChildProfile() {
        let notification = makeNotification(
            eventID: "55555555-5555-5555-5555-555555555555",
            childProfileId: child.id,
            type: "command_applied",
            deepLink: ["route": "deviceDetail", "child_profile_id": child.id]
        )

        let route = ParentNotificationRouteResolver.route(
            for: notification,
            children: [child]
        )

        guard case .appRoute(.profile(let routedChild, _)) = route else {
            return XCTFail("Expected profile route, got \(String(describing: route))")
        }
        XCTAssertEqual(routedChild.id, child.id)
    }

    func testTaskReviewNotificationRoutesToBackendTaskDetail() {
        let taskID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let notification = makeNotification(
            eventID: "88888888-8888-8888-8888-888888888888",
            childProfileId: child.id,
            type: "task_submitted",
            deepLink: [
                "route": "taskReview",
                "child_id": "99999999-9999-9999-9999-999999999999",
                "task_id": taskID.uuidString,
            ]
        )

        let route = ParentNotificationRouteResolver.route(
            for: notification,
            children: [child]
        )

        guard case .appRoute(.taskDetailByBackendID(let routedChild, let routedTaskID)) = route else {
            return XCTFail("Expected backend task detail route, got \(String(describing: route))")
        }
        XCTAssertEqual(routedChild.id, child.id)
        XCTAssertEqual(routedTaskID, taskID)
    }

    func testPendingNotificationOpenStoreConsumesEventOnce() {
        let defaults = UserDefaults(suiteName: "ParentNotificationRoutingTests-\(UUID().uuidString)")!
        let store = PendingNotificationOpenStore(defaults: defaults)
        let eventID = "66666666-6666-6666-6666-666666666666"

        store.save(eventID)

        XCTAssertEqual(store.consume(), eventID)
        XCTAssertNil(store.consume())
    }

    private func makeNotification(
        eventID: String,
        childProfileId: String?,
        type: String,
        deepLink: [String: String]? = nil
    ) -> FeedNotification {
        FeedNotification(
            id: "recipient-\(eventID)",
            eventId: eventID,
            childProfileId: childProfileId,
            type: type,
            urgency: "normal_push_active",
            title: nil,
            body: nil,
            renderKey: nil,
            renderArgs: nil,
            deepLink: deepLink,
            createdAt: nil,
            readAt: nil
        )
    }
}
