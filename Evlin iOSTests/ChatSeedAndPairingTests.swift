//
//  ChatSeedAndPairingTests.swift
//  Evlin iOSTests
//
//  Go-live Chat P0: proves a fresh install seeds a neutral welcome (no fake
//  lock receipt, no fake StrategyCard) and that the pure unpaired-guard
//  decision is correct across the family_id × child_device matrix.
//

import XCTest
@testable import Evlin_iOS

@MainActor
final class ChatSeedAndPairingTests: XCTestCase {

    private let historyKey = "evlin_chat_history"

    override func setUp() {
        super.setUp()
        // Force a "fresh install" — no persisted chat history.
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: historyKey)
        super.tearDown()
    }

    // MARK: - C1: neutral welcome seed

    func testFreshInstallSeedsSingleNeutralWelcome() {
        let vm = ChatViewModel()
        // Exactly one welcome bubble — not the old 3-bubble fabrication.
        XCTAssertEqual(vm.messages.count, 1, "fresh install must seed exactly one neutral welcome bubble")
        XCTAssertEqual(vm.messages.first?.role, .agent)
    }

    func testFreshInstallSeedsNoFakeLockReceipt() {
        let vm = ChatViewModel()
        for m in vm.messages {
            XCTAssertNil(m.receiptState, "neutral welcome must not carry a receipt")
            XCTAssertNil(m.commandID, "neutral welcome must not carry a command id")
            XCTAssertFalse(
                m.content.lowercased().contains("confirmed the manual lock"),
                "fresh install must not claim a manual lock was confirmed"
            )
        }
    }

    func testFreshInstallSeedsNoFakeStrategyCard() {
        let vm = ChatViewModel()
        for m in vm.messages {
            XCTAssertFalse(m.isStrategyArtifact, "fresh install must not seed a StrategyCard")
            XCTAssertNil(m.videoId, "fresh install must not seed a hardcoded YouTube video")
            XCTAssertNil(m.strategyTitle)
        }
    }

    // MARK: - C2: pure unpaired-guard decision

    func testIsUnpairedTruthTable() {
        let fam = UUID()
        let dev = UUID()
        // Paired: both present → NOT unpaired.
        XCTAssertFalse(ChatViewModel.isUnpaired(familyID: fam, childDeviceID: dev))
        // Missing family → unpaired.
        XCTAssertTrue(ChatViewModel.isUnpaired(familyID: nil, childDeviceID: dev))
        // Missing child device → unpaired (nothing to queue a command to).
        XCTAssertTrue(ChatViewModel.isUnpaired(familyID: fam, childDeviceID: nil))
        // Neither → unpaired.
        XCTAssertTrue(ChatViewModel.isUnpaired(familyID: nil, childDeviceID: nil))
    }

    // MARK: - C2: unpaired sendMessage blocks the POST + shows a CTA

    func testUnpairedSendMessageBlocksDispatchAndShowsCTA() {
        // Force the unpaired state by clearing the pairing UserDefaults keys.
        UserDefaults.standard.removeObject(forKey: "evlin.familyID")
        UserDefaults.standard.removeObject(forKey: "evlin.childDeviceID")
        defer {
            UserDefaults.standard.removeObject(forKey: "evlin.familyID")
            UserDefaults.standard.removeObject(forKey: "evlin.childDeviceID")
        }

        let vm = ChatViewModel()
        let baseline = vm.messages.count   // 1 (neutral welcome)
        vm.inputText = "lock instagram for 30 minutes"
        vm.sendMessage()

        // No "thinking" spinner — we never dispatched.
        XCTAssertFalse(vm.isThinking, "unpaired send must not enter the thinking/dispatch state")
        // The composer is NOT cleared, so the parent can retry after pairing.
        XCTAssertEqual(vm.inputText, "lock instagram for 30 minutes",
                       "unpaired send must keep the typed text")
        // Exactly one new bubble appended (the agent CTA). No user bubble was added.
        XCTAssertEqual(vm.messages.count, baseline + 1)
        let last = vm.messages.last
        XCTAssertEqual(last?.role, .agent, "the only new bubble must be the agent pairing CTA")
        XCTAssertTrue(
            (last?.content ?? "").lowercased().contains("pair"),
            "the CTA must tell the parent to pair a child first"
        )
        // Hard guarantee: no user bubble leaked into history.
        XCTAssertFalse(
            vm.messages.contains { $0.role == .parent && $0.content == "lock instagram for 30 minutes" },
            "unpaired send must NOT append a parent bubble (it would imply a sent message)"
        )
    }
}
