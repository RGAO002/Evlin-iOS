# Unblock Card Child Avatar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display the current child's real profile photo in the `Blocked apps` picker, with backend-photo and initial fallbacks.

**Architecture:** `ChatView` projects `FamilyStore.childProfiles` into a child-ID-to-avatar-string map and passes it into `AppControlCard`. A pure model helper validates and orders distinct web URLs; a small SwiftUI avatar view attempts those URLs sequentially before rendering the existing colored initial.

**Tech Stack:** Swift 5, SwiftUI, Observation `FamilyStore`, XCTest

## Global Constraints

- Match avatars only by backend child profile ID.
- Never match by device ID or child name.
- URL priority is FamilyStore photo, then backend card photo, then colored initial.
- A failed image download must advance to the next candidate URL.
- Do not add API calls or change backend/profile storage.
- Limit behavior changes to `AppControlCardKind.restrictionUnlockPicker`.

---

### Task 1: Pure Restriction Avatar URL Resolution

**Files:**
- Modify: `Evlin iOS/Models/AppControlCardModel.swift`
- Test: `Evlin iOSTests/LockSelectedAppsCardModelTests.swift`

**Interfaces:**
- Consumes: restriction group `id` as the backend child profile ID, `[String: String]` FamilyStore avatar map, and `RestrictionUnlockGroup.avatarURL`.
- Produces: `AppControlCardModel.restrictionAvatarCandidateURLs(childID:familyAvatarURLsByChildID:payloadURL:) -> [URL]`.

- [ ] **Step 1: Write failing URL-priority and child-ID tests**

Add tests that call the pure helper directly:

```swift
func testRestrictionAvatarCandidatesPreferFamilyStoreAndDeduplicate() {
    let backend = URL(string: "https://cdn.example/backend.jpg")!
    let result = AppControlCardModel.restrictionAvatarCandidateURLs(
        childID: "child-1",
        familyAvatarURLsByChildID: [
            "child-1": "https://cdn.example/current.jpg",
            "device-1": "https://cdn.example/wrong-device.jpg",
        ],
        payloadURL: backend
    )

    XCTAssertEqual(result.map(\.absoluteString), [
        "https://cdn.example/current.jpg",
        "https://cdn.example/backend.jpg",
    ])
}

func testRestrictionAvatarCandidatesFallBackWhenChildMissing() {
    let backend = URL(string: "https://cdn.example/backend.jpg")!
    let result = AppControlCardModel.restrictionAvatarCandidateURLs(
        childID: "child-1",
        familyAvatarURLsByChildID: [
            "child-2": "https://cdn.example/other.jpg",
        ],
        payloadURL: backend
    )

    XCTAssertEqual(result, [backend])
}

func testRestrictionAvatarCandidatesRejectInvalidFamilyURL() {
    let backend = URL(string: "https://cdn.example/backend.jpg")!
    let result = AppControlCardModel.restrictionAvatarCandidateURLs(
        childID: "child-1",
        familyAvatarURLsByChildID: ["child-1": "not a remote URL"],
        payloadURL: backend
    )

    XCTAssertEqual(result, [backend])
}

func testRestrictionAvatarCandidatesReturnEmptyWithoutUsableURL() {
    let result = AppControlCardModel.restrictionAvatarCandidateURLs(
        childID: "child-1",
        familyAvatarURLsByChildID: [:],
        payloadURL: nil
    )

    XCTAssertTrue(result.isEmpty)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test \
  -project "Evlin iOS.xcodeproj" \
  -scheme "Evlin iOS" \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1" \
  -only-testing:"Evlin iOSTests/LockSelectedAppsCardModelTests" \
  CODE_SIGNING_ALLOWED=NO
```

Expected: build fails because `restrictionAvatarCandidateURLs` does not exist.

- [ ] **Step 3: Implement strict ordered URL resolution**

Add this helper to the existing `AppControlCardModel` extension:

