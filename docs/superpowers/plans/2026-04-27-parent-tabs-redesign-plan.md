# Parent-end redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring iOS Parent app to visual + interaction parity with Esen's HTML prototype, focused on the ~40% gap (Profile rebuild, TaskDetailSheet, Calendar multi-column, 6 add/edit forms).

**Architecture:** Pure SwiftUI views + sheets, all data stays mock (no backend changes). New views live under `Views/Profile/` and `Views/Calendar/`; new shared form primitives under `Components/`. Notification → Profile deep linking flows through `ContentView` route state.

**Tech Stack:** SwiftUI, iOS 17+, EvlinTokens (existing color/font system), SF Symbols (substituting Esen's Material Symbols).

**Reference:** All HTML line numbers refer to `frontend_for_app_evlin/Evlin_Parent_view/Evlin Parent Dashboard (1).html`.

**iOS test note:** Tests can't run in simulator (FamilyControls limitation). Each phase ends with `xcodebuild build` verification + a manual user-visual-check checkpoint, not XCTest assertions.

---

# Phase 1 — Models + foundation

Foundation everything else depends on. Expands TaskItem with rich data, adds bypass states, adds taskId routing fields to notifications, adds repeat to calendar events, adds bypass purple constant.

### Task 1.1: Expand TaskItem to support rich data + bypass states

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Components/TaskRow.swift:3-20` (TaskItem struct + State enum)

- [ ] **Step 1: Replace the TaskItem struct + State enum**

Replace lines 3-20 of `Components/TaskRow.swift` with:

```swift
struct TaskItem: Identifiable, Hashable {
    let id: Int
    var title: String
    var state: State
    var iconSystemName: String?

    // Rich data (Phase 1 — for TaskDetailSheet, see HTML 730-865)
    var category: String? = nil           // "Chore" | "Homework" | "Reading" | "Routine"
    var description: String? = nil        // "What to do" body
    var photos: [String] = []             // submission photo URLs
    var note: String? = nil               // child's note OR bypass reason
    var submittedAt: String? = nil        // "3:18 PM"
    var dueLabel: String? = nil           // "Today, 4:00 PM"

    enum State: String, Hashable {
        case pending, done, review, overdue, bypass, bypassed
        var label: String {
            switch self {
            case .pending:  return "Pending"
            case .done:     return "Done"
            case .review:   return "Reviewing"
            case .overdue:  return "Overdue"
            case .bypass:   return "Bypass requested"
            case .bypassed: return "Bypassed"
            }
        }
    }
}
```

- [ ] **Step 2: Verify TaskRow.swift's existing switch statements still compile**

The existing switches in TaskRow only handle 4 cases. After expanding, Swift will complain. We'll let those compile errors surface in Step 3 for Phase 3. For now, add `default:` fallbacks so the build still works:

In `Components/TaskRow.swift`, find the `cardBackground` computed property and ensure it has a default branch:

```swift
private var cardBackground: Color {
    switch task.state {
    case .review:  return Color(hex: 0xFFF9ED)
    case .overdue: return Color(hex: 0xFFF5F3)
    case .bypass:  return Color(hex: 0xF7F2FF)   // pale purple
    default:       return .evSurfaceContainerLowest
    }
}
```

Find `stateIcon` switch — add new cases at the end of the switch (matching HTML 504-522 style), inside the existing `@ViewBuilder` block, before any closing brace:

```swift
case .bypass:
    ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(hex: 0x7C3AED))    // BYPASS_PURPLE per HTML 483
        Image(systemName: "hand.raised.fill")
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(.white)
    }
    .frame(width: 36, height: 36)

case .bypassed:
    ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.evOutlineVariant, lineWidth: 2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.evSurfaceContainerLowest)
            )
        Image(systemName: "nosign")
            .font(.system(size: 14, weight: .heavy))
            .foregroundStyle(Color.evOutline)
    }
    .frame(width: 36, height: 36)
```

Find `trailingLabel` switch — add new cases:

```swift
case .bypass:
    Text("BYPASS REQUESTED")
        .font(.custom("Inter", size: 10).weight(.heavy))
        .tracking(1.4)
        .foregroundStyle(Color(hex: 0x7C3AED))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(hex: 0x7C3AED).opacity(0.12)))

case .bypassed:
    EvlinPill(text: "Bypassed", tone: .neutral, size: .xs)
```

- [ ] **Step 3: Build to verify**

Run from `/Users/fred/Desktop/Evlin/Evlin iOS`:
```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Components/TaskRow.swift"
git commit -m "feat(models): expand TaskItem with rich data + bypass states (Phase 1)"
```

---

### Task 1.2: Update ProfileMockData.tasks with rich Liam data

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Models/ProfileMockData.swift:42-49` (tasks function)

- [ ] **Step 1: Replace the tasks function**

Replace lines 42-49 of `Models/ProfileMockData.swift` with the rich mock matching HTML 874-880:

```swift
    static func tasks(for childId: String) -> [TaskItem] {
        // Mirror HTML 874-880 verbatim; non-Liam children get a subset.
        guard childId == "liam" else {
            return [
                .init(id: 1, title: "Read for 15 min", state: .done,
                      iconSystemName: "checkmark", category: "Reading",
                      description: "Read any book of your choice for 15 minutes.",
                      submittedAt: "3:00 PM", dueLabel: "Today, 4:00 PM"),
                .init(id: 2, title: "Tidy bedroom", state: .pending,
                      iconSystemName: nil, category: "Chore",
                      description: "Make the bed and put away clothes.",
                      dueLabel: "Today, 6:00 PM"),
            ]
        }
        return [
            .init(id: 1, title: "Clean Table", state: .done,
                  iconSystemName: "checkmark",
                  category: "Chore",
                  description: "Wipe down the kitchen table after lunch and put any plates in the sink.",
                  photos: ["https://images.unsplash.com/photo-1556909114-f6e7ad7d3136?w=800&q=80"],
                  note: "All done! Used the new spray.",
                  submittedAt: "12:42 PM",
                  dueLabel: "Today, 1:00 PM"),
            .init(id: 2, title: "Science Project", state: .review,
                  iconSystemName: "camera",
                  category: "Homework",
                  description: "Finish the volcano diagram on page 14 and label the layers. Take a photo of your finished page.",
                  photos: [
                    "https://images.unsplash.com/photo-1532619675605-1ede6c2ed2b0?w=800&q=80",
                    "https://images.unsplash.com/photo-1581094271901-8022df4466f9?w=800&q=80",
                    "https://images.unsplash.com/photo-1606326608606-aa0b62935f2b?w=800&q=80",
                  ],
                  note: "Took longer than I thought!",
                  submittedAt: "3:18 PM",
                  dueLabel: "Today, 4:00 PM"),
            .init(id: 3, title: "Math Practice", state: .pending,
                  iconSystemName: nil,
                  category: "Homework",
                  description: "Complete questions 1 through 8 on page 24 of your maths book. Take a photo of your finished page.",
                  dueLabel: "Today, 6:00 PM"),
            .init(id: 5, title: "Read for 20 minutes", state: .bypass,
                  iconSystemName: nil,
                  category: "Reading",
                  description: "Read any book of your choice for at least 20 minutes and tell us about it.",
                  note: "I had football practice and got home too late. Can I do double tomorrow instead?",
                  submittedAt: "7:42 PM",
                  dueLabel: "Today, 8:00 PM"),
            .init(id: 4, title: "Walk Dog", state: .overdue,
                  iconSystemName: nil,
                  category: "Chore",
                  description: "Take Buddy for his afternoon walk around the block — at least 15 minutes.",
                  dueLabel: "Yesterday, 5:00 PM"),
        ]
    }
```

- [ ] **Step 2: Build**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Models/ProfileMockData.swift"
git commit -m "feat(mock): rich Liam tasks with photos/notes/bypass per HTML 874-880 (Phase 1)"
```

---

### Task 1.3: Extend HomeNotification with kind + taskId

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Models/HomeMockData.swift:3-49` (full file)

- [ ] **Step 1: Replace the file**

```swift
import SwiftUI

struct HomeNotification: Identifiable, Hashable {
    let id: Int
    let childId: String              // "liam" / "maya" / "emma" / "family"
    let iconSystemName: String
    let title: String
    let body: String
    let time: String
    var unread: Bool

    /// "task" → tap opens ProfileView with TaskDetailSheet expanded for taskId.
    /// nil → tap only marks as read (legacy behavior).
    /// See HTML 220-228.
    var kind: String? = nil
    var taskId: Int? = nil
}

enum HomeMockData {
    /// Notifications array. Per HTML 219-228, the first 5 are 'task' kind that
    /// deep-link into ProfileView; the last 3 are informational.
    static let notifications: [HomeNotification] = [
        .init(id: 1, childId: "liam",   iconSystemName: "checkmark.circle",
              title: "Science Project — needs review",
              body: "Liam submitted his Science Project. Tap to review and approve.",
              time: "2m ago", unread: true, kind: "task", taskId: 2),
        .init(id: 2, childId: "maya",   iconSystemName: "music.note",
              title: "Piano Practice — needs review",
              body: "Maya finished her 45-min piano session and uploaded a clip.",
              time: "18m ago", unread: true, kind: "task", taskId: 2),
        .init(id: 6, childId: "liam",   iconSystemName: "exclamationmark.circle",
              title: "Walk Dog — overdue",
              body: "Liam hasn't checked off Walk Dog from yesterday.",
              time: "12h ago", unread: true, kind: "task", taskId: 4),
        .init(id: 7, childId: "liam",   iconSystemName: "clock",
              title: "Math Practice — due soon",
              body: "Math Practice is due at 6:00 PM today.",
              time: "30m ago", unread: false, kind: "task", taskId: 3),
        .init(id: 8, childId: "liam",   iconSystemName: "hand.raised",
              title: "Bypass requested — Read for 20 minutes",
              body: "\"I had football practice and got home too late. Can I do double tomorrow instead?\"",
              time: "5m ago", unread: true, kind: "task", taskId: 5),
        .init(id: 3, childId: "liam",   iconSystemName: "figure.soccer",
              title: "Soccer Practice",
              body: "Liam's session starts in 30 minutes at City Park.",
              time: "1h ago", unread: false),
        .init(id: 4, childId: "emma",   iconSystemName: "book",
              title: "Reading Goal Reached",
              body: "Emma read for 60 minutes today — new personal best!",
              time: "2h ago", unread: false),
        .init(id: 5, childId: "family", iconSystemName: "fork.knife",
              title: "Family Dinner Reminder",
              body: "Family dinner is in 1 hour. Everyone to the dining room.",
              time: "3h ago", unread: false),
    ]

    static func childColor(_ id: String) -> Color {
        switch id {
        case "liam": return .evChildLiam
        case "maya": return .evChildMaya
        case "emma": return .evChildEmma
        default:     return .evPrimary
        }
    }

    static func avatarURL(_ id: String) -> String? {
        ChildProfile.all.first(where: { $0.id == id })?.avatarURL
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Models/HomeMockData.swift"
git commit -m "feat(mock): notifications carry kind/taskId for deep-link routing (Phase 1)"
```

---

### Task 1.4: Add `repeat` to CalendarEvent + AddPalette constants

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Models/CalendarMockData.swift:10-20` (CalendarEvent struct)
- Create: `Evlin iOS/Evlin iOS/DesignSystem/EvlinAddPalette.swift`

- [ ] **Step 1: Add `repeat` field to CalendarEvent**

Replace lines 10-20 of `Models/CalendarMockData.swift`:

```swift
struct CalendarEvent: Identifiable, Hashable {
    let id = UUID()
    let col: String
    let title: String
    let emoji: String
    let start: String
    let end: String
    let category: String
    let location: String
    let note: String
    /// One of: "none" | "daily" | "weekdays" | "weekly" | "monthly". See HTML 1418.
    var recurrence: String = "none"
}
```

(Field is named `recurrence` not `repeat` because `repeat` is a Swift keyword.)

- [ ] **Step 2: Add the EvlinAddPalette file**

Create `DesignSystem/EvlinAddPalette.swift`:

```swift
import SwiftUI

/// Visual constants used by AddBottomSheet, all forms, and TaskDetailSheet.
/// Centralized to keep all phases in sync.
enum EvlinAddPalette {
    /// HTML 483: BYPASS_PURPLE = '#7C3AED'
    static let bypass = Color(hex: 0x7C3AED)
    /// HTML 484: BYPASS_BG
    static let bypassBg = Color(hex: 0x7C3AED).opacity(0.08)

    /// Status banner (TaskDetailSheet HTML 740-750)
    static let reviewTone = Color(hex: 0xB26A00)
    static let reviewBg   = Color(hex: 0xFFA726).opacity(0.12)
    static let bypassTone = bypass
    static let bypassedBg = Color.evSurfaceContainerLow
    static let bypassedTone = Color.evOnSurfaceVariant
    static let overdueTone = Color.evError
    static let overdueBg = Color(hex: 0xF44336).opacity(0.10)
    static let doneTone = Color.evSecondary
    static let doneBg = Color(hex: 0x4CAF50).opacity(0.10)

