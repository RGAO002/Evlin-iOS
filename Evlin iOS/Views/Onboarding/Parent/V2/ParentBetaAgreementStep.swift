//
//  ParentBetaAgreementStep.swift
//  Evlin iOS
//
//  Beta Participation Agreement — scroll-to-bottom read gate.
//
//  Sits between ParentProfileStep and ParentNewOrJoinStep so every parent
//  (new-family owner AND joining co-parent) reads it after their account
//  exists but before any family/child enrollment. Continue stays disabled
//  until the reader has scrolled the full text into view.
//
//  IMPORTANT — legal posture:
//  - The embedded text is Draft v2.0 (July 2026) and is NOT yet cleared by
//    counsel for execution. Ship-blocking: swap in the counsel-approved text
//    (and bump `version`) before this step reaches real users.
//  - Reaching the bottom + Continue is an ACKNOWLEDGMENT OF READING, not
//    execution. VPC / COPPA consent is a separate flow by design (§4.1 —
//    consent must not be bundled into general terms).
//

import SwiftUI

/// Same per-file convention as the other V2 parent step files.
private let parentTotal = 12

struct ParentBetaAgreementStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    /// Flips when the end-of-document sentinel scrolls into view; never unflips.
    @State private var readToBottom = false

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Accounts",
            stepIndex: 4,
            stepTotal: parentTotal,
            title: "Beta agreement",
            subtitle: "Please read to the end — the button unlocks at the bottom.",
            dotsCount: parentTotal,
            dotsCurrent: 3,
            content: {
                BetaAgreementReaderCard(readToBottom: $readToBottom)
            },
            footer: {
                if readToBottom {
                    Text("✓ Read to the end")
                        .onboardingV2BodyXS()
                        .foregroundStyle(OnboardingV2Theme.Palette.secondary)
                } else {
                    ScrollNudgeHint()
                }
                OnboardingV2PrimaryButton("I've read the agreement — continue",
                                          role: .parent,
                                          action: onContinue)
                    .disabled(!readToBottom)
                    .opacity(readToBottom ? 1 : 0.5)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - Shared reader card (onboarding step + launch gate)

/// The scrollable agreement card with the end-of-document sentinel and the
/// bottom fade. Flips `readToBottom` (never unflips) when the reader reaches
/// the end. Shared by the onboarding step and `BetaAgreementGateView`.
struct BetaAgreementReaderCard: View {
    @Binding var readToBottom: Bool

    var body: some View {
        OnboardingV2Card {
            ScrollView {
                // LazyVStack so the sentinel's onAppear fires only when
                // actually scrolled into view (a plain VStack builds
                // everything up front and would unlock immediately).
                LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                    Text(BetaAgreementContent.header)
                        .onboardingV2BodyStrong()
                    Text(BetaAgreementContent.version)
                        .onboardingV2BodyXS()
                        .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)

                    ForEach(BetaAgreementContent.sections, id: \.heading) { section in
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text(section.heading)
                                .onboardingV2BodyStrong()
                            Text(section.body)
                                .onboardingV2BodyXS()
                                .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                        }
                    }

                    // End-of-document sentinel: unlocks Continue.
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            withAnimation(.easeOut(duration: 0.25)) {
                                readToBottom = true
                            }
                        }
                }
                .padding(.vertical, Spacing.xs)
            }
            .frame(maxHeight: .infinity)
            // Bottom fade — signals there's more to read; lifts on unlock.
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [OnboardingV2Theme.Palette.surfaceLowest.opacity(0),
                             OnboardingV2Theme.Palette.surfaceLowest],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 44)
                .allowsHitTesting(false)
                .opacity(readToBottom ? 0 : 1)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Launch gate (existing accounts)

/// Full-screen re-read gate shown from the parent root when the account's
/// acked agreement version differs from `BetaAgreementContent.wireVersion`
/// (parents who onboarded before the agreement step existed, or after a
/// version bump). Same reader card and unlock rules as the onboarding step.
struct BetaAgreementGateView: View {
    /// Called once on confirm; the presenter records the ack and dismisses.
    let onConfirm: () -> Void