```swift
static func restrictionAvatarCandidateURLs(
    childID: String,
    familyAvatarURLsByChildID: [String: String],
    payloadURL: URL?
) -> [URL] {
    var result: [URL] = []
    var seen: Set<String> = []

    func appendIfUsable(_ url: URL?) {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil,
              seen.insert(url.absoluteString).inserted else {
            return
        }
        result.append(url)
    }

    let familyURL = familyAvatarURLsByChildID[childID]
        .flatMap(URL.init(string:))
    appendIfUsable(familyURL)
    appendIfUsable(payloadURL)
    return result
}
```

This accepts only absolute HTTP(S) URLs, preserves source order, and removes duplicates.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the command from Step 2.

Expected: all `LockSelectedAppsCardModelTests` pass.

- [ ] **Step 5: Commit the pure resolver**

```bash
git add \
  "Evlin iOS/Models/AppControlCardModel.swift" \
  "Evlin iOSTests/LockSelectedAppsCardModelTests.swift"
git commit -m "feat(chat): resolve child avatar fallback URLs"
```

---

### Task 2: FamilyStore Wiring and Sequential Image Fallback

**Files:**
- Modify: `Evlin iOS/Views/Chat/ChatView.swift`
- Modify: `Evlin iOS/Components/ConfirmationCards/AppControlCard.swift`
- Test: `Evlin iOSTests/LockSelectedAppsCardModelTests.swift`

**Interfaces:**
- Consumes: Task 1's `restrictionAvatarCandidateURLs(...)`.
- Produces: `RestrictionAvatarCursor`, `AppControlCard.familyAvatarURLsByChildID: [String: String]`, and a private `RestrictionGroupAvatar` view that advances through candidate URLs on `AsyncImagePhase.failure`.

- [ ] **Step 1: Add failing cursor and parsed-group contract tests**

Add a cursor test that proves failed image loads advance one source at a time:

```swift
func testRestrictionAvatarCursorAdvancesThroughFailures() {
    let current = URL(string: "https://cdn.example/current.jpg")!
    let backend = URL(string: "https://cdn.example/backend.jpg")!
    var cursor = RestrictionAvatarCursor(candidateURLs: [current, backend])

    XCTAssertEqual(cursor.currentURL, current)
    cursor.advanceAfterFailure(for: current)
    XCTAssertEqual(cursor.currentURL, backend)
    cursor.advanceAfterFailure(for: backend)
    XCTAssertNil(cursor.currentURL)
}

func testRestrictionAvatarCursorIgnoresStaleFailure() {
    let current = URL(string: "https://cdn.example/current.jpg")!
    let backend = URL(string: "https://cdn.example/backend.jpg")!
    var cursor = RestrictionAvatarCursor(candidateURLs: [current, backend])

    cursor.advanceAfterFailure(for: backend)
    XCTAssertEqual(cursor.currentURL, current)
}
```

Also extend `testParseRestrictionUnlockPicker` with:

```swift
let group = try XCTUnwrap(model?.restrictionGroups.first)
let urls = AppControlCardModel.restrictionAvatarCandidateURLs(
    childID: group.id,
    familyAvatarURLsByChildID: [
        "child-1": "https://example.test/avatars/current-ryan.jpg",
    ],
    payloadURL: group.avatarURL
)
XCTAssertEqual(urls.map(\.absoluteString), [
    "https://example.test/avatars/current-ryan.jpg",
    "https://example.test/avatars/ryan.jpg",
])
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run the Task 1 test command.

Expected: build fails because `RestrictionAvatarCursor` does not exist.

- [ ] **Step 3: Implement the sequential cursor**

Add this internal value type beside `RestrictionUnlockGroup`:

```swift
struct RestrictionAvatarCursor: Equatable {
    let candidateURLs: [URL]
    private(set) var index = 0

    var currentURL: URL? {
        candidateURLs.indices.contains(index) ? candidateURLs[index] : nil
    }