    /// Form input (HTML 1194)
    static let formInputBorder = Color.evOutlineVariant
}
```

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Models/CalendarMockData.swift" "Evlin iOS/DesignSystem/EvlinAddPalette.swift"
git commit -m "feat(models): CalendarEvent.recurrence + EvlinAddPalette constants (Phase 1)"
```

---

# Phase 2 — TaskDetailSheet (the central new view)

This is the biggest single new view in the project. Mirrors HTML 730-865 — the screen the user showed in screenshots. 5 status banners, photo gallery, bypass UI, action buttons that depend on state.

### Task 2.1: Create TaskDetailSheet skeleton + status banner

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Profile/TaskDetailSheet.swift`

- [ ] **Step 1: Create the file with the skeleton**

```swift
import SwiftUI

/// Full-screen task detail. See HTML 730-865.
/// Presented from ProfileView when a task row is tapped, or deep-linked
/// from a notification (kind="task", taskId set).
struct TaskDetailSheet: View {
    let task: TaskItem
    let child: ChildProfile
    var onClose: () -> Void = {}
    var onApprove: () -> Void = {}
    var onRedo: () -> Void = {}
    var onEdit: () -> Void = {}

    @State private var activePhotoIndex: Int = 0

    private var stateMeta: (label: String, tone: Color, bg: Color) {
        switch task.state {
        case .done:
            return ("Approved", EvlinAddPalette.doneTone, EvlinAddPalette.doneBg)
        case .bypassed:
            return ("Bypassed", EvlinAddPalette.bypassedTone, EvlinAddPalette.bypassedBg)
        case .review:
            return ("Awaiting your review", EvlinAddPalette.reviewTone, EvlinAddPalette.reviewBg)
        case .overdue:
            return ("Overdue · not submitted", EvlinAddPalette.overdueTone, EvlinAddPalette.overdueBg)
        case .bypass:
            return ("Bypass requested", EvlinAddPalette.bypassTone, EvlinAddPalette.bypass.opacity(0.10))
        case .pending:
            return ("Waiting on student", Color.evOnSurfaceVariant, Color.evSurfaceContainerLow)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    titleBlock
                    statusBanner
                    whatToDoBlock
                    if task.state != .bypass {
                        submissionBlock
                    }
                    noteBlock
                    actionButtons
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }
        }
        .background(Color.evSurface)
        .navigationBarBackButtonHidden(true)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.clear)
                    )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(child.name.uppercased())
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                Text("Task")
                    .font(.custom("Manrope", size: 19).weight(.heavy))
                    .tracking(-0.2)
                    .foregroundStyle(Color.evPrimary)
            }

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.evOnSurface)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Color.evSurface
                .overlay(
                    Rectangle()
                        .fill(Color.evOutlineVariant)
                        .frame(height: 1),
                    alignment: .bottom
                )
                .ignoresSafeArea(edges: .top)
        )
    }

    private var titleBlock: some View {
        Text(task.title)
            .font(.custom("Manrope", size: 26).weight(.heavy))
            .tracking(-0.5)
            .foregroundStyle(Color.evOnSurface)
            .lineSpacing(2)
            .padding(.top, 12)
    }

    private var statusBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(stateMeta.tone)
                .frame(width: 8, height: 8)
                .shadow(color: stateMeta.tone.opacity(0.4), radius: 4)
            Text(stateMeta.label)
                .font(.custom("Inter", size: 12).weight(.heavy))
                .foregroundStyle(stateMeta.tone)
            Spacer()
            if let due = task.dueLabel {
                Text("Due \(due)")
                    .font(.custom("Inter", size: 11))
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(stateMeta.bg)
        )
    }

    private var whatToDoBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT TO DO")
                .font(.custom("Inter", size: 11).weight(.heavy))
                .tracking(1.6)
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text(task.description ?? "")
                .font(.custom("Inter", size: 15))
                .foregroundStyle(Color.evOnSurface)
                .lineSpacing(4)
        }
    }

    @ViewBuilder
    private var submissionBlock: some View {
        EmptyView()  // Filled in Task 2.2
    }

    @ViewBuilder
    private var noteBlock: some View {
        EmptyView()  // Filled in Task 2.3
    }

    @ViewBuilder
    private var actionButtons: some View {
        EmptyView()  // Filled in Task 2.4
    }
}

#Preview("Review (with photos)") {
    TaskDetailSheet(
        task: ProfileMockData.tasks(for: "liam").first(where: { $0.state == .review })!,
        child: .liam
    )
}

#Preview("Bypass") {
    TaskDetailSheet(
        task: ProfileMockData.tasks(for: "liam").first(where: { $0.state == .bypass })!,
        child: .liam
    )
}

#Preview("Overdue") {
    TaskDetailSheet(
        task: ProfileMockData.tasks(for: "liam").first(where: { $0.state == .overdue })!,
        child: .liam
    )
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/Profile/TaskDetailSheet.swift"
git commit -m "feat(profile): TaskDetailSheet skeleton + header + status banner (Phase 2)"
```

---

### Task 2.2: Add submission block (photo gallery + empty states)

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/TaskDetailSheet.swift` (replace `submissionBlock`)

- [ ] **Step 1: Replace the `submissionBlock` ViewBuilder**

Replace the placeholder with the real implementation. Find:

```swift
    @ViewBuilder
    private var submissionBlock: some View {
        EmptyView()  // Filled in Task 2.2
    }
```

Replace with:

```swift
    @ViewBuilder
    private var submissionBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(child.name.uppercased())'S SUBMISSION")
                    .font(.custom("Inter", size: 11).weight(.heavy))
                    .tracking(1.6)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                Spacer()
                if let at = task.submittedAt {
                    Text("at \(at)")
                        .font(.custom("Inter", size: 11))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
            }

            if !task.photos.isEmpty {
                photoGallery
            } else {
                emptySubmissionPlaceholder
            }
        }
    }

    private var photoGallery: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: URL(string: task.photos[min(activePhotoIndex, task.photos.count - 1)])) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color.evSurfaceContainerLow)
                    }
                }
                .aspectRatio(4/3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.evOutlineVariant, lineWidth: 1)
                )

                if task.photos.count > 1 {
                    Text("\(activePhotoIndex + 1) / \(task.photos.count)")
                        .font(.custom("Inter", size: 11).weight(.heavy))
                        .tracking(0.4)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .padding(10)
                }
            }

            if task.photos.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(task.photos.enumerated()), id: \.offset) { idx, urlStr in
                            Button {
                                activePhotoIndex = idx
                            } label: {
                                AsyncImage(url: URL(string: urlStr)) { phase in
                                    if let img = phase.image {
                                        img.resizable().scaledToFill()
                                    } else {
                                        Rectangle().fill(Color.evSurfaceContainerLow)
                                    }
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(idx == activePhotoIndex ? Color.evPrimary : Color.evOutlineVariant,
                                                lineWidth: idx == activePhotoIndex ? 2 : 1)
                                )
                                .opacity(idx == activePhotoIndex ? 1.0 : 0.75)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var emptySubmissionPlaceholder: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.evSurfaceContainerLow)
                    .frame(width: 56, height: 56)
                Image(systemName: task.state == .overdue ? "exclamationmark" : "hourglass")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.evOutline)
            }
            Text(task.state == .overdue ? "No photo submitted" : "Waiting for photo")
                .font(.custom("Manrope", size: 14).weight(.bold))
                .foregroundStyle(Color.evOnSurface)
            Text(task.state == .overdue
                 ? "\(child.name) missed the deadline"
                 : "\(child.name) hasn't uploaded yet")
                .font(.custom("Inter", size: 12))
                .foregroundStyle(Color.evOnSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .foregroundStyle(Color.evOutlineVariant)
        )
    }
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Profile/TaskDetailSheet.swift"
git commit -m "feat(profile): TaskDetailSheet submission block (photos + empty) (Phase 2)"
```

---

### Task 2.3: Add note block (regular note vs bypass reason)

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/TaskDetailSheet.swift` (replace `noteBlock`)

- [ ] **Step 1: Replace `noteBlock`**

Replace:

```swift
    @ViewBuilder
    private var noteBlock: some View {
        EmptyView()  // Filled in Task 2.3
    }
```

With:

```swift
    @ViewBuilder
    private var noteBlock: some View {
        let isBypass = task.state == .bypass
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isBypass
                     ? "WHY \(child.name.uppercased()) CAN'T DO IT"
                     : "\(child.name.uppercased())'S NOTE")
                    .font(.custom("Inter", size: 11).weight(.heavy))
                    .tracking(1.6)
                    .foregroundStyle(isBypass ? EvlinAddPalette.bypass : Color.evOnSurfaceVariant)
                Spacer()
                if isBypass, let at = task.submittedAt {
                    Text("at \(at)")
                        .font(.custom("Inter", size: 11))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
            }

            if let note = task.note {
                Text("\u{201C}\(note)\u{201D}")
                    .font(.custom("Inter", size: 14))
                    .foregroundStyle(Color.evOnSurface)
                    .lineSpacing(3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isBypass ? EvlinAddPalette.bypass.opacity(0.06) : Color.evSurfaceContainerLow)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isBypass ? EvlinAddPalette.bypass.opacity(0.25) : Color.evOutlineVariant,
                                    lineWidth: 1)
                    )
            } else {
                Text("No note added.")
                    .font(.custom("Inter", size: 13))
                    .italic()
                    .foregroundStyle(Color.evOutline)
            }
        }
    }
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Profile/TaskDetailSheet.swift"
git commit -m "feat(profile): TaskDetailSheet note block + bypass copy variant (Phase 2)"
```

---

### Task 2.4: Add action buttons (state-specific CTAs)

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/TaskDetailSheet.swift` (replace `actionButtons`)

- [ ] **Step 1: Replace `actionButtons`**

Replace:

```swift
    @ViewBuilder
    private var actionButtons: some View {
        EmptyView()  // Filled in Task 2.4
    }
```

With:

```swift
    @ViewBuilder
    private var actionButtons: some View {
        switch task.state {
        case .review:
            VStack(spacing: 10) {
                primaryButton("Approve submission", color: Color.evSecondary, action: onApprove)
                outlinedButton("Request redo", action: onRedo)
            }
        case .bypass:
            VStack(spacing: 10) {
                primaryButton("Allow bypass", color: EvlinAddPalette.bypass, action: onApprove)
                outlinedButton("Deny — keep as task", action: onRedo)
            }
        case .pending, .overdue:
            primaryButton("Mark as complete", color: Color.evSecondary, action: onApprove)
        case .done:
            doneStatusCard
        case .bypassed:
            bypassedStatusCard
        }
    }

    private func primaryButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Manrope", size: 14).weight(.heavy))
                .tracking(0.3)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(color)
                )
                .shadow(color: color.opacity(0.32), radius: 14, y: 4)
        }
        .buttonStyle(.plain)
    }

    private func outlinedButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.custom("Manrope", size: 12).weight(.heavy))
                .tracking(1.0)
                .foregroundStyle(Color.evOnTertiaryContainer)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(hex: 0xEF6C00), lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var doneStatusCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.evSecondary)
            Text("You approved this task")
                .font(.custom("Manrope", size: 14).weight(.bold))
                .foregroundStyle(Color.evSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.evSecondaryContainer)
        )
    }

    private var bypassedStatusCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "nosign")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text(task.title)
                .font(.custom("Manrope", size: 14).weight(.bold))
                .strikethrough(true, color: Color.evOnSurfaceVariant)
                .foregroundStyle(Color.evOnSurfaceVariant)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.evSurfaceContainerLow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
    }
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual visual check**

Open Xcode, open `TaskDetailSheet.swift`, click the Canvas previews. Should see:
- "Review (with photos)" — orange banner, 3-photo gallery, Approve/Redo buttons
- "Bypass" — purple banner, "Why Liam can't do it" block, Allow/Deny buttons
- "Overdue" — red banner, "No photo submitted" placeholder, "Mark as complete" button

Compare side-by-side with HTML rendered in browser at http://localhost:3333 — fidelity should be near pixel-level.

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Views/Profile/TaskDetailSheet.swift"
git commit -m "feat(profile): TaskDetailSheet action buttons per state (Phase 2 complete)"
```

---

# Phase 3 — TaskRow upgrade + Notification deep-link routing

Wires the rest of the chain so a notification tap lands the user in the TaskDetailSheet from Phase 2.