    @State private var readToBottom = false
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Beta agreement")
                    .onboardingV2TitleL()
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                Text("One quick thing before you continue — please read to the end. The button unlocks at the bottom.")
                    .onboardingV2Body()
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
            }

            BetaAgreementReaderCard(readToBottom: $readToBottom)

            VStack(spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                if readToBottom {
                    Text("✓ Read to the end")
                        .onboardingV2BodyXS()
                        .foregroundStyle(OnboardingV2Theme.Palette.secondary)
                } else {
                    ScrollNudgeHint()
                }
                OnboardingV2PrimaryButton("I've read the agreement — continue",
                                          role: .parent) {
                    guard !confirmed else { return }
                    confirmed = true
                    onConfirm()
                }
                .disabled(!readToBottom || confirmed)
                .opacity(readToBottom ? 1 : 0.5)
            }
        }
        .padding(.horizontal, OnboardingV2Theme.Metrics.screenBodyPaddingHorizontal)
        .padding(.top, Spacing.xl)
        .padding(.bottom, OnboardingV2Theme.Metrics.screenBodyPaddingBottom)
        .background(OnboardingV2Theme.Palette.surface.ignoresSafeArea())
        .interactiveDismissDisabled()
    }
}

/// "Scroll to the end to continue ↓" with a gentle repeating nudge on the
/// chevron (stilled under Reduce Motion).
struct ScrollNudgeHint: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nudged = false

    var body: some View {
        HStack(spacing: 4) {
            Text("Scroll to the end to continue")
                .onboardingV2BodyXS()
            Text("↓")
                .onboardingV2BodyXS()
                .offset(y: nudged ? 3 : 0)
                .animation(reduceMotion ? nil
                           : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                           value: nudged)
        }
        .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
        .onAppear { if !reduceMotion { nudged = true } }
    }
}

// MARK: - Agreement text (extracted from Evlin_Beta_Participation_Agreement_v2.0)
//
// Verbatim sections 1–11 + preamble. Deliberately excluded: internal
// ATTORNEY REVIEW annotations, the signature block, and Exhibit A (the
// enrollment form belongs to the execution flow, not the read gate).

enum BetaAgreementContent {

    static let header = "EVLIN INC. — BETA PARTICIPATION AGREEMENT"
    static let version = "v2.0 · July 2026"

    /// Version string recorded via POST /me/agreement/ack and compared by the
    /// parent-root launch gate. BUMP THIS whenever the agreement text changes
    /// materially (e.g. the counsel-approved final) — every account, including
    /// ones that acked an older version, is then re-gated on next launch.
    static let wireVersion = "2.0-draft"

    struct Section {
        let heading: String
        let body: String
    }