    mutating func advanceAfterFailure(for failedURL: URL) {
        guard currentURL == failedURL else { return }
        index += 1
    }
}
```

Run the Task 1 test command.

Expected: the cursor tests and parsed-group contract pass.

- [ ] **Step 4: Pass current FamilyStore avatars from ChatView**

Add a private projection in `ChatView`:

```swift
private var childAvatarURLsByID: [String: String] {
    Dictionary(
        familyStore.childProfiles.compactMap { child -> (String, String)? in
            guard let avatarURL = child.avatarURL, !avatarURL.isEmpty else {
                return nil
            }
            return (child.id, avatarURL)
        },
        uniquingKeysWith: { first, _ in first }
    )
}
```

Pass it to the existing card call:

```swift
AppControlCard(
    model: appControlCard,
    familyAvatarURLsByChildID: childAvatarURLsByID,
    onOption: { option in viewModel.handleAppControlOption(option) },
    onCandidate: { candidate in viewModel.handleAppControlCandidate(candidate) },
    onCancel: { viewModel.dismissAppControlCard() }
)
```

- [ ] **Step 5: Implement sequential image attempts**

Add `familyAvatarURLsByChildID: [String: String]` to `AppControlCard`. Replace the existing one-shot `restrictionGroupAvatar` rendering with:

```swift
RestrictionGroupAvatar(
    group: group,
    fallbackColor: color(from: group.avatarColorHex) ?? Color.evPrimary,
    candidateURLs: AppControlCardModel.restrictionAvatarCandidateURLs(
        childID: group.id,
        familyAvatarURLsByChildID: familyAvatarURLsByChildID,
        payloadURL: group.avatarURL
    )
)
```

Add a private view in `AppControlCard.swift`:

```swift
private struct RestrictionGroupAvatar: View {
    let group: RestrictionUnlockGroup
    let fallbackColor: Color
    let candidateURLs: [URL]
    @State private var cursor: RestrictionAvatarCursor

    init(
        group: RestrictionUnlockGroup,
        fallbackColor: Color,
        candidateURLs: [URL]
    ) {
        self.group = group
        self.fallbackColor = fallbackColor
        self.candidateURLs = candidateURLs
        _cursor = State(
            initialValue: RestrictionAvatarCursor(candidateURLs: candidateURLs)
        )
    }

    var body: some View {
        Group {
            if let currentURL = cursor.currentURL {
                AsyncImage(url: currentURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        fallback
                            .task(id: currentURL) {
                                cursor.advanceAfterFailure(for: currentURL)
                            }
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(Circle())
        .onChange(of: candidateURLs) {
            cursor = RestrictionAvatarCursor(candidateURLs: candidateURLs)
        }
    }

    private var fallback: some View {
        let raw = group.avatarValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = raw.isEmpty ? String(group.childName.prefix(1)).uppercased() : raw
        return ZStack {
            Circle().fill(fallbackColor.opacity(0.16))
            Text(text)
                .font(.custom("Manrope", size: 15).weight(.heavy))
                .foregroundStyle(fallbackColor)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
    }
}
```

Keep the existing `AppControlCard.color(from:)` helper and pass its result into
the child view as shown. Keep cursor mutation in `.task`, never directly inside
the `AsyncImage` view-builder evaluation.

- [ ] **Step 6: Compile and run the focused card tests**

Run:

```bash
xcodebuild test \
  -project "Evlin iOS.xcodeproj" \
  -scheme "Evlin iOS" \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1" \
  -only-testing:"Evlin iOSTests/LockSelectedAppsCardModelTests" \
  CODE_SIGNING_ALLOWED=NO
```

Expected: all focused tests pass and `AppControlCard.swift` plus `ChatView.swift` compile.

- [ ] **Step 7: Verify formatting and scoped diff**

Run:

```bash
git diff --check -- \
  "Evlin iOS/Views/Chat/ChatView.swift" \
  "Evlin iOS/Components/ConfirmationCards/AppControlCard.swift" \
  "Evlin iOS/Models/AppControlCardModel.swift" \
  "Evlin iOSTests/LockSelectedAppsCardModelTests.swift"
```

Expected: no output.

- [ ] **Step 8: Commit UI wiring**

```bash
git add \
  "Evlin iOS/Views/Chat/ChatView.swift" \
  "Evlin iOS/Components/ConfirmationCards/AppControlCard.swift" \
  "Evlin iOSTests/LockSelectedAppsCardModelTests.swift"
git commit -m "feat(chat): show real child avatar in unblock card"
```