### Task 3.1: TaskRow gains `onOpen` callback + bypass action buttons

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Components/TaskRow.swift` (struct body)

- [ ] **Step 1: Modify TaskRow struct to accept `onOpen`**

Replace the property declarations at the top of the `TaskRow` struct (around lines 22-25):

```swift
struct TaskRow: View {
    let task: TaskItem
    var onApprove: () -> Void = {}
    var onRedo: () -> Void = {}
    var onOpen: () -> Void = {}
```

- [ ] **Step 2: Wrap the body in a Button so the row is tappable**

Find the `body` block (currently `var body: some View { VStack(spacing: 14) { mainRow ... } }`) and wrap it in a Button targeting `onOpen`:

```swift
    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 14) {
                mainRow
                if task.state == .review {
                    reviewActions
                }
                if task.state == .bypass {
                    bypassActions
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.evOutlineVariant.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
```

- [ ] **Step 3: Add `bypassActions` view**

Add right after the existing `reviewActions` computed property in the same struct:

```swift
    private var bypassActions: some View {
        HStack(spacing: 10) {
            Button(action: onApprove) {
                Text("ALLOW")
                    .font(.custom("Manrope", size: 12).weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(EvlinAddPalette.bypass)
                    )
                    .shadow(color: EvlinAddPalette.bypass.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain)

            Button(action: onRedo) {
                Text("DENY")
                    .font(.custom("Manrope", size: 12).weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(Color.evOnTertiaryContainer)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color(hex: 0xEF6C00), lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)
        }
    }
```

- [ ] **Step 4: Stop button taps inside the row from triggering onOpen**

The Approve/Redo/Allow/Deny buttons inside `reviewActions` and `bypassActions` will currently fire `onOpen` too because they're nested inside the outer Button. Add `.simultaneousGesture(TapGesture())` to each inner button — actually a cleaner approach is to use `.allowsHitTesting(true)` won't work; instead make the inner buttons opt-out via stopping propagation. Simplest fix: wrap `reviewActions`/`bypassActions` in a `Group` with `.contentShape(Rectangle()).onTapGesture {}` to swallow the row tap.

Replace the `reviewActions`/`bypassActions` calls inside `body`:

```swift
                if task.state == .review {
                    reviewActions
                        .contentShape(Rectangle())
                        .onTapGesture { /* swallow */ }
                }
                if task.state == .bypass {
                    bypassActions
                        .contentShape(Rectangle())
                        .onTapGesture { /* swallow */ }
                }
```

- [ ] **Step 5: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Components/TaskRow.swift"
git commit -m "feat(profile): TaskRow gains onOpen + bypass action buttons (Phase 3)"
```

---

### Task 3.2: ProfileView wires TaskRow.onOpen → TaskDetailSheet, accepts initialTaskId

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/ProfileView.swift`

- [ ] **Step 1: Add new state + initialTaskId param**

At the top of `ProfileView`, add:

```swift
struct ProfileView: View {
    let child: ChildProfile
    var initialTaskId: Int? = nil
    var onBack: () -> Void = {}
    var onOpenCalendar: () -> Void = {}

    @State private var rules: [RuleItem] = []
    @State private var tasks: [TaskItem] = []
    @State private var events: [ProfileEvent] = []
    @State private var devices: [DeviceItem] = []
    @State private var activeTask: TaskItem? = nil
```

- [ ] **Step 2: Hook activeTask up via overlay**

Find the `body` block. After the closing brace of `ScrollView { ... }` but BEFORE `.background(Color.evSurfaceContainerLow)`, add a fullScreenCover modifier:

```swift
            ScrollView { ... }   // existing
        }
        .background(Color.evSurfaceContainerLow)
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()
        .fullScreenCover(item: $activeTask) { task in
            NavigationStack {
                TaskDetailSheet(
                    task: task,
                    child: child,
                    onClose: { activeTask = nil },
                    onApprove: {
                        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                            tasks[i].state = (task.state == .bypass) ? .bypassed : .done
                        }
                        activeTask = nil
                    },
                    onRedo: {
                        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                            tasks[i].state = .pending
                        }
                        activeTask = nil
                    },
                    onEdit: {}    // wired in Phase 6
                )
            }
        }
        .onAppear { ... }   // existing onAppear
```

- [ ] **Step 3: Make TaskItem Identifiable for fullScreenCover(item:)**

`TaskItem` already has `Identifiable` (it has `id: Int`). But `fullScreenCover(item:)` requires the bound state to be `Optional<Hashable & Identifiable>`. Since TaskItem already conforms, this should work.

- [ ] **Step 4: Pass `onOpen` to each TaskRow**

Find the existing `ForEach(tasks) { t in TaskRow(task: t, onApprove: {...}, onRedo: {...}) }` block in ProfileView. Add `onOpen`:

```swift
                            ForEach(tasks) { t in
                                TaskRow(
                                    task: t,
                                    onApprove: {
                                        if let i = tasks.firstIndex(where: { $0.id == t.id }) {
                                            tasks[i].state = (t.state == .bypass) ? .bypassed : .done
                                        }
                                    },
                                    onRedo: {
                                        if let i = tasks.firstIndex(where: { $0.id == t.id }) {
                                            tasks[i].state = .pending
                                        }
                                    },
                                    onOpen: { activeTask = t }
                                )
                            }
```

- [ ] **Step 5: Auto-open task on appear if `initialTaskId` set**

Inside the existing `.onAppear { ... }` block at the bottom of ProfileView's body, after the existing assignments, add:

```swift
        .onAppear {
            rules = ProfileMockData.rules(for: child.id)
            tasks = ProfileMockData.tasks(for: child.id)
            events = ProfileMockData.events(for: child.id)
            devices = ProfileMockData.devices(for: child.id)
            if let id = initialTaskId, let task = tasks.first(where: { $0.id == id }) {
                activeTask = task
            }
        }
```

- [ ] **Step 6: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Profile/ProfileView.swift"
git commit -m "feat(profile): ProfileView opens TaskDetailSheet on row tap + initialTaskId deep-link (Phase 3)"
```

---

### Task 3.3: NotificationPanel routes to ProfileView with taskId

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Home/NotificationPanel.swift`
- Modify: `Evlin iOS/Evlin iOS/Views/Home/HomeView.swift`
- Modify: `Evlin iOS/Evlin iOS/ContentView.swift`

- [ ] **Step 1: NotificationPanel accepts onOpenProfile callback**

Replace the top of `NotificationPanel` struct:

```swift
struct NotificationPanel: View {
    var onClose: () -> Void
    var onOpenProfile: (String, Int?) -> Void = { _, _ in }
    @State private var notifs: [HomeNotification] = HomeMockData.notifications
```

- [ ] **Step 2: Modify `row(for:)` to call onOpenProfile when notif has kind="task"**

Find the row's `Button { ... } label: { ... }` block. Replace the action body:

```swift
        Button {
            withAnimation {
                if let idx = notifs.firstIndex(where: { $0.id == n.id }) {
                    notifs[idx].unread = false
                }
            }
            // Deep-link: task notifications open the corresponding child's
            // ProfileView with the task expanded. See HTML 240-246.
            if n.kind == "task", n.childId != "family" {
                onClose()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onOpenProfile(n.childId, n.taskId)
                }
            }
        } label: { ... }
```

- [ ] **Step 3: HomeView passes onOpenProfile through**

Find the `.fullScreenCover` (or however NotificationPanel is presented currently in HomeView). Wait — NotificationPanel is opened via the `onOpenNotifications` callback from HomeView. Let me update HomeView to accept a profile-deep-link callback.

In `HomeView.swift`, add a new parameter:

```swift
struct HomeView: View {
    @AppStorage("parentName") private var parentName: String = "Morgan"
    @State private var showSettings = false
    @Binding var selectedTab: EvlinTab
    var onOpenProfile: (ChildProfile) -> Void
    var onOpenProfileWithTask: (String, Int?) -> Void = { _, _ in }
    var onOpenNotifications: () -> Void
```

(The new `onOpenProfileWithTask` is what NotificationPanel needs.)

The actual NotificationPanel is presented from `ContentView`, not HomeView, based on `onOpenNotifications` flowing up. Let me check that and update it directly.

- [ ] **Step 4: Update ContentView's notification panel presentation**

Open `ContentView.swift`. Find the `ParentRootView` struct and the navigationDestination handling for `HomeRoute.notifications`. Update it:

```swift
                            case .notifications:
                                NotificationPanel(
                                    onClose: {
                                        if !profilePath.isEmpty { profilePath.removeLast() }
                                    },
                                    onOpenProfile: { childId, taskId in
                                        // Pop notifications, then push profile with taskId.
                                        if !profilePath.isEmpty { profilePath.removeLast() }
                                        if let child = ChildProfile.all.first(where: { $0.id == childId }) {
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                                profilePath.append(HomeRoute.profile(child, taskId: taskId))
                                            }
                                        }
                                    }
                                )
```

- [ ] **Step 5: HomeRoute enum gains taskId**

In `ContentView.swift`, find the `HomeRoute` enum and update:

```swift
enum HomeRoute: Hashable {
    case profile(ChildProfile, taskId: Int? = nil)
    case notifications
}
```

Then in `navigationDestination(for: HomeRoute.self)`, update the profile case:

```swift
                            case .profile(let child, let taskId):
                                ProfileView(
                                    child: child,
                                    initialTaskId: taskId,
                                    onBack: { if !profilePath.isEmpty { profilePath.removeLast() } },
                                    onOpenCalendar: { selectedTab = .calendar }
                                )
```

- [ ] **Step 6: Build**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Manual end-to-end test**

In Xcode, run on the device. Navigate to Home → tap bell icon → tap any "Science Project — needs review" notification → expect ProfileView to open with the Science Project's TaskDetailSheet automatically expanded.

- [ ] **Step 8: Commit**

```bash
git add "Evlin iOS/Views/Home/NotificationPanel.swift" \
        "Evlin iOS/Views/Home/HomeView.swift" \
        "Evlin iOS/ContentView.swift"
git commit -m "feat(home): notification kind=task routes to ProfileView with task expanded (Phase 3)"
```

---

# Phase 4 — Profile layout overhaul

Adds the Lock/Unlock big button, the "..." header menu (Edit / Delete profile), collapsible Devices/Rules sections, and the floating "+" FAB stub. The FAB will be hooked up to AddBottomSheet in Phase 5.

### Task 4.1: Lock/Unlock button under summary card

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/ProfileView.swift` (`summaryCard` computed property)

- [ ] **Step 1: Replace `summaryCard`**

Find the existing `private var summaryCard: some View { ... }` and replace its entire body. Per HTML 1017-1057:

```swift
    private var summaryCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 18) {
                EvlinAvatarView(url: child.avatarURL, name: child.name, size: 64, status: child.status)
                VStack(alignment: .leading, spacing: 6) {
                    Text(child.name)
                        .font(.custom("Manrope", size: 22).weight(.heavy))
                        .tracking(-0.22)
                        .foregroundStyle(Color.evPrimary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.evSecondaryContainer).frame(height: 5)
                            Capsule().fill(Color.evSecondary)
                                .frame(width: max(6, geo.size.width * child.timePct), height: 5)
                        }
                    }
                    .frame(height: 5)
                    HStack(spacing: 4) {
                        Text(child.timeLeft)
                            .font(.custom("Inter", size: 11).weight(.heavy))
                            .foregroundStyle(Color.evSecondary)
                        Text("left today")
                            .font(.custom("Inter", size: 11).weight(.heavy))
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }
                }
            }

            // Lock/Unlock big button (HTML 1036-1056)
            Button {
                // Phase 4: visual only. Backend hookup is out of scope here.
                // Toggle local mock state by dispatching a notification or @State.
                // For now, log; hookup happens when ChildProfile is observable.
                print("[Profile] Lock/Unlock tapped for \(child.id)")
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: child.status == .unlocked ? "lock" : "lock.open")
                        .font(.system(size: 18, weight: .semibold))
                    Text(child.status == .unlocked
                         ? "Lock \(child.name)'s devices"
                         : "Unlock \(child.name)'s devices")
                        .font(.custom("Manrope", size: 14).weight(.heavy))
                        .tracking(0.2)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(child.status == .unlocked ? Color.evSecondary : Color.evError)
                )
                .shadow(color: (child.status == .unlocked ? Color.evSecondary : Color.evError).opacity(0.32),
                        radius: 14, y: 4)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
        )
        .evShadow(.premium)
    }
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Profile/ProfileView.swift"
git commit -m "feat(profile): Lock/Unlock big button on summary card (Phase 4)"
```

---

### Task 4.2: Header "..." menu → Edit / Delete profile

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/ProfileView.swift` (header section + new state + sheets)

- [ ] **Step 1: Add menu state + sheet states**

In the `ProfileView` struct, after the existing `@State` declarations, add:

```swift
    @State private var showProfileMenu = false
    @State private var showEditProfile = false
    @State private var showDeleteConfirm = false
```

- [ ] **Step 2: Replace the header**

Find:

```swift
            GlassmorphicHeader(title: "\(child.name)'s Space", onBack: onBack) {
                HeaderIconButton(systemName: "ellipsis") {}
            }
```

Replace with a Menu-based variant (uses native iOS context menu, simpler than HTML's custom popover):

```swift
            GlassmorphicHeader(title: "\(child.name)'s Space", onBack: onBack) {
                Menu {
                    Button {
                        showEditProfile = true
                    } label: {
                        Label("Edit Profile", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Profile", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.evOnSurface)
                        .frame(width: 40, height: 40)
                }
            }
```

- [ ] **Step 3: Add the delete confirm dialog**

After the `.fullScreenCover(item: $activeTask)` modifier, add:

```swift
        .alert("Delete \(child.name)?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onBack()  // Phase 4 stub: backend wiring deferred
            }
        } message: {
            Text("This will remove the profile and all associated data.")
        }
```

- [ ] **Step 4: Stub the edit profile sheet**

Add another sheet modifier:

```swift
        .sheet(isPresented: $showEditProfile) {
            // Phase 4: stub. ChildEditSheet from HTML 307 needs avatar upload
            // which we defer to a polish phase. For now show a simple placeholder.
            NavigationStack {
                Text("Edit Profile (coming soon)")
                    .navigationTitle("Edit \(child.name)")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showEditProfile = false }
                        }
                    }
            }
        }