    static let sections: [Section] = [
        Section(
            heading: "Introduction",
            body: """
            This Beta Participation Agreement (this "Agreement") is entered into between Evlin Inc., a Delaware corporation ("Evlin," "we," "us"), and the individual identified in the signature block and Exhibit A ("Participant," "you"). It is effective on the date of the last signature below (the "Effective Date").
            """
        ),
        Section(
            heading: "1. Definitions",
            body: """
            1.1 "Beta Program" means Evlin's pre-release testing program for the Services, conducted in two phases: "Phase 0," in which adults operate both the parent and child surfaces of the Services and no Child uses the Services; and "Phase 1," in which a Child Profile is activated and the Child uses the Services, subject to Section 4.

            1.2 "Services" means Evlin's pre-release parental control and screen-time management applications for parents and children ages 3–11, including the parent app, the child app, device enforcement features, the task and consequence system, reflections and quizzes, chore photo verification, comic content, and the Evlin AI companion, together with the evlin.io website.

            1.3 "Child" means a child under 13 years of age for whom Participant is the parent or legal guardian and who is enrolled in the Beta Program under Exhibit A.

            1.4 "Child Data" means personal information collected from or about a Child through the Services, as described in the Kids' Data Notice.

            1.5 "Kids' Data Notice" means Evlin's children's privacy notice published at evlin.io, as updated from time to time in accordance with Section 5.6.

            1.6 "Verifiable Parental Consent" or "VPC" means the consent to collection and use of Child Data obtained from Participant in accordance with the Children's Online Privacy Protection Act and its implementing Rule ("COPPA"), recorded in Evlin's consent records.
            """
        ),
        Section(
            heading: "2. Nature of the Beta Program",
            body: """
            2.1 Pre-release software. The Services are pre-release, under active development, and provided for testing and evaluation. Features may be incomplete, may change or be removed without notice, and may contain defects. Evlin makes no commitment that the Services, or any feature of them, will be commercially released.

            2.2 No fee; no compensation. Participation is free of charge. Participant is not an employee, contractor, or agent of Evlin, and is not entitled to compensation for participation or feedback.

            2.3 Enforcement limitations — read carefully. Device locking, screen-time enforcement, and content controls depend on operating-system frameworks outside Evlin's control (including Apple's Screen Time frameworks and Android device administration). Locks and limits may apply late, apply incorrectly, or fail entirely, particularly on iOS where enforcement events are subject to operating-system timing constraints, and following operating-system updates. Participant acknowledges that the Services are a convenience tool, not a safety device, and are not a substitute for adult supervision of a child's device use, online activity, or wellbeing.

            2.4 Not an emergency, medical, or safety service. The Services, including the AI companion, do not provide medical, psychological, safety, or emergency services and must not be relied on for any such purpose.
            """
        ),
        Section(
            heading: "3. Eligibility and Participant Responsibilities",
            body: """
            3.1 Eligibility. Participant represents and warrants that Participant: (a) is at least 18 years old; (b) is the parent or legal guardian of each Child enrolled under Exhibit A, with legal authority to consent to the collection of that Child's personal information; (c) owns, or has the authority of the owner of, each device enrolled in the Services; and (d) resides in the State of California.

            3.2 Accurate information. Participant will provide accurate account, family, and enrollment information and keep it current, including notifying Evlin if Participant ceases to be the Child's parent or legal guardian.

            3.3 Account security. Participant will keep account credentials confidential, will not share the parent account with the Child, and will notify Evlin promptly of any suspected unauthorized access.

            3.4 Acceptable use. Participant will use the Services only for their intended household purpose; will not use them to monitor any child for whom Participant lacks legal authority or any adult without that adult's consent; will not attempt to reverse engineer, probe, or circumvent security or enforcement mechanisms except in the ordinary course of good-faith bug reporting; and will not upload unlawful content.

            3.5 Phase 0 conduct. During Phase 0, Participant will not permit any child to use the Services and will not enter any real child's personal information into the Services. Test profiles in Phase 0 must use fictitious data.
            """
        ),
        Section(
            heading: "4. Children's Privacy and Consent — Order of Operations",
            body: """
            4.1 This Agreement is not consent. Execution of this Agreement does not constitute Verifiable Parental Consent, and Evlin will not treat it as such. VPC to the collection and use of Child Data, and any separate consent to third-party disclosure that applicable law requires, are obtained through a distinct consent flow, after Participant has received Evlin's direct notice, and are recorded separately. This separation is deliberate and required: COPPA prohibits bundling consent into general terms.

            4.2 Phase 1 gate. No Child Profile will be activated and no Child Data will be collected unless and until, in order: (a) Participant has received the direct notice; (b) VPC is recorded; (c) any required separate third-party disclosure consent is recorded; and (d) this Agreement is executed. The Services are built to make activation technically impossible without a recorded consent.

            4.3 Withdrawal. Participant may withdraw VPC at any time under Section 5.4. Withdrawal is effective immediately upon Evlin's receipt and does not require terminating this Agreement, though Phase 1 participation ends upon withdrawal.
            """
        ),
        Section(
            heading: "5. Child Data: Collection, Use, Limits, and Parental Rights",
            body: """
            5.1 What is collected. Child Data collected through the Services is limited to the categories described in the Kids' Data Notice, and in summary comprises: a nickname and birth year for the Child; identifiers for enrolled devices; screen time and app usage on enrolled devices; tasks assigned and completed and consequence history; the Child's reflections and quiz responses; chore verification photos; and text the Child types to the Evlin companion. The Services do not collect the Child's precise geolocation and do not capture the Child's voice.

            5.2 How it is used. Child Data is used solely to operate the Services for Participant's family: to enforce the rules Participant sets, to generate habit insights and reports for Participant, and to enable the companion to respond to the Child. Chore photos are processed by an automated moderation service solely to verify task completion and are deleted within seven days of the verification decision.

            5.3 Absolute limits. Evlin will not: (a) serve advertising of any kind to the Child; (b) sell or share Child Data; (c) permit Child Data to be used to train artificial-intelligence models, whether Evlin's or a third party's; or (d) disclose Child Data to third parties except to service providers bound by written contracts limiting use to providing the Services, or as required by law.

            5.4 Parental rights. At any time, by writing to privacy@evlin.io, Participant may: (a) review the Child Data Evlin holds, delivered as a readable export within ten business days; (b) direct deletion of Child Data, completed within thirty days across production systems, backup cycles, and service providers, with written confirmation; and (c) withdraw consent, upon which collection stops immediately and the Child's devices are released from enforcement within twenty-four hours.

            5.5 Retention. Child Data is retained only per the written retention schedule published in the Kids' Data Notice. Account closure triggers permanent deletion of Child Data within thirty days. "Deletion" means permanent removal, not archival flagging.

            5.6 Notice changes. Evlin will notify Participant of material changes to the Kids' Data Notice before they take effect. Any new category of Child Data collection or new third-party disclosure requires new consent; continued use is not consent to materially expanded collection.
            """
        ),
        Section(
            heading: "6. Feedback; No Confidentiality Obligation",
            body: """
            6.1 Feedback. Participant may provide suggestions, bug reports, and other feedback. Participant assigns to Evlin all right, title, and interest in feedback, and Evlin may use it without restriction or attribution. Feedback must not include any other person's personal information.

            6.2 No NDA. Participant has no confidentiality obligation regarding Participant's own experience with the Services and is free to discuss, review, and recommend (or criticize) the Services publicly. The only exception: Participant will not publicly disclose another beta family's identity or a Child's personal information other than Participant's own.

            6.3 Screenshots of children. If Participant shares screenshots or recordings publicly, Participant is responsible for what they reveal about Participant's own family.
            """
        ),
        Section(
            heading: "7. Intellectual Property; License",
            body: """
            7.1 License to Participant. Evlin grants Participant a personal, non-exclusive, non-transferable, revocable license to use the Services during the Beta Program for household purposes.

            7.2 Reservation. Evlin and its licensors retain all rights in the Services, including the Evlin name and characters. No rights are granted except as stated in Section 7.1.
            """
        ),
        Section(
            heading: "8. Term, Termination, and Offboarding",
            body: """
            8.1 Term. This Agreement runs from the Effective Date until the earlier of: the end of the Beta Program as announced by Evlin; termination by either party on notice, which either party may give at any time for any reason; or termination for breach.

            8.2 Offboarding. On termination or consent withdrawal, Evlin will release the Child's devices from enforcement gracefully within twenty-four hours and delete Child Data per Section 5.5, unless Participant elects in writing to retain the parent account only.

            8.3 Survival. Sections 5.4–5.5 (until deletion completes), 6, 7.2, 9, 10, and 11 survive termination.
            """
        ),
        Section(
            heading: "9. Disclaimers",
            body: """
            THE SERVICES ARE PROVIDED "AS IS" AND "AS AVAILABLE," WITH ALL FAULTS. TO THE MAXIMUM EXTENT PERMITTED BY LAW, EVLIN DISCLAIMS ALL WARRANTIES, EXPRESS OR IMPLIED, INCLUDING MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, AND NON-INFRINGEMENT, AND ANY WARRANTY THAT ENFORCEMENT FEATURES WILL OPERATE TIMELY, ACCURATELY, OR AT ALL. NOTHING IN THIS SECTION LIMITS EVLIN'S OBLIGATIONS UNDER SECTION 5 OR ANY OBLIGATION THAT CANNOT BE DISCLAIMED UNDER APPLICABLE LAW.
            """
        ),
        Section(
            heading: "10. Limitation of Liability",
            body: """
            TO THE MAXIMUM EXTENT PERMITTED BY LAW: (A) NEITHER PARTY IS LIABLE FOR INDIRECT, INCIDENTAL, CONSEQUENTIAL, SPECIAL, OR PUNITIVE DAMAGES; AND (B) EVLIN'S AGGREGATE LIABILITY UNDER THIS AGREEMENT IS CAPPED AT ONE HUNDRED U.S. DOLLARS ($100). THE CAP DOES NOT APPLY TO EVLIN'S BREACH OF SECTION 5.3, TO LIABILITY THAT CANNOT BE LIMITED UNDER APPLICABLE LAW, OR TO EITHER PARTY'S WILLFUL MISCONDUCT.
            """
        ),
        Section(
            heading: "11. General",
            body: """
            11.1 Governing law. This Agreement is governed by the laws of the State of California, without regard to conflicts rules.

            11.2 Disputes. [Dispute mechanism to be finalized before execution.]

            11.3 Entire agreement; order of precedence. This Agreement, the Kids' Data Notice, Evlin's privacy notice, and Evlin's terms of service are the entire agreement for the Beta Program. If they conflict with respect to Child Data, the more protective provision governs.

            11.4 Assignment. Participant may not assign this Agreement. Evlin may assign it in connection with a merger, acquisition, or sale of assets, provided the assignee assumes the Section 5 obligations in full.

            11.5 Notices. Evlin will send notices to Participant's account email. Participant sends notices to privacy@evlin.io (data matters) or support@evlin.io (all other matters).

            11.6 Electronic execution. This Agreement may be executed electronically, including via DocuSign, and electronic signatures are effective as originals.

            11.7 Severability; waiver. If a provision is unenforceable, the remainder stands. A failure to enforce is not a waiver.
            """
        ),
    ]
}
