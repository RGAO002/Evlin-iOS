import XCTest
@testable import Evlin_iOS

/// The chat fast path's disambiguation rewrite.
///
/// When a parent says "lock sayunara" and Evlin cannot resolve it, the app shows
/// an App Store picker; whatever the parent picks is spliced into the original
/// sentence and the sentence is re-sent. Every existing test covers a case where
/// the splice succeeds. These cover the cases where it does not — which is where
/// the reported symptoms live: an endless "which app is sayunara?" loop, and
/// "it asked about one app and locked a different one".
final class AppControlFastPathRewriteTests: XCTestCase {

    private func rewrite(
        _ original: String,
        _ target: String,
        _ candidate: String
    ) -> String {
        AppControlRouter.rewriteOriginalCommand(
            original,
            replacing: target,
            with: candidate
        )
    }

    // MARK: - The loop

    /// Reported: pick "not in the list" → choose an app → asked about the ORIGINAL
    /// made-up name again, forever.
    ///
    /// When the target is not found in the sentence the rewrite returns the
    /// sentence untouched, and the caller re-sends it. Re-sending the exact text
    /// that produced the picker reproduces the picker: a closed loop with no exit
    /// and no diagnostic. The same function already has a fallback for an empty
    /// target — it returns the candidate — so the not-found case returning the
    /// original is the outlier, not the design.
    func test_targetMissingFromSentenceMustNotResendTheSentenceUnchanged() {
        let original = "lock sayunara"
        let rewritten = rewrite(original, "Sayunara Corp Ltd", "懂球帝")
        XCTAssertNotEqual(
            rewritten,
            original,
            "re-sending the sentence that produced the picker reproduces the "
                + "picker; the parent has no way out"
        )
        XCTAssertTrue(
            rewritten.contains("懂球帝"),
            "the parent's choice must reach the command somehow, even if the "
                + "original wording cannot be patched. Got: \(rewritten)"
        )
    }

    /// A stale `lastUserMessageForCard` — or any parent bubble sent after the card
    /// appeared — produces the same shape: the target is simply not in the text
    /// the rewrite is handed.
    func test_unrelatedSentenceStillCarriesTheChoice() {
        let rewritten = rewrite("what did she do today?", "sayunara", "懂球帝")
        XCTAssertTrue(
            rewritten.contains("懂球帝"),
            "Got: \(rewritten)"
        )
    }

    // MARK: - Locking the wrong app

    /// Reported: "asks me to lock this and then locks another one".
    ///
    /// The splice is a plain substring replace. A short target is a substring of
    /// longer words, so the candidate lands inside a word that was never the
    /// target and the re-sent command names an app the parent never chose.
    func test_shortTargetMustNotSpliceInsideALongerWord() {
        let rewritten = rewrite("lock fbi for 10 min", "fb", "Facebook")
        XCTAssertFalse(
            rewritten.contains("Facebooki"),
            "the candidate was spliced into the middle of another word — the "
                + "re-sent command now names an app nobody chose. Got: \(rewritten)"
        )
    }

    /// The same hazard with the verb: a target that happens to appear inside the
    /// command word rewrites the instruction itself.
    func test_targetMatchingTheVerbMustNotRewriteTheVerb() {
        // "block" literally contains "loc".
        let rewritten = rewrite("block Instagram", "loc", "Facebook")
        XCTAssertTrue(
            rewritten.lowercased().hasPrefix("block "),
            "the verb must survive the splice — block and lock are different "
                + "actions (block hides the app, lock shields it), so mangling "
                + "the verb changes what the command DOES. Got: \(rewritten)"
        )
    }

    /// The not-found fallback rebuilds the command rather than sending a bare
    /// display name. A name with no verb cannot execute even in principle, so
    /// dropping the verb would trade the loop for a different dead end.
    func test_fallbackKeepsTheVerbTheParentUsed() {
        XCTAssertEqual(
            rewrite("block sayunara", "Sayunara Corp Ltd", "懂球帝"),
            "block 懂球帝",
            "a block must not come back as a lock, or as a bare app name"
        )
    }

    /// "unlock" contains "lock". Matching the shorter verb first would invert
    /// the command — the parent asks to release an app and it gets locked.
    func test_unlockIsNotReadAsLock() {
        XCTAssertEqual(
            rewrite("unlock fb for 30 min", "fb", "Facebook"),
            "unlock Facebook for 30 min"
        )
    }

    // MARK: - Cases that already work, pinned so a fix cannot regress them

    func test_storeSuffixIsTrimmedToACommandableName() {
        XCTAssertEqual(
            rewrite("lock ttok", "ttok", "TikTok - Videos, Shop & LIVE"),
            "lock TikTok"
        )
    }

    func test_durationAndCasingSurviveTheSplice() {
        XCTAssertEqual(
            rewrite("Lock cat quest for 15 mins", "Cat Quest", "Cat Quest III"),
            "Lock Cat Quest III for 15 mins"
        )
    }

    func test_emptyOriginalFallsBackToTheCandidateAlone() {
        XCTAssertEqual(rewrite("", "sayunara", "懂球帝"), "懂球帝")
    }

    /// Re-confirming the same card must not compound: the sentence already names
    /// the candidate, so a second pass has to leave it alone rather than nest it.
    func test_rewritingTwiceIsIdempotent() {
        let once = rewrite("lock sayunara", "sayunara", "懂球帝")
        let twice = rewrite(once, "sayunara", "懂球帝")
        XCTAssertEqual(twice, once, "Got: \(twice)")
    }
}