```

- [ ] **Step 5: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Profile/ProfileView.swift"
git commit -m "feat(profile): header ... menu with Edit / Delete profile (Phase 4)"
```

---

### Task 4.3: Collapsible Devices section

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/ProfileView.swift` (Devices section + new state)

- [ ] **Step 1: Add expansion state**

In `ProfileView` struct, add:

```swift
    @State private var devicesExpanded = true
    @State private var rulesExpanded = true
```

- [ ] **Step 2: Replace the existing Devices block**

Find the existing `// Devices` section in `body` (the one that says `SectionHead("Enrolled Devices")`). Replace with:

```swift
                    // Devices (collapsible per HTML 1064-1085)
                    VStack(spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                devicesExpanded.toggle()
                            }
                        } label: {
                            HStack {
                                Text("Enrolled Devices")
                                    .font(.custom("Manrope", size: 16).weight(.heavy))
                                    .tracking(-0.16)
                                    .foregroundStyle(Color.evOnSurface)
                                EvlinPill(
                                    text: "\(devices.count) \(child.status == .unlocked ? "active" : "locked")",
                                    tone: child.status == .unlocked ? .success : .danger,
                                    size: .xs
                                )
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.evOutline)
                                    .rotationEffect(.degrees(devicesExpanded ? 180 : 0))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)

                        if devicesExpanded {
                            VStack(spacing: 0) {
                                ForEach(Array(devices.enumerated()), id: \.element.id) { idx, d in
                                    DeviceRow(
                                        iconSystemName: d.iconSystemName, name: d.name,
                                        detail: d.detail, locked: d.locked,
                                        isLast: idx == devices.count - 1
                                    )
                                }
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.evSurfaceContainerLowest)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
                    )
```

- [ ] **Step 3: Replace the Active Rules section similarly**

Find `// Active Rules` and replace with:

```swift
                    // Active Rules (collapsible per HTML 1086-1121)
                    VStack(spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                rulesExpanded.toggle()
                            }
                        } label: {
                            HStack {
                                Text("Active Rules")
                                    .font(.custom("Manrope", size: 16).weight(.heavy))
                                    .tracking(-0.16)
                                    .foregroundStyle(Color.evOnSurface)
                                EvlinPill(
                                    text: "\(rules.filter(\.on).count)/\(rules.count)",
                                    tone: .success, size: .xs
                                )
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.evOutline)
                                    .rotationEffect(.degrees(rulesExpanded ? 180 : 0))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)

                        if rulesExpanded {
                            VStack(spacing: 0) {
                                ForEach($rules) { $rule in
                                    RuleRow(iconSystemName: rule.iconSystemName,
                                            title: rule.title, detail: rule.detail,
                                            isOn: $rule.on, tone: rule.tone)
                                        .padding(.horizontal, 14)
                                        .overlay(
                                            Rectangle().fill(Color.evOutlineVariant.opacity(0.4)).frame(height: 1),
                                            alignment: .bottom
                                        )
                                }
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.evSurfaceContainerLowest)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
                    )
```

- [ ] **Step 4: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Profile/ProfileView.swift"
git commit -m "feat(profile): collapsible Devices + Rules sections (Phase 4)"
```

---

### Task 4.4: Floating "+" FAB stub

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/ProfileView.swift`

- [ ] **Step 1: Add FAB state**

In `ProfileView`, add:

```swift
    @State private var showAddSheet = false
```

- [ ] **Step 2: Wrap the existing `body` in a ZStack so the FAB floats**

Replace the outer `VStack(spacing: 0) { ... }` of the `body` with:

```swift
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                // ... all existing header + ScrollView content stays here ...
            }

            // FAB (HTML 1124-1130)
            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.evPrimary))
                    .shadow(color: Color.evPrimary.opacity(0.32), radius: 24, y: 8)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
            .padding(.bottom, 24)
        }
```

- [ ] **Step 3: Add stub sheet**

Append after the existing `.alert` and `.sheet`:

```swift
        .sheet(isPresented: $showAddSheet) {
            // Phase 5 will replace this with AddBottomSheet
            Text("Add menu (coming in Phase 5)")
                .presentationDetents([.medium])
        }
```

- [ ] **Step 4: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Profile/ProfileView.swift"
git commit -m "feat(profile): floating + FAB (stubs to AddBottomSheet, Phase 4)"
```

---

# Phase 5 — Form primitives + AddBottomSheet + AddMenu

Foundation for all 6 add/edit forms. AddMenu is the 4-option router (Task / Calendar / Rule / Device). FormShell + FormField are reusable.

### Task 5.1: Create FormShell + FormField + EvlinFormInput style

**Files:**
- Create: `Evlin iOS/Evlin iOS/Components/FormShell.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

/// Cancel / Title / Save header + scrollable body. See HTML 1196-1217.
/// Use as the root of every Add*/Edit* form sheet.
struct FormShell<Content: View>: View {
    let title: String
    var canSave: Bool = true
    var saveLabel: String = "Save"
    let onCancel: () -> Void
    let onSave: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: onCancel)
                    .font(.custom("Inter", size: 14))
                    .foregroundStyle(Color.evOnSurfaceVariant)

                Spacer()

                Text(title)
                    .font(.custom("Manrope", size: 17).weight(.heavy))
                    .foregroundStyle(Color.evPrimary)

                Spacer()

                Button(saveLabel, action: onSave)
                    .font(.custom("Inter", size: 14).weight(.heavy))
                    .foregroundStyle(canSave ? Color.evPrimary : Color.evOutline)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
        }
    }
}

/// Field wrapper with uppercase label above input. See HTML 1210-1217.
struct FormField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(Color.evOnSurfaceVariant)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// TextField input style matching HTML 1194 (FORM_INPUT).
extension View {
    func evlinFormInput() -> some View {
        self
            .font(.custom("Inter", size: 14))
            .foregroundStyle(Color.evOnSurface)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.evOutlineVariant, lineWidth: 1.5)
            )
    }
}

