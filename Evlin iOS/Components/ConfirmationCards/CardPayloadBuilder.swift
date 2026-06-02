import Foundation

/// Centralizes all card copy so localization + A/B testing are possible later.
enum CardPayloadBuilder {
    static func build(cardID: CardID, context: CardContext, handlers: CardHandlers) -> CardPayload {
        switch cardID {
        case .A1: return a1(context, handlers)
        case .A3: return a3(context, handlers)
        case .B1: return b1(context, handlers)
        case .B2: return b2(context, handlers)
        case .C1: return c1(context, handlers)
        case .C2: return c2(context, handlers)
        case .D1: return d1(context, handlers)
        case .D2: return d2(context, handlers)
        case .D3: return d3(context, handlers)
        case .D4: return d4(context, handlers)
        case .E1: return e1(context, handlers)
        case .E2: return e2(context, handlers)
        case .E3: return e3(context, handlers)
        case .E4: return e4(context, handlers)
        case .F1: return f1(context, handlers)
        case .G1: return g1(context, handlers)
        case .R1: return r1(context, handlers)
        case .U1:
            // U1 doesn't use CardPayload — CardDispatcher renders U1Card
            // directly from CardContext.u1Token + u1ShieldList. Return an
            // empty payload as a defensive stub so the switch is exhaustive
            // and any accidental builder call doesn't crash.
            return CardPayload(id: .U1, icon: "lock.open", title: "", body: "", buttons: [])
        case .contentGenFailed:
            return contentGenFailed(context, handlers)
        case .reflectionReview:
            // Phase 2B: adapter returns nil for confirm_approve / confirm_redo,
            // falling back to PlanArchCardView. This branch is dead until Phase 2C
            // adds ReflectionReviewCard. Use G1-style stub as defensive fallback.
            return g1(context, handlers)
        case .singleAppShieldAdvice, .shieldTokenMissing, .appStoreDisambiguation,
             .appNotFoundTerminal, .childDisambiguation, .categoryRenameRequired,
             .cannotBlockCategory, .categoryShieldOffer, .catalogAppInactive,
             .bundleIDRequired:
            // Task 11 app-control cards don't use CardPayload — they render via
            // AppControlCard from AppControlCardModel. Defensive empty stub so the
            // switch stays exhaustive; this builder is never called for them.
            return CardPayload(id: cardID, icon: "app.badge", title: "", body: "", buttons: [])
        }
    }

    // MARK: - Group R (reflection)