/// Pill button used in form category/repeat selectors. See HTML 1230 / 1285.
struct FormPillSelector<Item: Hashable>: View {
    let items: [(value: Item, label: String)]
    @Binding var selected: Item

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.value) { item in
                Button {
                    selected = item.value
                } label: {
                    Text(item.label)
                        .font(.custom("Inter", size: 11).weight(.heavy))
                        .foregroundStyle(selected == item.value ? Color.evPrimary : Color.evOnSurfaceVariant)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(selected == item.value ? Color.evPrimary.opacity(0.06) : Color.white)
                        )
                        .overlay(
                            Capsule()
                                .stroke(selected == item.value ? Color.evPrimary : Color.evOutlineVariant,
                                        lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Simple flow layout for pills (wraps when row is full).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(in: proposal.width ?? 0, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(in: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var maxX: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowH = max(rowH, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (frames, CGSize(width: maxX, height: y + rowH))
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Components/FormShell.swift"
git commit -m "feat(forms): FormShell + FormField + FlowLayout primitives (Phase 5)"
```

---

### Task 5.2: AddBottomSheet + AddMenu

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Profile/AddBottomSheet.swift`

- [ ] **Step 1: Create the file with AddMenu placeholder routing**

```swift
import SwiftUI

/// Bottom sheet host that picks between AddMenu / AddTaskForm / AddRuleForm /
/// AddCalendarForm / AddDeviceForm. Mode switches as the user navigates.
/// See HTML 1152-1166.
struct AddBottomSheet: View {
    @Binding var mode: AddBottomMode?
    let child: ChildProfile
    var onCreateTask: (TaskItem) -> Void = { _ in }
    var onCreateRule: (RuleItem) -> Void = { _ in }
    var onCreateCalendar: (CalendarEvent) -> Void = { _ in }
    var onCreateDevice: (DeviceItem) -> Void = { _ in }

    var body: some View {
        Group {
            switch mode {
            case .menu:     AddMenu(child: child, mode: $mode)
            case .task:     AddTaskForm(child: child, onSave: onCreateTask, onCancel: { mode = nil })
            case .rule:     AddRuleForm(child: child, onSave: onCreateRule, onCancel: { mode = nil })
            case .calendar: AddCalendarForm(child: child, onSave: onCreateCalendar, onCancel: { mode = nil })
            case .device:   AddDeviceForm(child: child, onSave: onCreateDevice, onCancel: { mode = nil })
            case nil:       EmptyView()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

enum AddBottomMode: Hashable {
    case menu, task, rule, calendar, device
}

/// 4-option launcher. HTML 1168-1192.
private struct AddMenu: View {
    let child: ChildProfile
    @Binding var mode: AddBottomMode?

    private struct Option {
        let id: AddBottomMode
        let icon: String
        let label: String
        let sub: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add new")
                .font(.custom("Manrope", size: 18).weight(.heavy))
                .tracking(-0.18)
                .foregroundStyle(Color.evPrimary)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)

            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { idx, o in
                    Button {
                        mode = o.id
                    } label: {
                        HStack(spacing: 16) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.evSurfaceContainerLow)
                                Image(systemName: o.icon)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(Color.evPrimary)
                            }
                            .frame(width: 48, height: 48)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.label)
                                    .font(.custom("Manrope", size: 16).weight(.heavy))
                                    .foregroundStyle(Color.evOnSurface)
                                Text(o.sub)
                                    .font(.custom("Inter", size: 12))
                                    .foregroundStyle(Color.evOnSurfaceVariant)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.evOutline)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)

                    if idx < options.count - 1 {
                        Rectangle()
                            .fill(Color.evOutlineVariant.opacity(0.4))
                            .frame(height: 1)
                            .padding(.leading, 80)
                    }
                }
            }

            Spacer()
        }
    }

    private var options: [Option] {
        [
            .init(id: .task, icon: "checkmark.circle", label: "Add Task",
                  sub: "New chore or homework for \(child.name)"),
            .init(id: .calendar, icon: "calendar", label: "Add to Calendar",
                  sub: "Schedule something on \(child.name)'s day"),
            .init(id: .rule, icon: "shield", label: "Add Rule",
                  sub: "New screen-time or routine rule"),
            .init(id: .device, icon: "iphone", label: "Add Device",
                  sub: "Enroll a phone, tablet, or laptop"),
        ]
    }
}

// Stubs for forms — actual implementations come in Tasks 6-9.
struct AddTaskForm: View {
    let child: ChildProfile
    var onSave: (TaskItem) -> Void
    var onCancel: () -> Void
    var body: some View {
        FormShell(title: "New Task", canSave: false, onCancel: onCancel, onSave: {}) {
            Text("AddTaskForm — implemented in Phase 6")
        }
    }
}
struct EditTaskForm: View {
    let task: TaskItem
    var onSave: (TaskItem) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void
    var body: some View {
        FormShell(title: "Edit Task", canSave: false, onCancel: onCancel, onSave: {}) {
            Text("EditTaskForm — implemented in Phase 6")
        }
    }
}
struct AddRuleForm: View {
    let child: ChildProfile
    var onSave: (RuleItem) -> Void
    var onCancel: () -> Void
    var body: some View {
        FormShell(title: "New Rule", canSave: false, onCancel: onCancel, onSave: {}) {
            Text("AddRuleForm — implemented in Phase 7")
        }
    }
}
struct EditRuleForm: View {
    let rule: RuleItem
    var onSave: (RuleItem) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void
    var body: some View {
        FormShell(title: "Edit Rule", canSave: false, onCancel: onCancel, onSave: {}) {
            Text("EditRuleForm — implemented in Phase 7")
        }
    }
}
struct AddCalendarForm: View {
    let child: ChildProfile
    var onSave: (CalendarEvent) -> Void
    var onCancel: () -> Void
    var body: some View {
        FormShell(title: "Add to Calendar", canSave: false, onCancel: onCancel, onSave: {}) {
            Text("AddCalendarForm — implemented in Phase 8")
        }
    }
}
struct AddDeviceForm: View {
    let child: ChildProfile
    var onSave: (DeviceItem) -> Void
    var onCancel: () -> Void
    var body: some View {
        FormShell(title: "Enroll Device", canSave: false, onCancel: onCancel, onSave: {}) {
            Text("AddDeviceForm — implemented in Phase 9")
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/Profile/AddBottomSheet.swift"
git commit -m "feat(profile): AddBottomSheet + AddMenu + form stubs (Phase 5)"
```

---

### Task 5.3: Wire AddBottomSheet into ProfileView

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/ProfileView.swift`

- [ ] **Step 1: Replace `showAddSheet` with `addMode`**

In `ProfileView`, replace:

```swift
    @State private var showAddSheet = false
```

with:

```swift
    @State private var addMode: AddBottomMode? = nil
```

- [ ] **Step 2: Update FAB action**

Replace `Button { showAddSheet = true }` with:

```swift
            Button {
                addMode = .menu
            } label: { ... }
```

- [ ] **Step 3: Replace stub sheet with AddBottomSheet**

Replace the existing `.sheet(isPresented: $showAddSheet) { ... }` block:

```swift
        .sheet(item: $addMode) { _ in
            AddBottomSheet(
                mode: $addMode,
                child: child,
                onCreateTask: { newTask in
                    tasks.append(newTask)
                    addMode = nil
                },
                onCreateRule: { newRule in
                    rules.append(newRule)
                    addMode = nil
                },
                onCreateCalendar: { _ in
                    addMode = nil  // Calendar events live in CalendarMockData; Phase 8 hooks the side-effect
                },
                onCreateDevice: { newDevice in
                    devices.append(newDevice)
                    addMode = nil
                }
            )
        }
```

Note: `sheet(item:)` requires `AddBottomMode` to be `Identifiable`. Add it:

```swift
extension AddBottomMode: Identifiable {
    var id: Self { self }
}
```

(Add this at the bottom of `AddBottomSheet.swift`.)

- [ ] **Step 4: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Profile/ProfileView.swift" "Evlin iOS/Views/Profile/AddBottomSheet.swift"
git commit -m "feat(profile): AddBottomSheet wired to FAB, AddMode is Identifiable (Phase 5)"
```

---

# Phase 6 — AddTaskForm + EditTaskForm

Real implementation of the task form. Replaces the stub in Phase 5.

### Task 6.1: AddTaskForm with title / category / description / due

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/AddBottomSheet.swift` (replace AddTaskForm stub)

- [ ] **Step 1: Replace AddTaskForm**

Find:

```swift
struct AddTaskForm: View {
    let child: ChildProfile
    var onSave: (TaskItem) -> Void
    var onCancel: () -> Void
    var body: some View {
        FormShell(title: "New Task", canSave: false, onCancel: onCancel, onSave: {}) {
            Text("AddTaskForm — implemented in Phase 6")
        }
    }
}
```

Replace with the real implementation (mirrors HTML 1219-1237):

```swift
struct AddTaskForm: View {
    let child: ChildProfile
    var onSave: (TaskItem) -> Void
    var onCancel: () -> Void

    @State private var title: String = ""
    @State private var category: TaskCategory = .chore
    @State private var taskDescription: String = ""
    @State private var dueLabel: String = ""

    private let categories: [(value: TaskCategory, label: String)] = [
        (.chore, "Chore"),
        (.homework, "Homework"),
        (.reading, "Reading"),
        (.routine, "Routine"),
    ]

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        FormShell(
            title: "New Task",
            canSave: canSave,
            onCancel: onCancel,
            onSave: save
        ) {
            FormField(label: "Title") {
                TextField("e.g. Read for 20 minutes", text: $title)
                    .font(.custom("Inter", size: 14).weight(.semibold))
                    .evlinFormInput()
            }

            FormField(label: "Category") {
                FormPillSelector(items: categories, selected: $category)
            }

            FormField(label: "What to do") {
                TextField("Instructions for the student…", text: $taskDescription, axis: .vertical)
                    .lineLimit(3...6)
                    .evlinFormInput()
            }

            FormField(label: "Due (optional)") {
                TextField("e.g. Today, 6:00 PM — leave blank for no deadline", text: $dueLabel)
                    .evlinFormInput()
            }
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let nextId = (Date().timeIntervalSince1970 * 1000).truncatingRemainder(dividingBy: 1_000_000)
        let task = TaskItem(
            id: Int(nextId),
            title: trimmed,
            state: .pending,
            iconSystemName: nil,
            category: category.rawValue,
            description: taskDescription.trimmingCharacters(in: .whitespaces),
            photos: [],
            note: nil,
            submittedAt: nil,
            dueLabel: dueLabel.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : dueLabel.trimmingCharacters(in: .whitespaces)
        )
        onSave(task)
    }
}

enum TaskCategory: String, Hashable, CaseIterable {
    case chore = "Chore"
    case homework = "Homework"
    case reading = "Reading"
    case routine = "Routine"
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Profile/AddBottomSheet.swift"
git commit -m "feat(forms): AddTaskForm with title/category/description/due (Phase 6)"
```

---

### Task 6.2: EditTaskForm + delete + wire to TaskDetailSheet edit menu

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/AddBottomSheet.swift` (replace EditTaskForm stub)
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/ProfileView.swift` (TaskDetailSheet onEdit handler)

- [ ] **Step 1: Replace EditTaskForm**

Replace the stub with HTML 1239-1258 implementation:

```swift
struct EditTaskForm: View {
    let task: TaskItem
    var onSave: (TaskItem) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void

    @State private var title: String
    @State private var category: TaskCategory
    @State private var taskDescription: String
    @State private var dueLabel: String

    init(task: TaskItem,
         onSave: @escaping (TaskItem) -> Void,
         onDelete: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.task = task
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _title = State(initialValue: task.title)
        _category = State(initialValue: TaskCategory(rawValue: task.category ?? "Chore") ?? .chore)
        _taskDescription = State(initialValue: task.description ?? "")
        _dueLabel = State(initialValue: task.dueLabel ?? "")
    }

    private let categories: [(value: TaskCategory, label: String)] = [
        (.chore, "Chore"),
        (.homework, "Homework"),
        (.reading, "Reading"),
        (.routine, "Routine"),
    ]

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        FormShell(
            title: "Edit Task",
            canSave: canSave,
            onCancel: onCancel,
            onSave: save
        ) {
            FormField(label: "Title") {
                TextField("e.g. Read for 20 minutes", text: $title)
                    .font(.custom("Inter", size: 14).weight(.semibold))
                    .evlinFormInput()
            }
            FormField(label: "Category") {
                FormPillSelector(items: categories, selected: $category)
            }
            FormField(label: "What to do") {
                TextField("Instructions for the student…", text: $taskDescription, axis: .vertical)
                    .lineLimit(3...6)
                    .evlinFormInput()
            }
            FormField(label: "Due (optional)") {
                TextField("e.g. Today, 6:00 PM — leave blank for no deadline", text: $dueLabel)
                    .evlinFormInput()
            }

            Button(action: onDelete) {
                Text("Delete task")
                    .font(.custom("Inter", size: 14).weight(.heavy))
                    .foregroundStyle(Color.evError)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.evError.opacity(0.4), lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
    }

    private func save() {
        var updated = task
        updated.title = title.trimmingCharacters(in: .whitespaces)
        updated.category = category.rawValue
        updated.description = taskDescription.trimmingCharacters(in: .whitespaces)
        let trimDue = dueLabel.trimmingCharacters(in: .whitespaces)
        updated.dueLabel = trimDue.isEmpty ? nil : trimDue
        onSave(updated)
    }
}
```

- [ ] **Step 2: Wire TaskDetailSheet's `onEdit` in ProfileView**

In `ProfileView`, find the `fullScreenCover(item: $activeTask)` block. Add new state:

```swift
    @State private var editingTask: TaskItem? = nil
```

Update the TaskDetailSheet's `onEdit`:

```swift
                    onEdit: { editingTask = task }
```

After the fullScreenCover block, add:

```swift
        .sheet(item: $editingTask) { task in
            EditTaskForm(
                task: task,
                onSave: { updated in
                    if let i = tasks.firstIndex(where: { $0.id == updated.id }) {
                        tasks[i] = updated
                    }
                    activeTask = updated  // refresh the open detail sheet
                    editingTask = nil
                },
                onDelete: {
                    tasks.removeAll(where: { $0.id == task.id })
                    activeTask = nil
                    editingTask = nil
                },
                onCancel: { editingTask = nil }
            )
            .presentationDetents([.large])
        }
```

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Profile/AddBottomSheet.swift" "Evlin iOS/Views/Profile/ProfileView.swift"
git commit -m "feat(forms): EditTaskForm with delete, wired to TaskDetailSheet ... menu (Phase 6 complete)"
```

---

(Plan continues in Part 2 for Phases 7-12 — see next file segment.)

---

# Phase 7 — AddRuleForm + EditRuleForm

Mirrors HTML 1292-1341. Rule has: title / detail / icon (7 SF Symbols) / tone (Primary/Calm/Neutral).

### Task 7.1: AddRuleForm

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/AddBottomSheet.swift` (replace AddRuleForm stub)

- [ ] **Step 1: Replace AddRuleForm**

```swift
struct AddRuleForm: View {
    let child: ChildProfile
    var onSave: (RuleItem) -> Void
    var onCancel: () -> Void

    @State private var title: String = ""
    @State private var detail: String = ""
    @State private var icon: String = "shield"
    @State private var tone: RuleRow.Tone = .primary

    private let icons = ["shield", "display", "moon", "sun.max", "iphone.slash", "nosign", "clock"]
    private let tones: [(value: RuleRow.Tone, label: String)] = [
        (.primary, "Primary"),
        (.tertiary, "Calm"),
        (.neutral, "Neutral"),
    ]

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        FormShell(
            title: "New Rule",
            canSave: canSave,
            onCancel: onCancel,
            onSave: save
        ) {
            FormField(label: "Title") {
                TextField("e.g. No phones at dinner", text: $title)
                    .font(.custom("Inter", size: 14).weight(.semibold))
                    .evlinFormInput()
            }
            FormField(label: "Detail") {
                TextField("e.g. 6:00 – 7:00 PM", text: $detail)
                    .evlinFormInput()
            }
            FormField(label: "Icon") {
                FlowLayout(spacing: 8) {
                    ForEach(icons, id: \.self) { name in
                        Button {
                            icon = name
                        } label: {
                            Image(systemName: name)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(icon == name ? Color.evPrimary : Color.evOnSurfaceVariant)
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(icon == name ? Color.evPrimary.opacity(0.06) : Color.white)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(icon == name ? Color.evPrimary : Color.evOutlineVariant,
                                                lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            FormField(label: "Tone") {
                FormPillSelector(items: tones, selected: $tone)
            }
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let id = "rule_\(Int(Date().timeIntervalSince1970 * 1000))"
        let rule = RuleItem(
            id: id,
            iconSystemName: icon,
            title: trimmed,
            detail: detail.trimmingCharacters(in: .whitespaces),
            on: true,
            tone: tone
        )
        onSave(rule)
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Profile/AddBottomSheet.swift"
git commit -m "feat(forms): AddRuleForm with icon picker + tone (Phase 7)"
```

---

### Task 7.2: EditRuleForm + wire RuleRow edit pencil

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/AddBottomSheet.swift` (replace EditRuleForm stub)
- Modify: `Evlin iOS/Evlin iOS/Components/RuleRow.swift` (add edit button)
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/ProfileView.swift` (wire editingRule sheet)

- [ ] **Step 1: Replace EditRuleForm**

```swift
struct EditRuleForm: View {
    let rule: RuleItem
    var onSave: (RuleItem) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void

    @State private var title: String
    @State private var detail: String
    @State private var icon: String
    @State private var tone: RuleRow.Tone

    init(rule: RuleItem,
         onSave: @escaping (RuleItem) -> Void,
         onDelete: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.rule = rule
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _title = State(initialValue: rule.title)
        _detail = State(initialValue: rule.detail)
        _icon = State(initialValue: rule.iconSystemName)
        _tone = State(initialValue: rule.tone)
    }

    private let icons = ["shield", "display", "moon", "sun.max", "iphone.slash", "nosign", "clock"]
    private let tones: [(value: RuleRow.Tone, label: String)] = [
        (.primary, "Primary"),
        (.tertiary, "Calm"),
        (.neutral, "Neutral"),
    ]

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        FormShell(
            title: "Edit Rule",
            canSave: canSave,
            onCancel: onCancel,
            onSave: save
        ) {
            FormField(label: "Title") {
                TextField("e.g. No phones at dinner", text: $title)
                    .font(.custom("Inter", size: 14).weight(.semibold))
                    .evlinFormInput()
            }
            FormField(label: "Detail") {
                TextField("e.g. 6:00 – 7:00 PM", text: $detail).evlinFormInput()
            }
            FormField(label: "Icon") {
                FlowLayout(spacing: 8) {
                    ForEach(icons, id: \.self) { name in
                        Button { icon = name } label: {
                            Image(systemName: name)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(icon == name ? Color.evPrimary : Color.evOnSurfaceVariant)
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(icon == name ? Color.evPrimary.opacity(0.06) : Color.white)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(icon == name ? Color.evPrimary : Color.evOutlineVariant,
                                                lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            FormField(label: "Tone") {
                FormPillSelector(items: tones, selected: $tone)
            }
            Button(action: onDelete) {
                Text("Delete rule")
                    .font(.custom("Inter", size: 14).weight(.heavy))
                    .foregroundStyle(Color.evError)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.evError.opacity(0.4), lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
    }

    private func save() {
        var updated = rule
        updated.title = title.trimmingCharacters(in: .whitespaces)
        updated.detail = detail.trimmingCharacters(in: .whitespaces)
        updated.iconSystemName = icon
        updated.tone = tone
        onSave(updated)
    }
}
```

Note: `RuleItem`'s fields (`iconSystemName`, `title`, `detail`, `tone`) are currently `let`. Make them `var`:

In `Models/ProfileMockData.swift`, change `RuleItem`:

```swift
struct RuleItem: Identifiable, Hashable {
    let id: String
    var iconSystemName: String
    var title: String
    var detail: String
    var on: Bool
    var tone: RuleRow.Tone
}
```

- [ ] **Step 2: Add edit pencil to RuleRow**

In `Components/RuleRow.swift`, replace the trailing element. Find where the Toggle is rendered and add a pencil button next to it:

```swift
struct RuleRow: View {
    let iconSystemName: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    let tone: Tone
    var onEdit: () -> Void = {}
    ...

    var body: some View {
        HStack(spacing: 16) {
            // ... existing icon + title block ...

            Spacer()

            HStack(spacing: 14) {
                Toggle("", isOn: $isOn).labelsHidden()
                Button(action: onEdit) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.evOutline)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 16)
    }
    ...
}
```

- [ ] **Step 3: Wire editingRule in ProfileView**

Add `@State`:

```swift
    @State private var editingRule: RuleItem? = nil
```

Update RuleRow call site:

```swift
                                ForEach($rules) { $rule in
                                    RuleRow(
                                        iconSystemName: rule.iconSystemName,
                                        title: rule.title, detail: rule.detail,
                                        isOn: $rule.on, tone: rule.tone,
                                        onEdit: { editingRule = rule }
                                    )
                                    .padding(.horizontal, 14)
                                    .overlay(
                                        Rectangle().fill(Color.evOutlineVariant.opacity(0.4)).frame(height: 1),
                                        alignment: .bottom
                                    )
                                }
```

Add sheet:

```swift
        .sheet(item: $editingRule) { rule in
            EditRuleForm(
                rule: rule,
                onSave: { updated in
                    if let i = rules.firstIndex(where: { $0.id == updated.id }) {
                        rules[i] = updated
                    }
                    editingRule = nil
                },
                onDelete: {
                    rules.removeAll(where: { $0.id == rule.id })
                    editingRule = nil
                },
                onCancel: { editingRule = nil }
            )
            .presentationDetents([.large])
        }
```

- [ ] **Step 4: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Profile/AddBottomSheet.swift" \
        "Evlin iOS/Views/Profile/ProfileView.swift" \
        "Evlin iOS/Components/RuleRow.swift" \
        "Evlin iOS/Models/ProfileMockData.swift"
git commit -m "feat(forms): EditRuleForm + RuleRow edit pencil + ProfileView sheet (Phase 7 complete)"
```

---

# Phase 8 — AddCalendarForm

Mirrors HTML 1260-1290. Calendar event creation with title / time range / category / repeat.

### Task 8.1: AddCalendarForm

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/AddBottomSheet.swift` (replace stub)
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/ProfileView.swift` (onCreateCalendar handler)

- [ ] **Step 1: Replace AddCalendarForm**

```swift
struct AddCalendarForm: View {
    let child: ChildProfile
    var onSave: (CalendarEvent) -> Void
    var onCancel: () -> Void

    @State private var title: String = ""
    @State private var startTime: String = "04:00 PM"
    @State private var endTime: String = "05:00 PM"
    @State private var category: String = "Activity"
    @State private var recurrence: String = "none"

    private let categories: [(value: String, label: String)] = [
        ("Activity", "Activity"), ("Lesson", "Lesson"), ("Sport", "Sport"),
        ("Family", "Family"), ("Routine", "Routine"), ("Study", "Study"),
    ]
    private let repeats: [(value: String, label: String)] = [
        ("none", "Once"), ("daily", "Daily"),
        ("weekdays", "Weekdays"), ("weekly", "Weekly"),
    ]

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        FormShell(
            title: "Add to Calendar",
            canSave: canSave,
            onCancel: onCancel,
            onSave: save
        ) {
            FormField(label: "Title") {
                TextField("e.g. Soccer Practice", text: $title)
                    .font(.custom("Inter", size: 14).weight(.semibold))
                    .evlinFormInput()
            }
            FormField(label: "Time") {
                HStack(spacing: 8) {
                    TextField("Start", text: $startTime).evlinFormInput()
                    Text("–").foregroundStyle(Color.evOnSurfaceVariant)
                    TextField("End", text: $endTime).evlinFormInput()
                }
            }
            FormField(label: "Category") {
                FormPillSelector(items: categories, selected: $category)
            }
            FormField(label: "Repeat") {
                FormPillSelector(items: repeats, selected: $recurrence)
            }
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let event = CalendarEvent(
            col: child.id,
            title: trimmed,
            emoji: emojiFor(category),
            start: startTime,
            end: endTime,
            category: category,
            location: "",
            note: "",
            recurrence: recurrence
        )
        onSave(event)
    }

    private func emojiFor(_ cat: String) -> String {
        switch cat {
        case "Activity": return "📅"
        case "Lesson":   return "📚"
        case "Sport":    return "⚽"
        case "Family":   return "🏠"
        case "Routine":  return "🌙"
        case "Study":    return "📐"
        default:         return "🗓️"
        }
    }
}
```

- [ ] **Step 2: Wire onCreateCalendar in ProfileView**

In `ProfileView`, the `onCreateCalendar:` callback needs to push the event into shared state. Calendar mock data is currently a static let in `CalendarMockData`. Add a runtime-mutable store:

In `Models/CalendarMockData.swift`, after the `eventsByOffset` static let, add:

```swift
    /// Runtime-added events (per session). Phase 8: ProfileView's "Add Calendar"
    /// pushes here. CalendarView's `events(for:)` merges these in.
    /// Keyed by days-offset same as eventsByOffset.
    static var runtimeEventsByOffset: [Int: [CalendarEvent]] = [:]
```

Update `events(for:)` to merge:

```swift
    static func events(for date: Date) -> [CalendarEvent] {
        let offset = daysFromToday(to: date)
        let baseline = eventsByOffset[offset] ?? []
        let runtime = runtimeEventsByOffset[offset] ?? []
        return baseline + runtime
    }
```

In ProfileView, update the `onCreateCalendar`:

```swift
                onCreateCalendar: { event in
                    // Push to today (offset 0) — Phase 8 simplification.
                    // Phase 11 will let user pick the day.
                    var todays = CalendarMockData.runtimeEventsByOffset[0] ?? []
                    todays.append(event)
                    CalendarMockData.runtimeEventsByOffset[0] = todays
                    addMode = nil
                },
```

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Profile/AddBottomSheet.swift" \
        "Evlin iOS/Views/Profile/ProfileView.swift" \
        "Evlin iOS/Models/CalendarMockData.swift"
git commit -m "feat(forms): AddCalendarForm wired to runtime calendar store (Phase 8)"
```

---

# Phase 9 — AddDeviceForm + DeviceAppsSheet

Mirrors HTML 1343-1371 (form) + HTML 563-625 (apps sheet). Device tap from Profile devices section opens DeviceAppsSheet (per-app limits + toggles).

### Task 9.1: APP_DATA mock + DeviceAppItem model

**Files:**
- Create: `Evlin iOS/Evlin iOS/Models/DeviceAppsMockData.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

/// Per-app data for DeviceAppsSheet. Mirrors HTML 627-644 (APP_DATA).
struct DeviceAppItem: Identifiable, Hashable {
    let id: String
    let name: String
    let iconSystemName: String
    let brandColor: Color
    let bgColor: Color
    var enabled: Bool = true
    var usedMin: Int        // minutes used today
    var limitMin: Int       // current limit
}

enum DeviceAppsMockData {
    static func apps(for childId: String) -> [DeviceAppItem] {
        switch childId {
        case "liam":
            return [
                .init(id: "youtube",   name: "YouTube",   iconSystemName: "play.tv",
                      brandColor: Color(hex: 0xFF0000), bgColor: Color.white,
                      usedMin: 75, limitMin: 60),
                .init(id: "roblox",    name: "Roblox",    iconSystemName: "gamecontroller",
                      brandColor: Color(hex: 0xE2231A), bgColor: Color.black,
                      usedMin: 45, limitMin: 30),
                .init(id: "tiktok",    name: "TikTok",    iconSystemName: "music.note",
                      brandColor: Color(hex: 0xFF0050), bgColor: Color.black,
                      usedMin: 20, limitMin: 20),
                .init(id: "minecraft", name: "Minecraft", iconSystemName: "square.grid.3x3",
                      brandColor: Color(hex: 0x4CAF50), bgColor: Color(hex: 0x5C4033),
                      usedMin: 0, limitMin: 45),
            ]
        case "maya":
            return [
                .init(id: "youtube",   name: "YouTube",   iconSystemName: "play.tv",
                      brandColor: Color(hex: 0xFF0000), bgColor: Color.white,
                      usedMin: 30, limitMin: 45),
                .init(id: "spotify",   name: "Spotify",   iconSystemName: "headphones",
                      brandColor: Color(hex: 0x1DB954), bgColor: Color(hex: 0x191414),
                      usedMin: 60, limitMin: 90),
                .init(id: "duolingo",  name: "Duolingo",  iconSystemName: "character.book.closed",
                      brandColor: Color(hex: 0x58CC02), bgColor: Color.white,
                      usedMin: 15, limitMin: 30),
            ]
        default:  // emma
            return [
                .init(id: "youtube",   name: "YouTube",   iconSystemName: "play.tv",
                      brandColor: Color(hex: 0xFF0000), bgColor: Color.white,
                      usedMin: 0,  limitMin: 20),
                .init(id: "netflix",   name: "Netflix",   iconSystemName: "film",
                      brandColor: Color(hex: 0xE50914), bgColor: Color.black,
                      usedMin: 0,  limitMin: 30),
                .init(id: "khan",      name: "Khan Kids", iconSystemName: "graduationcap",
                      brandColor: Color(hex: 0x14BF96), bgColor: Color.white,
                      usedMin: 0,  limitMin: 60),
            ]
        }
    }

    static let limitOptions: [Int] = [15, 20, 30, 45, 60, 90, 120]

    static func formatLimit(_ min: Int) -> String {
        if min >= 60 {
            let h = min / 60
            let m = min % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(min)m"
    }

    static func formatUsed(_ min: Int) -> String {
        if min >= 60 {
            return "\(min / 60)h \(min % 60)m"
        }
        return "\(min)m"
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Models/DeviceAppsMockData.swift"
git commit -m "feat(mock): DeviceAppItem + APP_DATA per child (Phase 9)"
```

---

### Task 9.2: DeviceAppsSheet

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Profile/DeviceAppsSheet.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

/// Per-app management for one device. Mirrors HTML 563-625.
/// Each row: app icon + name + toggle + tappable limit pill + progress bar.
/// Tap pill → expands inline 7-option limit picker (15/20/30/45/60/90/120 min).
struct DeviceAppsSheet: View {
    let device: DeviceItem
    let childId: String
    var onClose: () -> Void = {}

    @State private var apps: [DeviceAppItem] = []
    @State private var editingLimitFor: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { idx, app in
                        appRow(app)
                        if idx < apps.count - 1 {
                            Rectangle()
                                .fill(Color.evOutlineVariant.opacity(0.4))
                                .frame(height: 1)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.evSurfaceContainerLowest)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
                )
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 110)
            }
        }
        .background(Color.evSurfaceContainerLow)
        .onAppear { apps = DeviceAppsMockData.apps(for: childId) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("APP LIMITS")
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                Text(device.name)
                    .font(.custom("Manrope", size: 19).weight(.heavy))
                    .tracking(-0.2)
                    .foregroundStyle(Color.evPrimary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Color.evSurface
                .overlay(
                    Rectangle()
                        .fill(Color.evOutlineVariant)
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    private func appRow(_ app: DeviceAppItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(app.bgColor)
                    Image(systemName: app.iconSystemName)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(app.brandColor)
                }
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(app.name)
                            .font(.custom("Manrope", size: 14).weight(.bold))
                            .foregroundStyle(Color.evOnSurface)

                        Spacer()

                        // Limit pill (tap to expand picker)
                        Button {
                            editingLimitFor = (editingLimitFor == app.id) ? nil : app.id
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.system(size: 11))
                                Text(DeviceAppsMockData.formatLimit(app.limitMin))
                                    .font(.custom("Manrope", size: 11).weight(.heavy))
                            }
                            .foregroundStyle(app.enabled ? Color.evPrimary : Color.evOutline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(app.enabled ? Color.evPrimaryContainer : Color.evSurfaceContainerHigh)
                            )
                        }
                        .buttonStyle(.plain)

                        Toggle("", isOn: Binding(
                            get: { app.enabled },
                            set: { newValue in
                                if let i = apps.firstIndex(where: { $0.id == app.id }) {
                                    apps[i].enabled = newValue
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(Color.evSecondary)
                    }

                    // Progress bar
                    progressBar(for: app)

                    // Status text
                    HStack {
                        Text(statusText(for: app))
                            .font(.custom("Inter", size: 10))
                            .foregroundStyle(app.enabled && app.usedMin >= app.limitMin
                                             ? Color.evError
                                             : Color.evOnSurfaceVariant)
                        Spacer()
                        if app.enabled && app.usedMin >= app.limitMin {
                            Text("LIMIT REACHED")
                                .font(.custom("Inter", size: 10).weight(.heavy))
                                .tracking(0.8)
                                .foregroundStyle(Color.evError)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            if editingLimitFor == app.id {
                limitPicker(for: app)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }
        }
    }

    private func progressBar(for app: DeviceAppItem) -> some View {
        let pct = min(1.0, Double(app.usedMin) / Double(max(app.limitMin, 1)))
        let color: Color = !app.enabled
            ? Color.evOutlineVariant
            : pct >= 1.0 ? Color.evError
            : pct > 0.75 ? Color(hex: 0xF97316)
            : Color.evSecondary
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.evSurfaceContainerHigh)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * (app.enabled ? pct : 0))
            }
        }
        .frame(height: 4)
    }

    private func statusText(for app: DeviceAppItem) -> String {
        guard app.enabled else { return "Limit off" }
        if app.usedMin == 0 { return "Not used today" }
        return "\(DeviceAppsMockData.formatUsed(app.usedMin)) used"
    }

    private func limitPicker(for app: DeviceAppItem) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(DeviceAppsMockData.limitOptions, id: \.self) { min in
                Button {
                    if let i = apps.firstIndex(where: { $0.id == app.id }) {
                        apps[i].limitMin = min
                    }
                    editingLimitFor = nil
                } label: {
                    Text(DeviceAppsMockData.formatLimit(min))
                        .font(.custom("Manrope", size: 11).weight(.heavy))
                        .foregroundStyle(app.limitMin == min ? .white : Color.evOnSurface)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(app.limitMin == min ? Color.evPrimary : Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(app.limitMin == min ? Color.evPrimary : Color.evOutlineVariant,
                                        lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
```

- [ ] **Step 2: Wire DeviceRow → DeviceAppsSheet in ProfileView**

In `ProfileView`, add `@State`:

```swift
    @State private var activeDevice: DeviceItem? = nil
```

Update DeviceRow inside the devices block to pass `onPress`. First add `onPress` to `Components/DeviceRow.swift`:

```swift
struct DeviceRow: View {
    let iconSystemName: String
    let name: String
    let detail: String
    let locked: Bool
    let isLast: Bool
    var onPress: () -> Void = {}

    var body: some View {
        Button(action: onPress) {
            HStack { ... existing layout ... }
        }
        .buttonStyle(.plain)
    }
}
```

(Wrap existing layout in Button.)

In ProfileView devices section, set `onPress`:

```swift
                                ForEach(Array(devices.enumerated()), id: \.element.id) { idx, d in
                                    DeviceRow(
                                        iconSystemName: d.iconSystemName, name: d.name,
                                        detail: d.detail, locked: d.locked,
                                        isLast: idx == devices.count - 1,
                                        onPress: { activeDevice = d }
                                    )
                                }
```

Add fullScreenCover for the device sheet:

```swift
        .fullScreenCover(item: $activeDevice) { device in
            NavigationStack {
                DeviceAppsSheet(
                    device: device,
                    childId: child.id,
                    onClose: { activeDevice = nil }
                )
            }
        }
```

Note: `DeviceItem.id` is currently `let id = UUID()` so it's already Identifiable.

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Profile/DeviceAppsSheet.swift" \
        "Evlin iOS/Views/Profile/ProfileView.swift" \
        "Evlin iOS/Components/DeviceRow.swift"
git commit -m "feat(profile): DeviceAppsSheet with per-app toggle/limit picker (Phase 9)"
```

---

### Task 9.3: AddDeviceForm

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Profile/AddBottomSheet.swift` (replace stub)

- [ ] **Step 1: Replace AddDeviceForm**

```swift
struct AddDeviceForm: View {
    let child: ChildProfile
    var onSave: (DeviceItem) -> Void
    var onCancel: () -> Void

    @State private var name: String = ""
    @State private var detail: String = ""
    @State private var iconSystemName: String = "iphone"

    private struct DeviceType: Hashable {
        let icon: String
        let label: String
    }
    private let types: [DeviceType] = [
        .init(icon: "iphone",          label: "Phone"),
        .init(icon: "ipad",            label: "Tablet"),
        .init(icon: "laptopcomputer",  label: "Laptop"),
        .init(icon: "desktopcomputer", label: "Desktop"),
        .init(icon: "applewatch",      label: "Watch"),
        .init(icon: "tv",              label: "TV"),
    ]

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        FormShell(
            title: "Enroll Device",
            canSave: canSave,
            onCancel: onCancel,
            onSave: save
        ) {
            FormField(label: "Device type") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(types, id: \.icon) { t in
                        Button {
                            iconSystemName = t.icon
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: t.icon)
                                    .font(.system(size: 24, weight: .medium))
                                Text(t.label)
                                    .font(.custom("Inter", size: 11).weight(.heavy))
                            }
                            .foregroundStyle(iconSystemName == t.icon ? Color.evPrimary : Color.evOnSurfaceVariant)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(iconSystemName == t.icon ? Color.evPrimary.opacity(0.06) : Color.white)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(iconSystemName == t.icon ? Color.evPrimary : Color.evOutlineVariant,
                                            lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            FormField(label: "Name") {
                TextField("e.g. iPhone 15", text: $name)
                    .font(.custom("Inter", size: 14).weight(.semibold))
                    .evlinFormInput()
            }
            FormField(label: "Notes") {
                TextField("e.g. \(child.name)'s primary phone", text: $detail)
                    .evlinFormInput()
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let device = DeviceItem(
            iconSystemName: iconSystemName,
            name: trimmed,
            detail: detail.trimmingCharacters(in: .whitespaces),
            locked: false
        )
        onSave(device)
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Profile/AddBottomSheet.swift"
git commit -m "feat(forms): AddDeviceForm with type grid (Phase 9 complete)"
```

---

# Phase 10 — Calendar multi-column timeline

Visual rebuild of the timeline. Default view shows 4 columns (Family / Liam / Maya / Emma); per-person filter narrows to 1 column. Mirrors HTML 1605-1710.

### Task 10.1: Refactor CalendarView timeline to multi-column grid

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Calendar/CalendarView.swift` (`timelineBody` and helpers)

- [ ] **Step 1: Replace `timelineBody`**

This is a substantial restructure. Replace the existing `timelineBody` computed property with a multi-column version:

```swift
    /// Visible columns: when no person focus, all 4. When focused, just that one.
    private var visibleColumns: [CalendarPerson] {
        guard let focusPerson else { return CalendarMockData.people }
        return CalendarMockData.people.filter { $0.id == focusPerson }
    }

    private var timelineBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !allDayItems.isEmpty {
                allDayBar
            }

            HStack(alignment: .top, spacing: 0) {
                timeGutter
                    .frame(width: CalendarMockData.TIME_W)

                // Multi-column event grid
                ZStack(alignment: .topLeading) {
                    // Hour grid lines
                    ForEach(CalendarMockData.START_H...CalendarMockData.END_H, id: \.self) { h in
                        Rectangle()
                            .fill(Color.evOutlineVariant.opacity(0.4))
                            .frame(height: 1)
                            .offset(y: CGFloat(h) * CalendarMockData.HOUR_H)
                    }

                    // Per-column events
                    GeometryReader { geo in
                        let colWidth = geo.size.width / CGFloat(visibleColumns.count)
                        ForEach(Array(visibleColumns.enumerated()), id: \.element.id) { colIdx, person in
                            let colEvents = visibleEvents.filter { $0.col == person.id }
                            ZStack(alignment: .topLeading) {
                                // Tap empty space to create event (Phase 11 wires it)
                                Rectangle()
                                    .fill(Color.clear)
                                    .contentShape(Rectangle())
                                    .frame(width: colWidth, height: totalHeight)

                                ForEach(colEvents) { ev in
                                    columnEventPill(ev, color: person.color, columnWidth: colWidth)
                                        .offset(y: CalendarMockData.yFor(ev.start))
                                }
                            }
                            .frame(width: colWidth, alignment: .topLeading)
                            .offset(x: colWidth * CGFloat(colIdx))
                        }
                    }
                    .frame(height: totalHeight)

                    if isViewingToday {
                        currentTimeIndicator
                    }
                }
                .frame(height: totalHeight, alignment: .top)
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
        }
    }

    private var allDayBar: some View {
        HStack(spacing: 8) {
            Text("ALL DAY")
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(Color.evOnSurfaceVariant)
            ForEach(allDayItems) { item in
                let p = CalendarMockData.person(item.col)
                Text(item.title)
                    .font(.custom("Inter", size: 12).weight(.semibold))
                    .foregroundStyle(p.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(p.bg))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func columnEventPill(_ ev: CalendarEvent, color: Color, columnWidth: CGFloat) -> some View {
        let h = CalendarMockData.heightFor(start: ev.start, end: ev.end)
        return Button { activeEvent = ev } label: {
            VStack(alignment: .leading, spacing: 3) {
                if h > 38 {
                    Text(ev.emoji).font(.system(size: 12))
                }
                HStack(spacing: 4) {
                    if ev.recurrence != "none" {
                        Image(systemName: "repeat")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Text(ev.title)
                        .font(.custom("Manrope", size: 11).weight(.heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if h > 54 {
                    Text("\(ev.start.replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "")) – \(ev.end.replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: ""))")
                        .font(.custom("Inter", size: 9).weight(.bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .padding(h > 40 ? 7 : 5)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: h)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color)
            )
            .shadow(color: color.opacity(0.33), radius: 6, y: 1)
            .padding(.horizontal, 3)
        }
        .buttonStyle(.plain)
        .frame(width: columnWidth)
    }
```

- [ ] **Step 2: Update avatarRow header to highlight active focus**

The existing `avatarRow` already supports focus toggling — verify it still works after timeline rewrite.

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 4: Visual check on device**

Open Calendar tab. Should see 4 columns with events distributed across them. Tapping an avatar at top should narrow to single column. Compare to HTML rendered at http://localhost:3333/Evlin_Parent_view/Evlin%20Parent%20Dashboard%20(1).html → click Calendar tab.

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Views/Calendar/CalendarView.swift"
git commit -m "feat(calendar): multi-column timeline (4 cols default, focus narrows to 1) (Phase 10)"
```

---

# Phase 11 — Calendar FAB + EventDetail edit/new mode + recurrence

Wires the FAB to a new EventDetailSheet, adds edit mode, adds recurrence picker, makes events created from this flow persist via runtime store.

### Task 11.1: EventDetailCard upgrade — edit mode + isNew mode

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Calendar/EventDetailCard.swift`

- [ ] **Step 1: Add new state for edit mode**

At the top of `EventDetailCard`, add:

```swift
struct EventDetailCard: View {
    let event: CalendarEvent
    let person: CalendarPerson
    let dayLabel: String
    var isNew: Bool = false
    var onClose: () -> Void = {}
    var onSave: (CalendarEvent) -> Void = { _ in }
    var onDelete: () -> Void = {}

    @State private var isEditing: Bool
    @State private var draft: CalendarEvent
    @State private var reminderOn: Bool = true

    init(event: CalendarEvent,
         person: CalendarPerson,
         dayLabel: String,
         isNew: Bool = false,
         onClose: @escaping () -> Void = {},
         onSave: @escaping (CalendarEvent) -> Void = { _ in },
         onDelete: @escaping () -> Void = {}) {
        self.event = event
        self.person = person
        self.dayLabel = dayLabel
        self.isNew = isNew
        self.onClose = onClose
        self.onSave = onSave
        self.onDelete = onDelete
        _isEditing = State(initialValue: isNew)
        _draft = State(initialValue: event)
    }
```

- [ ] **Step 2: Replace `body` to switch between read and edit modes**

Replace the existing body's content layout. Keep the outer ZStack/blur backdrop, but inside the Card:

```swift
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 12)

                Divider()

                if isEditing {
                    editForm
                } else {
                    readView
                }

                footer
                    .padding(.top, 14)
            }
```

Replace the existing field-rows block (personRow / categoryRow / noteRow / locationRow / reminderRow) with:

```swift
    private var readView: some View {
        VStack(alignment: .leading, spacing: 0) {
            personRow
            Divider()
            categoryRow
            Divider()
            recurrenceRow   // NEW
            Divider()
            noteRow
            Divider()
            locationRow
            Divider()
            reminderRow
        }
    }

    private var recurrenceRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "repeat")
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 20)
            Text(recurrenceLabel(event.recurrence))
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    private func recurrenceLabel(_ value: String) -> String {
        switch value {
        case "daily":    return "Every day"
        case "weekdays": return "Every weekday"
        case "weekly":   return "Every week"
        case "monthly":  return "Every month"
        default:         return "Does not repeat"
        }
    }

    private var editForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            evField("TITLE") {
                TextField("Event title", text: $draft.title).evlinFormInput()
            }

            evField("TIME") {
                HStack(spacing: 8) {
                    TextField("Start", text: $draft.start).evlinFormInput()
                    Text("–").foregroundStyle(Color.evOnSurfaceVariant)
                    TextField("End", text: $draft.end).evlinFormInput()
                }
            }

            evField("CATEGORY") {
                FormPillSelector(
                    items: [("Activity", "Activity"), ("Lesson", "Lesson"),
                            ("Sport", "Sport"), ("Family", "Family"),
                            ("Routine", "Routine"), ("Study", "Study")],
                    selected: Binding(get: { draft.category }, set: { draft.category = $0 })
                )
            }

            evField("REPEAT") {
                FormPillSelector(
                    items: [("none", "Once"), ("daily", "Daily"),
                            ("weekdays", "Weekdays"), ("weekly", "Weekly")],
                    selected: Binding(get: { draft.recurrence }, set: { draft.recurrence = $0 })
                )
            }

            evField("NOTE") {
                TextField("Add a note…", text: Binding(
                    get: { draft.note },
                    set: { draft.note = $0 }
                ), axis: .vertical)
                .lineLimit(3...5)
                .evlinFormInput()
            }

            evField("LOCATION") {
                TextField("Add location…", text: Binding(
                    get: { draft.location },
                    set: { draft.location = $0 }
                ))
                .evlinFormInput()
            }
        }
        .padding(.vertical, 4)
    }

    private func evField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(Color.evOnSurfaceVariant)
            content()
        }
    }
```

- [ ] **Step 3: Replace footer to support edit/save/cancel**

Find the `private var footer` and replace:

```swift
    private var footer: some View {
        HStack(spacing: 10) {
            if isEditing {
                Button {
                    if isNew { onClose() } else {
                        draft = event
                        isEditing = false
                    }
                } label: {
                    Text(isNew ? "Cancel" : "Discard")
                        .font(.custom("Manrope", size: 14).weight(.heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundStyle(Color.evOnSurface)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.evOutlineVariant, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    onSave(draft)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                        Text(isNew ? "Create Event" : "Save Changes")
                    }
                    .font(.custom("Manrope", size: 14).weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(canSaveDraft ? Color.evPrimary : Color.evSurfaceContainerHigh)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSaveDraft)
            } else {
                Button(action: onClose) {
                    Text("Close")
                        .font(.custom("Manrope", size: 14).weight(.heavy))
                        .foregroundStyle(Color.evOnSurface)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)

                Button {
                    isEditing = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                        Text("Edit")
                    }
                    .font(.custom("Manrope", size: 14).weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.evPrimary)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var canSaveDraft: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
    }
```

- [ ] **Step 4: Build**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Views/Calendar/EventDetailCard.swift"
git commit -m "feat(calendar): EventDetailCard supports edit + isNew modes (Phase 11)"
```

---

### Task 11.2: Wire CalendarView FAB to new event flow

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Calendar/CalendarView.swift`

- [ ] **Step 1: Add new event state**

In `CalendarView`:

```swift
    @State private var newEvent: (event: CalendarEvent, person: CalendarPerson)? = nil
```

- [ ] **Step 2: Replace `floatingAddButton` action**

```swift
    private var floatingAddButton: some View {
        Button {
            startNewEvent()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.evPrimary))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
    }

    private func startNewEvent(person: CalendarPerson? = nil, startTime: String = "04:00 PM") {
        let target = person ?? (focusPerson.flatMap { id in CalendarMockData.people.first { $0.id == id } } ?? CalendarMockData.people[0])
        let blank = CalendarEvent(
            col: target.id,
            title: "",
            emoji: "🗓️",
            start: startTime,
            end: addOneHour(to: startTime),
            category: "Activity",
            location: "",
            note: "",
            recurrence: "none"
        )
        newEvent = (blank, target)
    }

    private func addOneHour(to timeStr: String) -> String {
        // Simple: assume "HH:MM AM/PM"; bump hour by 1 keeping period boundary.
        let parts = timeStr.split(separator: " ")
        guard parts.count == 2 else { return timeStr }
        let hm = parts[0].split(separator: ":")
        guard hm.count == 2, var h = Int(hm[0]), let m = Int(hm[1]) else { return timeStr }
        var period = String(parts[1])
        h = (h % 12) + 1
        if h == 12 { period = (period == "AM") ? "PM" : "AM" }
        return String(format: "%02d:%02d %@", h, m, period)
    }
```

- [ ] **Step 3: Wire newEvent into view body**

Find the existing `.overlay { if let event = activeEvent { EventDetailCard ... } }` and add a sibling overlay for newEvent:

```swift
        .overlay {
            if let event = activeEvent {
                EventDetailCard(
                    event: event,
                    person: CalendarMockData.person(event.col),
                    dayLabel: "\(isViewingToday ? "Today" : CalendarMockData.shortDateLabel(selectedDate)), \(event.start) – \(event.end)",
                    onClose: { activeEvent = nil },
                    onSave: { updated in
                        // Phase 11: edits are session-only via runtime store
                        var todays = CalendarMockData.runtimeEventsByOffset[CalendarMockData.daysFromToday(to: selectedDate)] ?? []
                        if let i = todays.firstIndex(where: { $0.id == updated.id }) {
                            todays[i] = updated
                            CalendarMockData.runtimeEventsByOffset[CalendarMockData.daysFromToday(to: selectedDate)] = todays
                        }
                        activeEvent = nil
                    }
                )
                .transition(.opacity)
                .zIndex(100)
            }
            if let pair = newEvent {
                EventDetailCard(
                    event: pair.event,
                    person: pair.person,
                    dayLabel: CalendarMockData.shortDateLabel(selectedDate),
                    isNew: true,
                    onClose: { newEvent = nil },
                    onSave: { created in
                        let offset = CalendarMockData.daysFromToday(to: selectedDate)
                        var todays = CalendarMockData.runtimeEventsByOffset[offset] ?? []
                        todays.append(created)
                        CalendarMockData.runtimeEventsByOffset[offset] = todays
                        newEvent = nil
                    }
                )
                .transition(.opacity)
                .zIndex(101)
            }
        }
```

- [ ] **Step 4: Make `daysFromToday` public**

In `Models/CalendarMockData.swift`, find `private static func daysFromToday(...)` and remove `private`.

- [ ] **Step 5: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Calendar/CalendarView.swift" "Evlin iOS/Models/CalendarMockData.swift"
git commit -m "feat(calendar): FAB creates new event, edit mode persists to runtime store (Phase 11)"
```

---

# Phase 12 — P1 polish

Library taps, Insights buttons, NotificationBanner, and the Home Evlin observation card removal.

### Task 12.1: Remove stale Evlin observation prompt from Home

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Home/HomeView.swift:46-83`

- [ ] **Step 1: Remove the block**

In `HomeView.swift`, find the `// Evlin observation prompt` block (the `Button { selectedTab = .chat } label: { ... }` block, roughly lines 47-82). Delete the entire block.

The body's main VStack now contains only the Children section.

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Home/HomeView.swift"
git commit -m "feat(home): remove stale Evlin observation card per HTML spec (Phase 12)"
```

---

### Task 12.2: Library card tap → "Coming soon" sheet

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Components/ReelCard.swift`
- Modify: `Evlin iOS/Evlin iOS/Components/LessonCard.swift`
- Modify: `Evlin iOS/Evlin iOS/Views/Library/CategoryDetailView.swift`

- [ ] **Step 1: ReelCard accepts onTap**

```swift
struct ReelCard: View {
    let reel: ReelInfo
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            // ... existing content ...
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: LessonCard accepts onTap (same pattern)**

- [ ] **Step 3: LibraryView passes onTap with simple alert**

In `LibraryView.swift`:

```swift
struct LibraryView: View {
    @State private var scrolledReelId: UUID?
    @State private var libraryPath = NavigationPath()
    @State private var comingSoonTitle: String? = nil
    ...

    private var trendingReels: some View {
        ...
            ForEach(LibraryMockData.reels) { reel in
                ReelCard(reel: reel, onTap: { comingSoonTitle = reel.title }).id(reel.id)
            }
        ...
    }
    private var trendingLessons: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHead("Trending Lessons")
            VStack(spacing: 12) {
                ForEach(LibraryMockData.lessons) { lesson in
                    LessonCard(lesson: lesson, onTap: { comingSoonTitle = lesson.title })
                }
            }
        }
    }
```

Add the alert at the bottom of body:

```swift
        .alert("Coming soon", isPresented: Binding(
            get: { comingSoonTitle != nil },
            set: { if !$0 { comingSoonTitle = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(comingSoonTitle.map { "Player for \"\($0)\" is coming soon." } ?? "")
        }
```

- [ ] **Step 4: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Components/ReelCard.swift" \
        "Evlin iOS/Components/LessonCard.swift" \
        "Evlin iOS/Views/Library/LibraryView.swift"
git commit -m "feat(library): card tap shows Coming soon alert (Phase 12)"
```

---

### Task 12.3: Insights "Apply" + "Review strategy" buttons → toast

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Insights/InsightsView.swift`

- [ ] **Step 1: Add toast state + show on button taps**

```swift
struct InsightsView: View {
    @State private var selection: String = "liam"
    @State private var heroDismissed: Bool = false
    @State private var toastText: String? = nil
    ...
```

In `heroCard`, find the `EvlinButton(title: "Review strategy", ...) {}` and replace the empty action:

```swift
                    EvlinButton(title: "Review strategy", icon: "checkmark.seal", variant: .success, size: .sm) {
                        toastText = "Strategy details coming soon."
                    }
```

In `recommendations`, find the "Apply" button and replace its action similarly.

Add toast overlay at the bottom of body:

```swift
        .overlay(alignment: .bottom) {
            if let text = toastText {
                Text(text)
                    .font(.custom("Inter", size: 13).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.bottom, 90)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                            withAnimation { toastText = nil }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastText)
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Views/Insights/InsightsView.swift"
git commit -m "feat(insights): Review strategy + Apply buttons show toast (Phase 12)"
```

---

### Task 12.4: NotificationBanner top-of-screen

**Files:**
- Create: `Evlin iOS/Evlin iOS/Components/NotificationBanner.swift`
- Modify: `Evlin iOS/Evlin iOS/ContentView.swift`

- [ ] **Step 1: Create NotificationBanner**

```swift
import SwiftUI

/// Top-of-screen banner that auto-dismisses after 5s. See HTML 2106-2127.
struct NotificationBanner: View {
    let title: String
    let body: String
    let avatarURL: String?
    var onDismiss: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.evPrimary)
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("EVLIN")
                        .font(.custom("Inter", size: 12).weight(.heavy))
                        .tracking(0.6)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                    Spacer()
                    Text("now")
                        .font(.custom("Inter", size: 11))
                        .foregroundStyle(Color.evOutline)
                }
                Text(title)
                    .font(.custom("Manrope", size: 14).weight(.heavy))
                    .foregroundStyle(Color.evPrimary)
                Text(body)
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(Color.evOnSurface)
                    .lineSpacing(2)
                    .lineLimit(2)
            }

            if let urlStr = avatarURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color.evSurfaceContainerLow)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.evChildLiam, lineWidth: 2)
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 32, y: 8)
        .padding(.horizontal, 12)
        .onTapGesture { onDismiss() }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                onDismiss()
            }
        }
    }
}
```

- [ ] **Step 2: Wire banner state into ContentView**

In `ContentView.swift`, in `ParentRootView`:

```swift
    @State private var banner: (title: String, body: String, avatarURL: String?)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // ... existing tabs ...
            }
            EvlinTabBar(selection: $selectedTab)
        }
        .overlay(alignment: .top) {
            if let b = banner {
                NotificationBanner(
                    title: b.title,
                    body: b.body,
                    avatarURL: b.avatarURL,
                    onDismiss: { withAnimation { banner = nil } }
                )
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(80)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: banner?.title)
    }
```

(Note: `banner` is a tuple — to use it in `.value:`, may need to make it `Equatable` via a struct. For Phase 12 simplicity use a String key like banner?.title.)

The banner can be triggered for testing from SpikeView; production triggers come later from a real event bus.

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add "Evlin iOS/Components/NotificationBanner.swift" "Evlin iOS/ContentView.swift"
git commit -m "feat(app): NotificationBanner top-of-screen + auto-dismiss (Phase 12 complete)"
```

---

# Final validation

After all phases:

- [ ] **Step 1: Full build succeeds**
```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
xcodebuild -scheme "Evlin iOS" -destination "generic/platform=iOS" -configuration Debug clean build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Backend tests still green**
```bash
cd "/Users/fred/Desktop/Evlin/adaptive-engine"
poetry run pytest backend/tests/services/test_verb_dispatcher.py -q
```
Expected: `13 passed`

- [ ] **Step 3: Side-by-side visual check**

Run the Esen prototype:
```bash
cd "/Users/fred/Desktop/Evlin/frontend_for_app_evlin"
python3 -m http.server 3333
```
Open http://localhost:3333/Evlin_Parent_view/Evlin%20Parent%20Dashboard%20(1).html

Run iOS on a real device. Walk through:
- Home: notifications panel → tap Science Project → ProfileView opens with TaskDetailSheet showing 3-photo gallery
- Profile: ... menu, Lock/Unlock button, collapsible Devices/Rules, "+" FAB → all 4 form types
- Calendar: 4-column timeline by default, tap avatar to focus, "+" FAB creates new event
- Library: tap any card → "Coming soon"
- Insights: tap Review strategy / Apply → toast

Compare each screen to the HTML on the laptop. Differences should be ≤ minor padding/icon-style tweaks.

- [ ] **Step 4: Tag the milestone**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git tag parent-redesign-complete
git push origin parent-redesign-complete
```