    private static func r1(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        // ctx.targetDisplay carries the parent's plain-English reason as
        // emitted by Gemini's `reflection_reason` field. The kid will see
        // a Gemini-rephrased "displayReason" once the trigger fires; here
        // we surface what the parent actually said so they can confirm
        // what they're sending.
        let who = ctx.childName.isEmpty ? "your kid" : ctx.childName
        return CardPayload(
            id: .R1,
            icon: "sparkles",
            title: "Send \(who) a reflection?",
            body: "I'll prepare a short video, a 5-question quiz, and a writing prompt about: “\(ctx.targetDisplay)”. Their phone stays locked until they finish all three.",
            buttons: [
                CardButton(label: "Send reflection", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Just venting — skip", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }

    // MARK: - contentGenFailed

    private static func contentGenFailed(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        // ctx.targetDisplay carries the failure_reason (or title) from the backend.
        // ReflectionContentFailedCard reads payload.title and payload.body directly.
        let title = ctx.targetDisplay.isEmpty
            ? "Couldn't prepare reflection"
            : ctx.targetDisplay
        return CardPayload(
            id: .contentGenFailed,
            icon: "exclamationmark.triangle",
            title: title,
            body: "The AI couldn't generate the reflection content. You can retry, use a simpler template, or cancel.",
            buttons: [
                CardButton(label: "Retry", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Use simpler template", style: .secondary, action: h.onSecondary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }

    // MARK: - Group A

    private static func a1(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .A1,
            icon: "nosign",
            title: "Block \(ctx.targetDisplay)?",
            body: "Blocking hides the app from \(ctx.childName)'s home screen until you unblock. It won't auto-release.",
            buttons: [
                CardButton(label: "Block \(ctx.targetDisplay)", style: .destructive, action: h.onPrimary ?? {}),
                CardButton(label: "Shield for a while instead", style: .secondary, action: h.onSecondary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }

    private static func a3(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .A3,
            icon: "exclamationmark.triangle",
            title: "Unblock ALL apps?",
            body: "All \(ctx.blockItems.count) will return to \(ctx.childName)'s home screen. Shields on other apps are not affected.",
            buttons: [
                CardButton(label: "Unblock all \(ctx.blockItems.count)", style: .destructive, action: h.onPrimary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ],
            itemList: ctx.blockItems
        )
    }

    // MARK: - Group B (downgrade)

    private static func b1(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        let durStr = ctx.durationMinutes.map { "\($0) min" } ?? "timed"
        return CardPayload(
            id: .B1,
            icon: "timer",
            title: "Change permanent lock to \(durStr)?",
            body: "\(ctx.targetDisplay) is currently shielded permanently. Changing to \(durStr) means it'll auto-unlock.",
            buttons: [
                CardButton(label: "Change to \(durStr)", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Keep permanent", style: .secondary, action: h.onCancel ?? {}),
            ]
        )
    }

    private static func b2(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        let durStr = ctx.durationMinutes.map { "\($0) min" } ?? "timed"
        return CardPayload(
            id: .B2,
            icon: "arrow.triangle.2.circlepath",
            title: "Switch from block to shield?",
            body: "\(ctx.targetDisplay) is currently blocked (hidden from home screen). Switching to a \(durStr) shield means: icon returns, app is locked but visible, auto-unlocks.",
            buttons: [
                CardButton(label: "Switch to shield", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Keep block", style: .secondary, action: h.onCancel ?? {}),
            ]
        )
    }

    // MARK: - Group C (upgrade)

    private static func c1(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .C1,
            icon: "nosign",
            title: "Replace shield with permanent block?",
            body: "\(ctx.targetDisplay) is currently shielded. Blocking removes the auto-unlock — \(ctx.childName) won't see it again until you unblock.",
            buttons: [
                CardButton(label: "Replace with block", style: .destructive, action: h.onPrimary ?? {}),
                CardButton(label: "Keep shield", style: .secondary, action: h.onCancel ?? {}),
            ]
        )
    }

    private static func c2(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .C2,
            icon: "nosign",
            title: "Block \(ctx.targetDisplay)?",
            body: "\(ctx.targetDisplay) is currently covered by a list shield. Blocking hides just this app; the list shield stays on the other apps until it expires.",
            buttons: [
                CardButton(label: "Block, keep list on others", style: .destructive, action: h.onPrimary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }

    // MARK: - Group D

    private static func d1(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .D1,
            icon: "timer",
            title: "How long should \(ctx.targetDisplay) be shielded?",
            body: "",
            buttons: [
                CardButton(label: "15 minutes", style: .secondary, action: { h.onDurationPicked?(15) }),
                CardButton(label: "30 minutes", style: .secondary, action: { h.onDurationPicked?(30) }),
                CardButton(label: "1 hour", style: .secondary, action: { h.onDurationPicked?(60) }),
                CardButton(label: "Permanently", style: .secondary, action: { h.onDurationPicked?(nil) }),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }

    private static func d2(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .D2,
            icon: "questionmark.circle",
            title: "What does \"everything\" mean?",
            body: "",
            buttons: [
                CardButton(label: "Lock ALL apps on \(ctx.childName)'s phone", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Just distracting categories", style: .secondary, action: h.onSecondary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }

    private static func d3(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        let durStr = ctx.durationMinutes.map { "\($0) min" } ?? "a long time"
        return CardPayload(
            id: .D3,
            icon: "hourglass",
            title: "Lock for \(durStr)?",
            body: "This is longer than 24 hours. Are you sure?",
            buttons: [
                CardButton(label: "Confirm \(durStr) lock", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Change duration", style: .secondary, action: h.onSecondary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }

    private static func d4(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        let items = ctx.childDevices.map {
            CardCheckboxItem(label: "\($0.label)", sublabel: nil, isSelected: false)
        }
        return CardPayload(
            id: .D4,
            icon: "person.2",
            title: "Lock \(ctx.targetDisplay) on which phone?",
            body: "",
            buttons: [
                CardButton(label: "Confirm", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ],
            checkboxes: items
        )
    }

    // MARK: - Group E

    private static func e1(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        let cat = ctx.categoryGuess?.capitalized ?? "its category"
        let isMax = ctx.mode == "max"

        let title: String
        let body: String
        var buttons: [CardButton] = []

        if isMax {
            title = "Can't shield \"\(ctx.targetDisplay)\" directly yet"
            body = "Remote single-app shield is coming soon. For now, shield the category \(ctx.targetDisplay) belongs to, or add it to a Saved List on \(ctx.childName)'s phone."
            buttons.append(CardButton(label: "Shield \(cat) category instead", style: .primary, action: h.onPrimary ?? {}))
            buttons.append(CardButton(label: "Add \(ctx.targetDisplay) to a Saved List", style: .secondary, action: h.onSecondary ?? {}))
        } else {
            title = "Standard mode can't shield \(ctx.targetDisplay) directly"
            body = "Standard mode locks by Saved List or category."
            buttons.append(CardButton(label: "Shield \(cat) category instead", style: .primary, action: h.onPrimary ?? {}))
            buttons.append(CardButton(label: "Add \(ctx.targetDisplay) to a Saved List", style: .secondary, action: h.onSecondary ?? {}))
            buttons.append(CardButton(label: "Upgrade to Max", style: .tertiary, action: h.onTertiary ?? {}))
        }
        buttons.append(CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}))

        return CardPayload(id: .E1, icon: "exclamationmark.triangle", title: title, body: body, buttons: buttons)
    }

    private static func e2(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .E2,
            icon: "lock.shield",
            title: "Block is a Max feature",
            body: "Permanent hiding from home screen requires Max. Standard mode can shield \(ctx.targetDisplay) temporarily instead.",
            buttons: [
                CardButton(label: "Upgrade to Max", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Shield \(ctx.targetDisplay) instead", style: .secondary, action: h.onSecondary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }

    private static func e3(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        var buttons: [CardButton] = []
        if let cat = ctx.categoryGuess?.capitalized {
            buttons.append(CardButton(label: "Shield \(cat) category", style: .primary, action: h.onPrimary ?? {}))
        }
        buttons.append(CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}))

        return CardPayload(
            id: .E3,
            icon: "xmark.circle.fill",
            title: "Can't hard-block \"\(ctx.targetDisplay)\"",
            body: "Block requires the app to be in Evlin's known catalog. \"\(ctx.targetDisplay)\" isn't recognized.",
            buttons: buttons,
            itemList: [
                "Shield the category it belongs to",
                "Add it manually to a Saved List (picker on \(ctx.childName)'s phone)",
            ]
        )
    }

    private static func e4(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .E4,
            icon: "xmark.circle",
            title: "No list called \"\(ctx.targetDisplay)\"",
            body: "",
            buttons: [
                CardButton(label: "Create \"\(ctx.targetDisplay)\" on \(ctx.childName)'s phone", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
            ],
            itemList: ctx.existingLists
        )
    }

    private static func f1(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        if ctx.listSuggestions.count == 1 {
            let suggestion = ctx.listSuggestions[0]
            return CardPayload(
                id: .F1,
                icon: "questionmark.circle",
                title: "Did you mean \"\(suggestion)\"?",
                body: "\"\(ctx.targetDisplay)\" doesn't exist, but \"\(suggestion)\" is close.",
                buttons: [
                    CardButton(label: "Lock \(suggestion)", style: .primary, action: { h.onListPicked?(suggestion) }),
                    CardButton(label: "Show all lists", style: .secondary, action: h.onSecondary ?? {}),
                    CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}),
                ]
            )
        }
        var buttons = ctx.listSuggestions.map { name in
            CardButton(label: "Pick \(name)", style: .secondary, action: { h.onListPicked?(name) })
        }
        buttons.append(CardButton(label: "Cancel", style: .cancel, action: h.onCancel ?? {}))
        return CardPayload(
            id: .F1,
            icon: "questionmark.circle",
            title: "Multiple lists close to \"\(ctx.targetDisplay)\":",
            body: "",
            buttons: buttons,
            itemList: ctx.listSuggestions
        )
    }

    // MARK: - Group G

    private static func g1(_ ctx: CardContext, _ h: CardHandlers) -> CardPayload {
        CardPayload(
            id: .G1,
            icon: "exclamationmark.triangle",
            title: "Can't set up Maximum on this phone",
            body: "\(ctx.childName)'s phone isn't signed in with a Child Apple ID. Maximum requires Family Sharing with a Child account.",
            buttons: [
                CardButton(label: "Set up Child Apple ID", style: .primary, action: h.onPrimary ?? {}),
                CardButton(label: "Continue with Standard", style: .secondary, action: h.onSecondary ?? {}),
                CardButton(label: "Back", style: .cancel, action: h.onCancel ?? {}),
            ]
        )
    }
}
