# iOS UI Revision Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute the 17 fixes in `docs/superpowers/specs/2026-04-21-ios-ui-revision-pass-design.md` as ordered, bite-sized tasks.

**Architecture:** Surgical edits to existing files; no new architectural layers. NavigationStack already exists on Home tab; extending its route enum covers Notifications. Library gains its own NavigationStack. Calendar is restructured (outer card + real dates + overlay modal). StrategyCard, LessonCard, TaskRow fully repainted. Settings content ported into HomeSettingsSheet with forced light color scheme.

**Tech Stack:** SwiftUI (iOS 17+), `NavigationStack`, `.navigationDestination(for:)`, `DateFormatter`, `Calendar`, `Timer.publish`, `.scrollTargetBehavior`, `.overlay`, `.preferredColorScheme`.

**Conventions**
- Project root = `/Users/fred/Desktop/Evlin/Evlin iOS`
- Build-verify command: `cd "/Users/fred/Desktop/Evlin/Evlin iOS" && xcodebuild -scheme "Evlin iOS" -destination 'generic/platform=iOS' build 2>&1 | tail -30`
- Expected after each task: no new errors introduced (existing errors from later-task dependencies are acceptable and noted)
- Every task ends with a commit
- Full file rewrites use Write; targeted edits use Edit with before/after blocks

---

## Task 1: Regenerate App Icon without white border

**Files:**
- Modify: `Evlin iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` (regenerate)

- [ ] **Step 1: Regenerate icon directly from 646×636 source → 1024×1024**

```bash
SRC="/Users/fred/Desktop/Evlin/appIcon.png"
DST="/Users/fred/Desktop/Evlin/Evlin iOS/Evlin iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
TMP="/tmp/evlin-appicon-v2.png"
JPG="/tmp/evlin-appicon-v2.jpg"

cp "$SRC" "$TMP"
# Scale directly (1.6% vertical stretch, imperceptible, no padding)
sips -z 1024 1024 "$TMP" >/dev/null 2>&1
# Flatten alpha via JPEG roundtrip
sips -s format jpeg -s formatOptions 100 "$TMP" --out "$JPG" >/dev/null 2>&1
sips -s format png "$JPG" --out "$DST" >/dev/null 2>&1
file "$DST"
```

Expected: `PNG image data, 1024 x 1024, 8-bit/color RGB, non-interlaced` (no alpha channel).

- [ ] **Step 2: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
git commit -m "fix(icon): regenerate without padding to remove white border"
```

---

## Task 2: Swap background colors — screens gray, tab bar white

**Files:**
- Modify: `Evlin iOS/Views/Home/HomeView.swift` (`.background(...)` on outer VStack)
- Modify: `Evlin iOS/Views/Profile/ProfileView.swift`
- Modify: `Evlin iOS/Views/Calendar/CalendarView.swift`
- Modify: `Evlin iOS/Views/Chat/ChatView.swift`
- Modify: `Evlin iOS/Views/Library/LibraryView.swift`
- Modify: `Evlin iOS/Views/Insights/InsightsView.swift`
- Modify: `Evlin iOS/Views/Library/CategoryDetailView.swift`
- Modify: `Evlin iOS/Views/Home/NotificationPanel.swift`

- [ ] **Step 1: Replace `.background(Color.evSurface)` → `.background(Color.evSurfaceContainerLow)` in each file above**

For each file, find the outer-most `.background(Color.evSurface)` modifier and change it to `.background(Color.evSurfaceContainerLow)`. Do NOT touch `Color.evSurface` references inside nested components or overlays — only the single top-level page background.

If a file has `Color(hex: 0xF0F4F8)` (CalendarView's custom gray), leave it — it's already gray.

CalendarView's `.background(Color(hex: 0xF0F4F8))` → change to `.background(Color.evSurfaceContainerLow)` for token consistency.

- [ ] **Step 2: Build-verify**

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Views/Home/HomeView.swift" \
        "Evlin iOS/Views/Profile/ProfileView.swift" \
        "Evlin iOS/Views/Calendar/CalendarView.swift" \
        "Evlin iOS/Views/Chat/ChatView.swift" \
        "Evlin iOS/Views/Library/LibraryView.swift" \
        "Evlin iOS/Views/Insights/InsightsView.swift" \
        "Evlin iOS/Views/Library/CategoryDetailView.swift" \
        "Evlin iOS/Views/Home/NotificationPanel.swift"
git commit -m "style: swap screen bg to evSurfaceContainerLow (gray); tab bar stays white"
```

---

## Task 3: Insights legend — fixedSize + horizontal scroll

**Files:**
- Modify: `Evlin iOS/Views/Insights/InsightsView.swift` (the `HStack(spacing: 18)` at the bottom of `dailyUsageCard`)

- [ ] **Step 1: Edit the legend HStack**

Find this block in InsightsView's `dailyUsageCard` (near the bottom, currently a plain `HStack(spacing: 18)` with `ForEach`):

```swift
HStack(spacing: 18) {
    ForEach(InsightsMockData.categories) { c in
        HStack(spacing: 6) {
            Circle().fill(c.color).frame(width: 8, height: 8)
            Text(c.label)
                .font(.custom("Inter", size: 11).weight(.semibold))
                .foregroundStyle(Color.evOnSurface)
            Text(c.time)
                .font(.custom("Inter", size: 11))
                .foregroundStyle(Color.evOnSurfaceVariant)
        }
    }
    Spacer()
}
```

Replace with:

```swift
ScrollView(.horizontal, showsIndicators: false) {
    HStack(spacing: 18) {
        ForEach(InsightsMockData.categories) { c in
            HStack(spacing: 6) {
                Circle().fill(c.color).frame(width: 8, height: 8)
                Text(c.label)
                    .font(.custom("Inter", size: 11).weight(.semibold))
                    .foregroundStyle(Color.evOnSurface)
                Text(c.time)
                    .font(.custom("Inter", size: 11))
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}
```

- [ ] **Step 2: Build-verify**

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Views/Insights/InsightsView.swift"
git commit -m "fix(insights): legend items horizontal scroll + fixedSize to prevent wrap"
```

---

## Task 4: ChatInputBar — bolt icon + rounded-square send

**Files:**
- Modify: `Evlin iOS/Components/ChatInputBar.swift` (full rewrite)

- [ ] **Step 1: Read current file to understand existing interface**

```bash
cat "/Users/fred/Desktop/Evlin/Evlin iOS/Evlin iOS/Components/ChatInputBar.swift"
```

- [ ] **Step 2: Overwrite with new layout**

Preserve the existing public signature (`@Binding var text: String`, `onSend: () -> Void`). Replace body with:

```swift
import SwiftUI

struct ChatInputBar: View {
    @Binding var text: String
    var onSend: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.evSecondary)

            TextField("Ask about the strategy...", text: $text, axis: .vertical)
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
                .lineLimit(1...4)
                .submitLabel(.send)
                .onSubmit(onSend)

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.evPrimary)
                    )
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1.0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
```

- [ ] **Step 3: Build-verify**

- [ ] **Step 4: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Components/ChatInputBar.swift"
git commit -m "refactor(chat-input): green hollow bolt + rounded-square send button"
```

---

## Task 5: RuleRow — add per-row edit glyph

**Files:**
- Modify: `Evlin iOS/Components/RuleRow.swift`

- [ ] **Step 1: Edit body's HStack to insert edit button before Toggle**

Find the `body` HStack. Current layout is `[iconTile, VStack(title+detail), Spacer, Toggle]`. Insert edit button between `Spacer()` and `Toggle`:

Replace this existing block:
```swift
Spacer()
Toggle("", isOn: $isOn)
    .labelsHidden()
    .tint(Color.evSecondary)
```
with:
```swift
Spacer()
Button {} label: {
    Image(systemName: "square.and.pencil")
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(Color.evOnSurfaceVariant)
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
}
.buttonStyle(.plain)
Toggle("", isOn: $isOn)
    .labelsHidden()
    .tint(Color.evSecondary)
```

- [ ] **Step 2: Build-verify**

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Components/RuleRow.swift"
git commit -m "feat(rule-row): add per-row edit glyph (no-op)"
```

---

## Task 6: ProfileCard — 4-line stacked layout

**Files:**
- Modify: `Evlin iOS/Components/ProfileCard.swift` (full rewrite)

- [ ] **Step 1: Overwrite ProfileCard.swift**

```swift
import SwiftUI

struct ProfileCard: View {
    let child: ChildProfile
    var action: () -> Void = {}

    @State private var ping: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                EvlinAvatarView(url: child.avatarURL, name: child.name, size: 56, status: child.status)

                VStack(alignment: .leading, spacing: 8) {
                    // Line 1: Name · age X
                    HStack(spacing: 6) {
                        Text(child.name)
                            .font(.custom("Manrope", size: 17).weight(.heavy))
                            .tracking(-0.2)
                            .foregroundStyle(Color.evPrimary)
                        Text("· age \(child.age)")
                            .font(.custom("Inter", size: 13))
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }

                    // Line 2: status dot + label · time left
                    HStack(spacing: 6) {
                        if child.status == .unlocked {
                            ZStack {
                                Circle()
                                    .fill(Color.evSecondary.opacity(0.6))
                                    .frame(width: 8, height: 8)
                                    .scaleEffect(ping ? 1.8 : 1.0)
                                    .opacity(ping ? 0 : 0.6)
                                Circle()
                                    .fill(Color.evSecondary)
                                    .frame(width: 8, height: 8)
                            }
                            Text("UNLOCKED · \(child.timeLeft) left")
                                .font(.custom("Inter", size: 10).weight(.heavy))
                                .tracking(1.4)
                                .foregroundStyle(Color.evSecondary)
                        } else {
                            Text("QUIET TIME")
                                .font(.custom("Inter", size: 10).weight(.heavy))
                                .tracking(1.4)
                                .foregroundStyle(Color.evOnSurfaceVariant)
                        }
                    }

                    // Line 3: progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.evSecondaryContainer).frame(height: 5)
                            Capsule().fill(Color.evSecondary)
                                .frame(width: max(6, geo.size.width * child.timePct), height: 5)
                        }
                    }
                    .frame(height: 5)

                    // Line 4: subtitle
                    Text(child.subtitle)
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.evOutline)
                    .padding(.top, 4)
            }
            .padding(18)
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
        .buttonStyle(.plain)
        .onAppear {
            if child.status == .unlocked {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    ping = true
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build-verify**

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Components/ProfileCard.swift"
git commit -m "refactor(profile-card): 4-line stacked layout (name·age / status / bar / subtitle)"
```

---

## Task 7: DeviceRow — status pill instead of plain lock

**Files:**
- Modify: `Evlin iOS/Components/DeviceRow.swift` (full rewrite)

- [ ] **Step 1: Overwrite DeviceRow.swift**

```swift
import SwiftUI

struct DeviceRow: View {
    let iconSystemName: String
    let name: String
    let detail: String
    var locked: Bool = false
    var isLast: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.evSurfaceContainerLow)
                Image(systemName: iconSystemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.custom("Manrope", size: 14).weight(.bold))
                    .foregroundStyle(Color.evPrimary)
                Text(detail)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            Spacer()
            EvlinPill(
                text: locked ? "Locked" : "Active",
                tone: locked ? .danger : .success,
                size: .xs
            )
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .overlay(
            Rectangle().fill(Color.evOutlineVariant.opacity(isLast ? 0 : 0.4))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}
```

- [ ] **Step 2: Build-verify**

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Components/DeviceRow.swift"
git commit -m "feat(device-row): ACTIVE/LOCKED status pill"
```

---

## Task 8: TaskRow rewrite — independent cards + state-variant icons

**Files:**
- Modify: `Evlin iOS/Components/TaskRow.swift` (full rewrite)

- [ ] **Step 1: Overwrite TaskRow.swift**

```swift
import SwiftUI

struct TaskItem: Identifiable, Hashable {
    let id: Int
    var title: String
    var state: State
    var iconSystemName: String?

    enum State: String, Hashable {
        case pending, done, review, overdue
        var label: String {
            switch self {
            case .pending: return "Pending"
            case .done: return "Done"
            case .review: return "Reviewing"
            case .overdue: return "Overdue"
            }
        }
    }
}

struct TaskRow: View {
    let task: TaskItem
    var onApprove: () -> Void = {}
    var onRedo: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            mainRow
            if task.state == .review {
                reviewActions
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

    // MARK: - Card background tint

    private var cardBackground: Color {
        switch task.state {
        case .review:  return Color(hex: 0xFFF9ED)  // pale amber
        case .overdue: return Color(hex: 0xFFF5F3)  // pale rose
        default:       return .evSurfaceContainerLowest
        }
    }

    // MARK: - Main row

    private var mainRow: some View {
        HStack(spacing: 14) {
            stateIcon
            titleText
            Spacer(minLength: 4)
            trailingLabel
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.evOutline)
        }
    }

    // MARK: - State icon (tile vs empty circle)

    @ViewBuilder
    private var stateIcon: some View {
        switch task.state {
        case .done:
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.evSecondary)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

        case .review:
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(hex: 0xEF6C00))     // amber
                Image(systemName: task.iconSystemName ?? "camera.fill")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

        case .pending:
            Circle()
                .stroke(Color.evOutline, lineWidth: 1.5)
                .frame(width: 28, height: 28)
                .padding(4)

        case .overdue:
            ZStack {
                Circle().stroke(Color.evError, lineWidth: 1.5)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Color.evError)
            }
            .frame(width: 28, height: 28)
            .padding(4)
        }
    }

    // MARK: - Title

    private var titleText: some View {
        Group {
            if task.state == .done {
                Text(task.title)
                    .strikethrough(true, color: Color.evOnSurfaceVariant)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            } else {
                Text(task.title)
                    .foregroundStyle(Color.evPrimary)
            }
        }
        .font(.custom("Manrope", size: 16).weight(.heavy))
    }

    // MARK: - Trailing label (pill or red text)

    @ViewBuilder
    private var trailingLabel: some View {
        switch task.state {
        case .done:
            EvlinPill(text: "Done", tone: .success, size: .xs)
        case .review:
            EvlinPill(text: "Reviewing", tone: .warn, size: .xs)
        case .pending:
            EvlinPill(text: "Pending", tone: .neutral, size: .xs)
        case .overdue:
            Text("OVERDUE")
                .font(.custom("Inter", size: 11).weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(Color.evError)
        }
    }

    // MARK: - Review action buttons

    private var reviewActions: some View {
        HStack(spacing: 10) {
            Button(action: onApprove) {
                Text("APPROVE")
                    .font(.custom("Manrope", size: 12).weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.evSecondary)
                    )
                    .shadow(color: Color.evSecondary.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain)

            Button(action: onRedo) {
                Text("REQUEST REDO")
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
}
```

- [ ] **Step 2: Build-verify**

Note: ProfileView.swift currently calls `TaskRow(task:isLast:onApprove:onRedo:)`. The new signature drops `isLast:` (no longer needed — each row is its own card). This will break ProfileView momentarily; Task 12 updates it.

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Components/TaskRow.swift"
git commit -m "refactor(task-row): independent cards, state-variant icons, review actions"
```

---

## Task 9: LessonCard + LessonItem rewrite (editorial + press shadow)

**Files:**
- Modify: `Evlin iOS/Components/LessonCard.swift` (full rewrite)
- Modify: `Evlin iOS/Models/LibraryMockData.swift` (replace `lessons` array)

- [ ] **Step 1: Overwrite LessonCard.swift**

```swift
import SwiftUI

struct LessonItem: Identifiable, Hashable {
    let id = UUID()
    let author: String
    let role: String
    let title: String
    let excerpt: String
    let hearts: String
    let comments: Int

    static func == (lhs: LessonItem, rhs: LessonItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var initials: String {
        author.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
    }
}

struct LessonCard: View {
    let lesson: LessonItem
    @State private var pressed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Author row
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.evPrimaryContainer)
                    Text(lesson.initials)
                        .font(.custom("Manrope", size: 11).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(lesson.author)
                        .font(.custom("Inter", size: 12).weight(.bold))
                        .foregroundStyle(Color.evOnSurface)
                    Text(lesson.role)
                        .font(.custom("Inter", size: 10))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                Spacer()
            }

            // Title
            Text(lesson.title)
                .font(.custom("Manrope", size: 17).weight(.heavy))
                .tracking(-0.17)
                .foregroundStyle(Color.evPrimary)
                .lineSpacing(-2)
                .fixedSize(horizontal: false, vertical: true)

            // Excerpt
            Text(lesson.excerpt)
                .font(.custom("Inter", size: 12))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            // Meta row
            HStack(spacing: 18) {
                HStack(spacing: 5) {
                    Image(systemName: "heart")
                        .font(.system(size: 13))
                    Text(lesson.hearts)
                        .font(.custom("Inter", size: 11).weight(.semibold))
                }
                .foregroundStyle(Color.evOnSurfaceVariant)

                HStack(spacing: 5) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 13))
                    Text("\(lesson.comments)")
                        .font(.custom("Inter", size: 11).weight(.semibold))
                }
                .foregroundStyle(Color.evOnSurfaceVariant)

                Spacer()

                HStack(spacing: 4) {
                    Text("READ LESSON")
                        .font(.custom("Manrope", size: 10).weight(.heavy))
                        .tracking(1.4)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(Color.evPrimary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(pressed ? 0.08 : 0.04),
            radius: pressed ? 40 : 30,
            x: 0,
            y: pressed ? 20 : 10
        )
        .scaleEffect(pressed ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.18), value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}
```

- [ ] **Step 2: Update `LibraryMockData.swift` — replace the `lessons` static**

Locate `static let lessons: [LessonItem] = [...]` in `Evlin iOS/Models/LibraryMockData.swift` and replace with:

```swift
static let lessons: [LessonItem] = [
    LessonItem(
        author: "Dr. Julian Vance",
        role: "Pediatric Neuropsychologist",
        title: "The \"Three-Second\" Pause Method",
        excerpt: "A neuro-scientific approach to de-escalating toddler tantrums before they peak.",
        hearts: "2.4k",
        comments: 184
    ),
    LessonItem(
        author: "Elena Rodriguez",
        role: "Digital Wellness Strategist",
        title: "Digital Sovereignty Protocols",
        excerpt: "Building a child's internal moral compass for digital spaces. Frameworks for the AI era.",
        hearts: "1.1k",
        comments: 56
    ),
]
```

- [ ] **Step 3: Build-verify**

- [ ] **Step 4: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Components/LessonCard.swift" "Evlin iOS/Models/LibraryMockData.swift"
git commit -m "refactor(lesson-card): editorial author-card layout + press shadow"
```

---

## Task 10: StrategyCard full rewrite

**Files:**
- Modify: `Evlin iOS/Components/StrategyCard.swift` (full rewrite)

- [ ] **Step 1: Overwrite StrategyCard.swift**

```swift
import SwiftUI

struct StrategyCardData: Hashable {
    let title: String
    let status: String          // "Locked"
    let category: String        // "Active Monitoring › Immediate Action"
    let videoLabel: String
    let videoDuration: String
    let tip: String
}

struct StrategyCard: View {
    let data: StrategyCardData
    var onWatchVideo: () -> Void = {}
    var onReviewStrategy: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            categoryLine
            videoTile
            proactiveTip
            actionButtons
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.5), lineWidth: 1)
        )
        .evShadow(.premium)
    }

    // Header: title + LOCKED pill
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(data.title)
                .font(.custom("Manrope", size: 22).weight(.heavy))
                .tracking(-0.3)
                .foregroundStyle(Color.evPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .heavy))
                Text(data.status.uppercased())
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(1.4)
            }
            .foregroundStyle(Color.evError)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.evErrorContainer))
        }
    }

    // Category breadcrumb
    private var categoryLine: some View {
        Text(data.category.uppercased())
            .font(.custom("Inter", size: 11).weight(.heavy))
            .tracking(1.6)
            .foregroundStyle(Color.evOnSurfaceVariant)
    }

    // Video tile
    private var videoTile: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.evPrimaryGradient)

            Circle()
                .fill(.white.opacity(0.18))
                .frame(width: 60, height: 60)
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                Text(data.videoLabel)
                    .font(.custom("Manrope", size: 16).weight(.heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text("\(data.videoDuration) duration")
                    .font(.custom("Inter", size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(16)
        }
        .frame(height: 160)
    }

    // Proactive Tip box
    private var proactiveTip: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.evSecondary)
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text("Proactive Tip")
                    .font(.custom("Manrope", size: 14).weight(.heavy))
                    .foregroundStyle(Color.evSecondary)
                Text(data.tip)
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(Color.evOnSurface)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.evSecondaryContainer)
        )
    }

    // Watch Video + Review Strategy buttons
    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button(action: onWatchVideo) {
                HStack(spacing: 6) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("WATCH VIDEO")
                        .font(.custom("Manrope", size: 12).weight(.heavy))
                        .tracking(0.9)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.evPrimary)
                )
            }
            .buttonStyle(.plain)

            Button(action: onReviewStrategy) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 14, weight: .bold))
                    Text("REVIEW STRATEGY")
                        .font(.custom("Manrope", size: 12).weight(.heavy))
                        .tracking(0.9)
                }
                .foregroundStyle(Color.evPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.evPrimary.opacity(0.3), lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
        }
    }
}
```

- [ ] **Step 2: Build-verify**

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Components/StrategyCard.swift"
git commit -m "refactor(strategy-card): full redesign per screenshot (video tile + tip + buttons)"
```

---

## Task 11: ChatView cleanup — remove GlassHeader + AgentReasoningCard render

**Files:**
- Modify: `Evlin iOS/Views/Chat/ChatView.swift`

- [ ] **Step 1: Remove the top GlassmorphicHeader block**

Find in `ChatView.body` the first child of the outer `VStack`:
```swift
GlassmorphicHeader(title: "Evlin") {
    HStack(spacing: 4) {
        HeaderIconButton(systemName: "checkmark.seal") {}
        HeaderIconButton(systemName: "ellipsis") {}
    }
}
```
Delete the entire block so the `ScrollViewReader` becomes the new first child.

- [ ] **Step 2: Remove the Strategic Context reasoning render**

Find inside `ForEach(viewModel.messages)`:
```swift
// Reasoning card
if let reasoning = message.reasoning, message.role == .agent {
    AgentReasoningCard(label: "Strategic Context", content: reasoning)
}
```
Delete these 4 lines (keeping the surrounding VStack structure intact).

- [ ] **Step 3: Build-verify**

- [ ] **Step 4: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Views/Chat/ChatView.swift"
git commit -m "refactor(chat): remove top GlassHeader + AgentReasoningCard render"
```

---

## Task 12: ProfileView — Enrolled Devices rename + TaskRow call sig + section polish

**Files:**
- Modify: `Evlin iOS/Views/Profile/ProfileView.swift`

- [ ] **Step 1: Update TaskRow call site (drop `isLast:` param, wrap in VStack with spacing)**

Find the Tasks section ForEach:
```swift
VStack(spacing: 0) {
    ForEach(Array(tasks.enumerated()), id: \.element.id) { idx, t in
        TaskRow(
            task: t,
            isLast: idx == tasks.count - 1,
            onApprove: { ... },
            onRedo: { ... }
        )
    }
}
.background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.evSurfaceContainerLowest))
.overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1))
```

Replace with (each row is its own card now; no background wrapping the group):

```swift
VStack(spacing: 10) {
    ForEach(tasks) { t in
        TaskRow(
            task: t,
            onApprove: {
                if let i = tasks.firstIndex(where: { $0.id == t.id }) {
                    tasks[i].state = .done
                }
            },
            onRedo: {
                if let i = tasks.firstIndex(where: { $0.id == t.id }) {
                    tasks[i].state = .pending
                }
            }
        )
    }
}
```

Also update the Tasks section header title from "Tasks" to "Current Tasks".

- [ ] **Step 2: Rename Device Permissions → Enrolled Devices**

Find:
```swift
SectionHead(title: "Device Permissions")
```
Replace with:
```swift
SectionHead("Enrolled Devices")
```

(The unlabeled init form matches patterns elsewhere.)

- [ ] **Step 3: Build-verify**

- [ ] **Step 4: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Views/Profile/ProfileView.swift"
git commit -m "feat(profile): Current Tasks per-card TaskRow; Enrolled Devices section"
```

---

## Task 13: CalendarMockData — offset-keyed events + date helpers

**Files:**
- Modify: `Evlin iOS/Models/CalendarMockData.swift`

- [ ] **Step 1: Overwrite CalendarMockData.swift**

```swift
import SwiftUI

struct CalendarPerson: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color
    let bg: Color
}

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
}

struct AllDayItem: Identifiable, Hashable {
    let id = UUID()
    let col: String
    let title: String
}

enum CalendarMockData {
    static let HOUR_H: CGFloat = 56
    static let START_H: Int = 0
    static let END_H: Int = 24
    static let TIME_W: CGFloat = 48

    static let people: [CalendarPerson] = [
        .init(id: "family", name: "Family events",
              color: Color(hex: 0x7C6FF7), bg: Color(hex: 0xEDE9FE)),
        .init(id: "liam", name: "Liam",
              color: .evChildLiam, bg: Color(hex: 0xDBEAFE)),
        .init(id: "maya", name: "Maya",
              color: Color(hex: 0x3DAA5C), bg: Color(hex: 0xDCFCE7)),
        .init(id: "emma", name: "Emma",
              color: Color(hex: 0xF97316), bg: Color(hex: 0xFFEDD5)),
    ]

    // Events keyed by days-offset from today (0 = today)
    static let eventsByOffset: [Int: [CalendarEvent]] = [
        0: [
            CalendarEvent(col: "liam",   title: "Clean Table",     emoji: "🧹",
                          start: "08:00 AM", end: "08:30 AM", category: "Chore",
                          location: "Kitchen", note: "Wipe down the kitchen table and chairs after lunch."),
            CalendarEvent(col: "maya",   title: "Piano Practice",  emoji: "🎹",
                          start: "10:00 AM", end: "11:30 AM", category: "Lesson",
                          location: "Living Room", note: "Work on the new piece from last week. Focus on the right-hand part."),
            CalendarEvent(col: "family", title: "Family Lunch",    emoji: "🍽️",
                          start: "12:00 PM", end: "01:00 PM", category: "Family",
                          location: "Dining Room", note: "Everyone together. No devices at the table."),
            CalendarEvent(col: "liam",   title: "Math Practice",   emoji: "📐",
                          start: "01:30 PM", end: "02:30 PM", category: "Study",
                          location: "Study Room", note: "Chapter 7 exercises, pages 112-118."),
            CalendarEvent(col: "emma",   title: "Reading Time",    emoji: "📚",
                          start: "02:00 PM", end: "03:00 PM", category: "Study",
                          location: "Bedroom", note: "Choose one book from the reading list."),
            CalendarEvent(col: "maya",   title: "Art Class",       emoji: "🎨",
                          start: "03:30 PM", end: "05:00 PM", category: "Lesson",
                          location: "Art Studio", note: "Bring the watercolor set."),
            CalendarEvent(col: "liam",   title: "Soccer Practice", emoji: "⚽",
                          start: "04:00 PM", end: "05:30 PM", category: "Sport",
                          location: "City Park", note: "Don't forget shin guards."),
            CalendarEvent(col: "family", title: "Family Dinner",   emoji: "🍴",
                          start: "06:00 PM", end: "07:00 PM", category: "Family",
                          location: "Dining Room", note: "Everyone helps set the table."),
            CalendarEvent(col: "emma",   title: "Story Time",      emoji: "🌙",
                          start: "07:30 PM", end: "08:30 PM", category: "Routine",
                          location: "Bedroom", note: "Two stories max, then lights out."),
        ],
        7: [
            CalendarEvent(col: "liam", title: "Science Lab", emoji: "🔬",
                          start: "10:00 AM", end: "11:30 AM", category: "Study",
                          location: "Study Room", note: "Volcanos experiment."),
            CalendarEvent(col: "maya", title: "Reading", emoji: "📖",
                          start: "09:00 AM", end: "10:00 AM", category: "Study",
                          location: "Living Room", note: "Finish chapter 4."),
            CalendarEvent(col: "family", title: "Library Trip", emoji: "🏛️",
                          start: "01:00 PM", end: "03:00 PM", category: "Family",
                          location: "Central Library", note: "Each kid picks two new books."),
            CalendarEvent(col: "emma", title: "Nap Time", emoji: "😴",
                          start: "02:00 PM", end: "03:30 PM", category: "Routine",
                          location: "Bedroom", note: "Keep the house quiet."),
            CalendarEvent(col: "liam", title: "Soccer Practice", emoji: "⚽",
                          start: "04:00 PM", end: "05:30 PM", category: "Sport",
                          location: "City Park", note: "Arrive 10 min early today."),
            CalendarEvent(col: "family", title: "Family Dinner", emoji: "🍴",
                          start: "06:00 PM", end: "07:00 PM", category: "Family",
                          location: "Dining Room", note: "Everyone helps set the table."),
        ],
    ]

    static let allDayByOffset: [Int: [AllDayItem]] = [
        0: [AllDayItem(col: "liam", title: "Wellness Day 🧘")],
    ]

    // MARK: - Date helpers

    static func daysFromToday(to date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: start, to: target).day ?? 0
    }

    static func events(for date: Date) -> [CalendarEvent] {
        eventsByOffset[daysFromToday(to: date)] ?? []
    }

    static func allDay(for date: Date) -> [AllDayItem] {
        allDayByOffset[daysFromToday(to: date)] ?? []
    }

    // "Thu, Sep 25"
    static func shortDateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }

    // "September"
    static func monthName(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "LLLL"
        return f.string(from: date)
    }

    // Parse "08:00 AM" into total minutes
    static func parseTimeToMinutes(_ s: String) -> Int {
        let parts = s.split(separator: " ")
        guard parts.count == 2 else { return 0 }
        let hm = parts[0].split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2 else { return 0 }
        var h = hm[0]
        let m = hm[1]
        let period = String(parts[1])
        if period == "PM", h != 12 { h += 12 }
        if period == "AM", h == 12 { h = 0 }
        return h * 60 + m
    }

    static func yFor(_ timeStr: String) -> CGFloat {
        let mins = parseTimeToMinutes(timeStr)
        return CGFloat(mins) / 60 * HOUR_H
    }

    static func heightFor(start: String, end: String) -> CGFloat {
        let h = yFor(end) - yFor(start)
        return max(h, 36)
    }

    // y for current time (Date)
    static func yForNow() -> CGFloat {
        let cal = Calendar.current
        let h = cal.component(.hour, from: Date())
        let m = cal.component(.minute, from: Date())
        return (CGFloat(h) + CGFloat(m) / 60) * HOUR_H
    }

    static func person(_ id: String) -> CalendarPerson {
        people.first(where: { $0.id == id }) ?? people[0]
    }
}
```

- [ ] **Step 2: Build-verify**

Expected: errors from `CalendarView.swift` / `MonthPickerSheet.swift` / `EventDetailSheet.swift` referencing removed `events[Int]` dictionary and `dayNames` — fixed in Tasks 14, 15, 16.

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Models/CalendarMockData.swift"
git commit -m "refactor(calendar-data): real-date offsets + Date helpers (replace day-int keys)"
```

---

## Task 14: EventDetailCard — centered overlay replaces bottom sheet

**Files:**
- Delete file body of: `Evlin iOS/Views/Calendar/EventDetailSheet.swift` (keep file per preservation rule) — it becomes a deprecated stub
- Create: `Evlin iOS/Views/Calendar/EventDetailCard.swift` (new centered overlay)

- [ ] **Step 1: Create EventDetailCard.swift**

```swift
import SwiftUI

// Centered modal card for Calendar event tap (replaces EventDetailSheet).
// Uses .overlay from CalendarView with its own dim backdrop; not a .sheet.

struct EventDetailCard: View {
    let event: CalendarEvent
    let person: CalendarPerson
    let dayLabel: String     // "Today, 10:00 AM – 11:30 AM" etc — caller composes
    var onClose: () -> Void = {}
    var onEdit: () -> Void = {}

    @State private var reminderOn: Bool = true

    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.4)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            // Card
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().padding(.vertical, 4)
                personRow
                Divider().padding(.vertical, 4)
                categoryRow
                Divider().padding(.vertical, 4)
                noteRow
                Divider().padding(.vertical, 4)
                locationRow
                Divider().padding(.vertical, 4)
                reminderRow
                Spacer(minLength: 8)
                footer
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white)
            )
            .shadow(color: .black.opacity(0.28), radius: 30, x: 0, y: 10)
            .padding(.horizontal, 16)
            .frame(maxWidth: 440)
        }
        .preferredColorScheme(.light)
    }

    // MARK: - Rows

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.evPrimary)
                    .frame(width: 44, height: 44)
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.custom("Manrope", size: 22).weight(.heavy))
                    .tracking(-0.2)
                    .foregroundStyle(Color.evPrimary)
                Text(dayLabel)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.evSurfaceContainerHigh))
            }
            .buttonStyle(.plain)
        }
    }

    private var personRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
            EvlinAvatarView(url: avatarURLFor(person.id), name: person.name, size: 26, ring: true, ringColor: person.color)
            Text(person.name)
                .font(.custom("Manrope", size: 14).weight(.heavy))
                .foregroundStyle(Color.evPrimary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var categoryRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "tag")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
            EvlinPill(text: event.category, tone: .neutral, size: .sm)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var noteRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "list.bullet")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
                .padding(.top, 1)
            Text(event.note)
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private var locationRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
            Text(event.location)
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var reminderRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "alarm")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
            Text("30 minutes before")
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
            Spacer()
            Toggle("", isOn: $reminderOn)
                .labelsHidden()
                .tint(Color.evSecondary)
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            Button("Close") { onClose() }
                .font(.custom("Manrope", size: 15).weight(.heavy))
                .foregroundStyle(Color.evPrimary)

            Spacer()

            Button(action: onEdit) {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .bold))
                    Text("Edit")
                        .font(.custom("Manrope", size: 14).weight(.heavy))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.evPrimary)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    private func avatarURLFor(_ id: String) -> String? {
        switch id {
        case "liam": return ChildProfile.liam.avatarURL
        case "maya": return ChildProfile.maya.avatarURL
        case "emma": return ChildProfile.emma.avatarURL
        default:     return nil
        }
    }
}
```

- [ ] **Step 2: Deprecate EventDetailSheet.swift (keep file as empty stub to avoid deletion)**

Overwrite `Evlin iOS/Views/Calendar/EventDetailSheet.swift` with:

```swift
import SwiftUI

// MARK: - DEPRECATED / RETAINED FOR REFERENCE
// Replaced by EventDetailCard (centered overlay). Not wired into CalendarView.
// Kept on disk per spec preservation rule. Do not delete. Do not wire back in.

struct EventDetailSheet_DEPRECATED: View {
    var body: some View { EmptyView() }
}
```

- [ ] **Step 3: Build-verify**

Expected: build fails because CalendarView still uses `EventDetailSheet(...)`. Fixed in Task 16.

- [ ] **Step 4: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Views/Calendar/EventDetailCard.swift" "Evlin iOS/Views/Calendar/EventDetailSheet.swift"
git commit -m "feat(calendar): EventDetailCard centered overlay; deprecate EventDetailSheet"
```

---

## Task 15: MonthPickerSheet — real-calendar grid

**Files:**
- Modify: `Evlin iOS/Views/Calendar/MonthPickerSheet.swift` (full rewrite)

- [ ] **Step 1: Overwrite MonthPickerSheet.swift**

```swift
import SwiftUI

struct MonthPickerSheet: View {
    @Binding var selectedDate: Date
    var onClose: () -> Void

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(CalendarMockData.monthName(selectedDate))
                .font(.custom("Manrope", size: 22).weight(.heavy))
                .foregroundStyle(Color.evPrimary)

            HStack(spacing: 6) {
                ForEach(weekdaySymbols, id: \.self) { d in
                    Text(d)
                        .font(.custom("Inter", size: 11).weight(.bold))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(cells.indices, id: \.self) { idx in
                    if let d = cells[idx] {
                        dayCell(d)
                    } else {
                        Color.clear.frame(height: 40)
                    }
                }
            }

            Spacer()
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.light)
    }

    // Short weekday initials (S M T W T F S)
    private var weekdaySymbols: [String] {
        let f = DateFormatter()
        f.locale = .current
        return f.veryShortStandaloneWeekdaySymbols
    }

    // Array of dates for the current month, padded with nils before day-1
    private var cells: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: selectedDate),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate))
        else { return [] }
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)  // 1 = Sunday
        let leadingBlanks = firstWeekday - 1
        var result: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for day in range {
            if let d = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) {
                result.append(d)
            }
        }
        return result
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)
        let day = calendar.component(.day, from: date)
        Button {
            selectedDate = date
            onClose()
        } label: {
            ZStack {
                Circle().fill(isSelected ? Color.evPrimary : Color.clear)
                if isToday && !isSelected {
                    Circle().stroke(Color.evPrimary, lineWidth: 1.5)
                }
                Text("\(day)")
                    .font(.custom("Manrope", size: 15).weight(.heavy))
                    .foregroundStyle(isSelected ? Color.white : Color.evOnSurface)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Build-verify**

Expected: `CalendarView.swift` still references old `selectedDay: Int` binding for MonthPickerSheet. Fixed in Task 16.

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Views/Calendar/MonthPickerSheet.swift"
git commit -m "refactor(month-picker): real calendar grid (Date binding, auto-align weekdays)"
```

---

## Task 16: CalendarView rewrite — outer card + today's events + FAB + red line + real dates + no GlassHeader

**Files:**
- Modify: `Evlin iOS/Views/Calendar/CalendarView.swift` (full rewrite)

- [ ] **Step 1: Overwrite CalendarView.swift**

```swift
import SwiftUI

struct CalendarView: View {
    @State private var selectedDate: Date = Date()
    @State private var showMonthPicker = false
    @State private var focusPerson: String? = nil
    @State private var activeEvent: CalendarEvent? = nil
    @State private var now: Date = Date()

    private let calendar = Calendar.current
    private let nowTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let totalHeight: CGFloat = CGFloat(CalendarMockData.END_H) * CalendarMockData.HOUR_H

    private var events: [CalendarEvent] { CalendarMockData.events(for: selectedDate) }
    private var visibleEvents: [CalendarEvent] {
        guard let focusPerson else { return events }
        return events.filter { $0.col == focusPerson }
    }
    private var allDayItems: [AllDayItem] { CalendarMockData.allDay(for: selectedDate) }

    private var isViewingToday: Bool {
        calendar.isDateInToday(selectedDate)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            scrollContainer

            floatingAddButton
                .padding(.trailing, 20)
                .padding(.bottom, 24)
        }
        .background(Color.evSurfaceContainerLow)
        .sheet(isPresented: $showMonthPicker) {
            MonthPickerSheet(selectedDate: $selectedDate, onClose: { showMonthPicker = false })
        }
        .overlay {
            if let event = activeEvent {
                EventDetailCard(
                    event: event,
                    person: CalendarMockData.person(event.col),
                    dayLabel: "\(isViewingToday ? "Today" : CalendarMockData.shortDateLabel(selectedDate)), \(event.start) – \(event.end)",
                    onClose: { activeEvent = nil },
                    onEdit: { activeEvent = nil }
                )
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: activeEvent)
        .onReceive(nowTimer) { t in now = t }
    }

    // MARK: - Card wrap

    private var scrollContainer: some View {
        ScrollViewReader { proxy in
            ScrollView {
                cardContent
                    .id("timeline")
            }
            .onAppear { scrollToFirstEvent(proxy) }
            .onChange(of: selectedDate) { _, _ in scrollToFirstEvent(proxy) }
            .onChange(of: focusPerson) { _, _ in scrollToFirstEvent(proxy) }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTopBar
            avatarRow
            Rectangle().fill(Color.evOutlineVariant.opacity(0.4)).frame(height: 1)
            timelineBody
        }
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .evShadow(.ambient)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .padding(.bottom, 80)   // leave room for FAB
    }

    // MARK: - Card top bar (title + 3 buttons)

    private var cardTopBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today's Events")
                    .font(.custom("Manrope", size: 17).weight(.heavy))
                    .foregroundStyle(Color.evPrimary)
                Text(CalendarMockData.shortDateLabel(selectedDate))
                    .font(.custom("Inter", size: 11).weight(.bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }

            Spacer()

            HStack(spacing: 2) {
                topBarButton(systemName: "chevron.left") {
                    if let d = calendar.date(byAdding: .day, value: -1, to: selectedDate) {
                        selectedDate = d
                    }
                }
                topBarButton(systemName: "calendar") { showMonthPicker = true }
                topBarButton(systemName: "chevron.right") {
                    if let d = calendar.date(byAdding: .day, value: 1, to: selectedDate) {
                        selectedDate = d
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func topBarButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Avatar row (Family events / Liam / Maya / Emma)

    private var avatarRow: some View {
        HStack(spacing: 0) {
            // Left gutter matching TIME_W
            Color.clear.frame(width: CalendarMockData.TIME_W)

            ForEach(CalendarMockData.people) { p in
                avatarButton(for: p)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func avatarButton(for p: CalendarPerson) -> some View {
        let focused = focusPerson == p.id
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                focusPerson = (focusPerson == p.id) ? nil : p.id
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if p.id == "family" {
                        Circle().fill(p.color)
                            .frame(width: focused ? 44 : 36, height: focused ? 44 : 36)
                        Image(systemName: "house.fill")
                            .font(.system(size: focused ? 18 : 14, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        EvlinAvatarView(
                            url: urlFor(p.id),
                            name: p.name,
                            size: focused ? 44 : 36,
                            ring: true,
                            ringColor: p.color
                        )
                    }
                }
                .frame(width: 46, height: 46)

                Text(p.id == "family" ? "Family" : p.name)
                    .font(.custom("Inter", size: 10).weight(focused ? .heavy : .semibold))
                    .foregroundStyle(focused ? p.color : Color.evOnSurface)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private func urlFor(_ personId: String) -> String? {
        switch personId {
        case "liam": return ChildProfile.liam.avatarURL
        case "maya": return ChildProfile.maya.avatarURL
        case "emma": return ChildProfile.emma.avatarURL
        default: return nil
        }
    }

    // MARK: - Timeline body

    private var timelineBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !allDayItems.isEmpty {
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

            HStack(alignment: .top, spacing: 0) {
                timeGutter
                ZStack(alignment: .topLeading) {
                    ForEach(CalendarMockData.START_H...CalendarMockData.END_H, id: \.self) { h in
                        Rectangle()
                            .fill(Color.evOutlineVariant.opacity(0.4))
                            .frame(height: 1)
                            .offset(y: CGFloat(h) * CalendarMockData.HOUR_H)
                    }

                    ForEach(visibleEvents) { ev in
                        eventPill(ev)
                            .offset(y: CalendarMockData.yFor(ev.start))
                    }

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

    private var timeGutter: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(CalendarMockData.START_H...CalendarMockData.END_H, id: \.self) { h in
                Text(hourLabel(h))
                    .font(.custom("Inter", size: 10).weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(Color.evOutline)
                    .frame(height: CalendarMockData.HOUR_H, alignment: .topTrailing)
                    .padding(.trailing, 8)
                    .offset(y: -4)
            }
        }
        .frame(width: CalendarMockData.TIME_W)
    }

    private func hourLabel(_ h: Int) -> String {
        switch h {
        case 0, 24: return ""
        case 12: return "12 PM"
        case let h where h < 12: return "\(h) AM"
        default: return "\(h - 12) PM"
        }
    }

    private func eventPill(_ ev: CalendarEvent) -> some View {
        let p = CalendarMockData.person(ev.col)
        let h = CalendarMockData.heightFor(start: ev.start, end: ev.end)
        return Button { activeEvent = ev } label: {
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(p.color).frame(width: 4).cornerRadius(2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ev.emoji).font(.system(size: 14))
                        Text(ev.title)
                            .font(.custom("Manrope", size: 13).weight(.heavy))
                            .foregroundStyle(Color.evPrimary)
                            .lineLimit(1)
                    }
                    Text(ev.start)
                        .font(.custom("Inter", size: 10).weight(.bold))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: h, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.bg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(p.color.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Current time red line

    private var currentTimeIndicator: some View {
        let _ = now   // read to tie re-render to timer publisher
        let y = CalendarMockData.yForNow()
        return ZStack(alignment: .leading) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .offset(x: -5)
            Rectangle()
                .fill(Color.red)
                .frame(height: 1.5)
                .padding(.leading, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: y - 5)
    }

    // MARK: - FAB

    private var floatingAddButton: some View {
        Button {} label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.evPrimary))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func scrollToFirstEvent(_ proxy: ScrollViewProxy) {
        guard let first = visibleEvents.map({ CalendarMockData.yFor($0.start) }).min() else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo("timeline", anchor: UnitPoint(x: 0, y: max(0, first - 80) / totalHeight))
        }
    }
}
```

- [ ] **Step 2: Build-verify**

Expected: `** BUILD SUCCEEDED **` once Calendar data+sheets+card are all in sync (Tasks 13–16).

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Views/Calendar/CalendarView.swift"
git commit -m "feat(calendar): outer card + today's events avatars + FAB + red line + real dates"
```

---

## Task 17: CategoryDetailView rebuild

**Files:**
- Modify: `Evlin iOS/Views/Library/CategoryDetailView.swift` (full rewrite)

- [ ] **Step 1: Overwrite CategoryDetailView.swift**

```swift
import SwiftUI

struct CategoryDetailView: View {
    let category: CategoryTileInfo
    var onBack: () -> Void = {}

    private var detail: (heroTitle: String, heroAuthor: String, items: [LibraryMockData.DetailItem]) {
        LibraryMockData.detail(for: category.id)
    }
    private let featuredDuration: String = "12:30"

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: category.label, kicker: category.count, onBack: onBack) {
                HeaderIconButton(systemName: "bookmark") {}
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    featuredSection
                    allContentSection
                }
                .padding(16)
                .padding(.bottom, 40)
            }
        }
        .background(Color.evSurfaceContainerLow)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Featured

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FEATURED")
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .padding(.leading, 2)

            ZStack(alignment: .bottomLeading) {
                // Gradient thumb
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(category.gradient)
                        .frame(height: 180)

                    // Decorative blur circles
                    Circle().fill(Color.white.opacity(0.04))
                        .frame(width: 130, height: 130)
                        .offset(x: 100, y: -60)
                    Circle().fill(Color.white.opacity(0.03))
                        .frame(width: 160, height: 160)
                        .offset(x: -100, y: 70)

                    // Central play
                    Circle()
                        .fill(.white.opacity(0.16))
                        .frame(width: 60, height: 60)
                        .overlay(
                            Circle().stroke(.white.opacity(0.22), lineWidth: 2)
                        )
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                        )
                }

                // Duration pill bottom-right
                Text(featuredDuration)
                    .font(.custom("Inter", size: 11).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.6))
                    )
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                // Bottom overlay band (separate, rendered after)
            }
            .overlay(
                // Info overlay band sitting at the bottom
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.heroTitle)
                        .font(.custom("Manrope", size: 16).weight(.heavy))
                        .foregroundStyle(.white)
                        .lineSpacing(-1)
                        .lineLimit(2)
                    Text(detail.heroAuthor)
                        .font(.custom("Inter", size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.25)),
                alignment: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .evShadow(.premium)
        }
    }

    // MARK: - All content grid

    private var allContentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ALL CONTENT")
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .padding(.leading, 2)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(detail.items) { item in
                    if item.kind == .video {
                        gridVideoCard(item)
                    } else {
                        gridArticleCard(item)
                    }
                }
            }
        }
    }

    private func gridVideoCard(_ item: LibraryMockData.DetailItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(category.gradient)
                Circle().fill(.white.opacity(0.18))
                    .frame(width: 42, height: 42)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }
            .frame(height: 110)

            Text(item.title)
                .font(.custom("Manrope", size: 13).weight(.heavy))
                .foregroundStyle(Color.evPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(item.meta.uppercased())
                .font(.custom("Inter", size: 9).weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(Color.evOnSurfaceVariant)
        }
    }

    private func gridArticleCard(_ item: LibraryMockData.DetailItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.evSurfaceContainerLow)
                Image(systemName: "doc.text")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
            }
            .frame(height: 110)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.evOutlineVariant, lineWidth: 1)
            )

            Text(item.title)
                .font(.custom("Manrope", size: 13).weight(.heavy))
                .foregroundStyle(Color.evPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(item.meta.uppercased())
                .font(.custom("Inter", size: 9).weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(Color.evOnSurfaceVariant)
        }
    }
}
```

- [ ] **Step 2: Build-verify**

Expected: `LibraryView` still uses `.fullScreenCover(item: $selectedCategory)`. Task 18 switches it to push.

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Views/Library/CategoryDetailView.swift"
git commit -m "refactor(category-detail): featured hero + all-content grid per Esen design"
```

---

## Task 18: LibraryView — NavigationStack + navigationDestination push

**Files:**
- Modify: `Evlin iOS/Views/Library/LibraryView.swift` (full rewrite)

- [ ] **Step 1: Overwrite LibraryView.swift**

```swift
import SwiftUI

struct LibraryView: View {
    @State private var scrolledReelId: UUID?
    @State private var libraryPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $libraryPath) {
            VStack(spacing: 0) {
                GlassmorphicHeader(title: "Library") {
                    HStack(spacing: 4) {
                        HeaderIconButton(systemName: "magnifyingglass") {}
                        HeaderIconButton(systemName: "bookmark") {}
                    }
                }

                ScrollView {
                    VStack(spacing: 24) {
                        trendingReels
                        trendingLessons
                        topicCategories
                    }
                    .padding(20)
                    .padding(.bottom, 40)
                }
            }
            .background(Color.evSurfaceContainerLow)
            .navigationDestination(for: CategoryTileInfo.self) { cat in
                CategoryDetailView(category: cat, onBack: {
                    if !libraryPath.isEmpty { libraryPath.removeLast() }
                })
            }
        }
    }

    private var trendingReels: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(title: "Trending Reels") {
                Text("60-SECOND INSIGHTS")
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 15) {
                    ForEach(LibraryMockData.reels) { reel in
                        ReelCard(reel: reel).id(reel.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrolledReelId)
            .scrollClipDisabled()
            .padding(.horizontal, -20)
            .padding(.leading, 20)
            .padding(.trailing, 20)
            .onChange(of: scrolledReelId) { _, _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
            }
        }
    }

    private var trendingLessons: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHead("Trending Lessons")
            VStack(spacing: 12) {
                ForEach(LibraryMockData.lessons) { lesson in
                    LessonCard(lesson: lesson)
                }
            }
        }
    }

    private var topicCategories: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead("Topic Categories")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(LibraryMockData.categories) { cat in
                    CategoryTile(info: cat) {
                        libraryPath.append(cat)
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build-verify**

Expected: `** BUILD SUCCEEDED **` (assuming Tasks 9, 17 completed).

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Views/Library/LibraryView.swift"
git commit -m "refactor(library): NavigationStack + push for CategoryDetailView"
```

---

## Task 19: HomeRoute enum + Notifications push

**Files:**
- Modify: `Evlin iOS/ContentView.swift`
- Modify: `Evlin iOS/Views/Home/HomeView.swift`

- [ ] **Step 1: Add HomeRoute enum and update ContentView's Home tab NavigationStack**

Edit `Evlin iOS/ContentView.swift`. Add this enum before the `ContentView` struct:

```swift
enum HomeRoute: Hashable {
    case profile(ChildProfile)
    case notifications
}
```

Inside `ParentRootView`, replace the Home tab block with:

```swift
case .home:
    NavigationStack(path: $profilePath) {
        HomeView(
            selectedTab: $selectedTab,
            onOpenProfile: { child in profilePath.append(HomeRoute.profile(child)) },
            onOpenNotifications: { profilePath.append(HomeRoute.notifications) }
        )
        .navigationDestination(for: HomeRoute.self) { route in
            switch route {
            case .profile(let child):
                ProfileView(
                    child: child,
                    onBack: { if !profilePath.isEmpty { profilePath.removeLast() } },
                    onOpenCalendar: { selectedTab = .calendar }
                )
            case .notifications:
                NotificationPanel(onClose: {
                    if !profilePath.isEmpty { profilePath.removeLast() }
                })
            }
        }
    }
```

- [ ] **Step 2: Update HomeView signature + remove fullScreenCover**

Edit `Evlin iOS/Views/Home/HomeView.swift`:

Replace the struct declaration + state + bell action:

```swift
struct HomeView: View {
    @AppStorage("parentName") private var parentName: String = "Morgan"
    @State private var showSettings = false
    @Binding var selectedTab: EvlinTab
    var onOpenProfile: (ChildProfile) -> Void
    var onOpenNotifications: () -> Void
    // ... rest unchanged: greeting, unreadCount, body
```

In `GlassmorphicHeader`'s trailing closure, change bell to call `onOpenNotifications()` instead of `showNotifications = true`:

```swift
HeaderIconButton(systemName: "bell", badge: unreadCount > 0) {
    onOpenNotifications()
}
```

Remove `@State private var showNotifications = false` and delete the `.fullScreenCover(isPresented: $showNotifications)` block.

Keep everything else (settings fullScreenCover, ScrollView content) the same.

- [ ] **Step 3: Build-verify**

Expected: errors in `NotificationPanel` because its old header used its own back button (sheet context), now it needs to work as a pushed view. Task 20 fixes this.

- [ ] **Step 4: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/ContentView.swift" "Evlin iOS/Views/Home/HomeView.swift"
git commit -m "refactor(home): route Notifications via NavigationStack push"
```

---

## Task 20: NotificationPanel — adapt header for NavigationStack context

**Files:**
- Modify: `Evlin iOS/Views/Home/NotificationPanel.swift` (replace custom top header with GlassmorphicHeader)

- [ ] **Step 1: Overwrite NotificationPanel.swift**

```swift
import SwiftUI

struct NotificationPanel: View {
    var onClose: () -> Void
    @State private var notifs: [HomeNotification] = HomeMockData.notifications

    private var unread: Int { notifs.filter(\.unread).count }

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(
                title: "Notifications",
                kicker: unread > 0 ? "\(unread) unread" : nil,
                onBack: onClose
            ) {
                if unread > 0 {
                    Button {
                        withAnimation { notifs = notifs.map { var n = $0; n.unread = false; return n } }
                    } label: {
                        Text("Mark all read")
                            .font(.custom("Inter", size: 12).weight(.bold))
                            .foregroundStyle(Color.evPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if notifs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 40))
                    Text("All caught up")
                        .font(.custom("Inter", size: 14))
                }
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(notifs) { n in
                            row(for: n)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation { notifs.removeAll { $0.id == n.id } }
                                    } label: {
                                        Label("Dismiss", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color.evSurfaceContainerLow)
        .navigationBarBackButtonHidden(true)
    }

    @ViewBuilder
    private func row(for n: HomeNotification) -> some View {
        let color = HomeMockData.childColor(n.childId)
        Button {
            withAnimation {
                if let idx = notifs.firstIndex(where: { $0.id == n.id }) {
                    notifs[idx].unread = false
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if n.unread {
                    Circle().fill(color).frame(width: 6, height: 6).offset(y: 8)
                } else {
                    Color.clear.frame(width: 6, height: 6).offset(y: 8)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(color.opacity(0.12))
                    if let url = HomeMockData.avatarURL(n.childId), let u = URL(string: url) {
                        AsyncImage(url: u) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else {
                                Image(systemName: n.iconSystemName)
                                    .font(.system(size: 16))
                                    .foregroundStyle(color)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    } else {
                        Image(systemName: n.iconSystemName)
                            .font(.system(size: 18))
                            .foregroundStyle(color)
                    }
                }
                .frame(width: 42, height: 42)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(color.opacity(0.25), lineWidth: 1.5)
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(n.title)
                            .font(.custom("Manrope", size: 13).weight(.heavy))
                            .foregroundStyle(Color.evPrimary)
                        Spacer()
                        Text(n.time)
                            .font(.custom("Inter", size: 10))
                            .foregroundStyle(Color.evOutline)
                    }
                    Text(n.body)
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineSpacing(1)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .background(n.unread ? color.opacity(0.03) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            Rectangle().fill(Color.evOutlineVariant.opacity(0.4)).frame(height: 1),
            alignment: .bottom
        )
    }
}
```

- [ ] **Step 2: Build-verify**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Views/Home/NotificationPanel.swift"
git commit -m "refactor(notifications): use GlassmorphicHeader for NavigationStack context"
```

---

## Task 21: HomeSettingsSheet — port old SettingsView content + force light mode

**Files:**
- Modify: `Evlin iOS/Views/Home/HomeSettingsSheet.swift` (full rewrite, port all legacy sections)
- Modify: `Evlin iOS/Views/SettingsView.swift` (add deprecation comment header)

- [ ] **Step 1: Overwrite HomeSettingsSheet.swift**

```swift
import SwiftUI
import FamilyControls

struct HomeSettingsSheet: View {
    @EnvironmentObject var apiClient: APIClient
    @EnvironmentObject var screenTimeManager: ScreenTimeManager
    var onClose: () -> Void

    @AppStorage("parentName") private var parentName: String = "Morgan"
    @AppStorage("childName") private var childName: String = "Liam"
    @AppStorage("targetChildId") private var targetChildId: String = ""
    @AppStorage("appMode") private var appMode: String = ""

    @State private var children: [ChildProfile] = ChildProfile.all
    @State private var editing: ChildProfile? = nil
    @State private var adding: Bool = false

    @State private var serverURL: String = ""
    @State private var isPickerPresented = false
    @State private var pairingInput: String = ""
    @State private var pairingMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Children (new top section)
                Section("Children") {
                    ForEach(children) { c in
                        Button { editing = c } label: {
                            HStack(spacing: 12) {
                                EvlinAvatarView(url: c.avatarURL, name: c.name, size: 36)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name)
                                        .font(.custom("Manrope", size: 14).weight(.bold))
                                        .foregroundStyle(Color.evOnSurface)
                                    Text("Age \(c.age)")
                                        .font(.custom("Inter", size: 12))
                                        .foregroundStyle(Color.evOnSurfaceVariant)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.evOutline)
                            }
                        }
                    }
                    .onDelete { children.remove(atOffsets: $0) }

                    Button { adding = true } label: {
                        Label("Add child", systemImage: "plus.circle.fill")
                            .foregroundStyle(Color.evPrimary)
                    }

                    LabeledContent("Parent name") {
                        TextField("", text: $parentName)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.plain)
                    }
                }

                // MARK: Connection
                Section("Connection") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Server URL")
                            .font(.custom("Inter", size: 11).weight(.bold))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.evOutline)
                        TextField("http://192.168.1.x:8000/api/v1", text: $serverURL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Child Name")
                            .font(.custom("Inter", size: 11).weight(.bold))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.evOutline)
                        TextField("Liam", text: $childName)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Child Device ID")
                            .font(.custom("Inter", size: 11).weight(.bold))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.evOutline)
                        TextField("Paste child's device ID here", text: $targetChildId)
                            .font(.system(size: 12, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pair with Code")
                            .font(.custom("Inter", size: 11).weight(.bold))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.evOutline)
                        HStack(spacing: 10) {
                            TextField("6-digit code", text: $pairingInput)
                                .font(.system(size: 18, weight: .bold, design: .monospaced))
                                .keyboardType(.numberPad)
                            Button("Pair") { pairWithCode() }
                                .disabled(pairingInput.count != 6)
                                .buttonStyle(.borderedProminent)
                                .tint(Color.evPrimary)
                        }
                        if let msg = pairingMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(msg.contains("Paired") ? Color.evSecondary : Color.evError)
                        }
                    }
                }

                // MARK: Screen Time
                Section("Screen Time") {
                    HStack {
                        Text("Authorization")
                        Spacer()
                        if screenTimeManager.isAuthorized {
                            Label("Authorized", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color.evSecondary)
                        } else {
                            Button("Authorize") {
                                Task { await screenTimeManager.requestAuthorization() }
                            }
                        }
                    }

                    let appCount = screenTimeManager.selectedApps.applicationTokens.count
                    let catCount = screenTimeManager.selectedApps.categoryTokens.count

                    Button {
                        isPickerPresented = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Managed Apps")
                                    .foregroundStyle(Color.evOnSurface)
                                if appCount > 0 || catCount > 0 {
                                    Text("\(appCount) apps, \(catCount) categories")
                                        .font(.caption)
                                        .foregroundStyle(Color.evOutline)
                                } else {
                                    Text("No apps selected")
                                        .font(.caption)
                                        .foregroundStyle(Color.evOutline)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Color.evOutline)
                        }
                    }

                    if appCount > 0 || catCount > 0 {
                        Button {
                            screenTimeManager.shieldApps()
                        } label: {
                            Label("Lock Selected Apps", systemImage: "lock.fill")
                                .foregroundStyle(Color.evError)
                        }
                    }

                    Button {
                        screenTimeManager.clearAllShields()
                    } label: {
                        Label("Unlock All Apps", systemImage: "lock.open.fill")
                            .foregroundStyle(Color.evSecondary)
                    }
                }

                // MARK: Device Status
                Section("Device Status") {
                    HStack {
                        Text("Lock State")
                        Spacer()
                        Text(screenTimeManager.isUnlocked ? "Unlocked" : "Locked")
                            .foregroundStyle(screenTimeManager.isUnlocked ? Color.evSecondary : Color.evError)
                    }
                }

                // MARK: Chat
                Section("Chat") {
                    Button(role: .destructive) {
                        UserDefaults.standard.removeObject(forKey: "evlin_chat_history")
                        NotificationCenter.default.post(name: .evlinClearChat, object: nil)
                    } label: {
                        Label("Clear Chat History", systemImage: "trash")
                    }
                }

                // MARK: Mode
                Section("Mode") {
                    HStack {
                        Text("Current Mode")
                        Spacer()
                        Text(appMode == "parent" ? "Parent" : "Child")
                            .foregroundStyle(Color.evPrimary)
                    }

                    Button(role: .destructive) {
                        appMode = "setup"
                        onClose()
                    } label: {
                        Label("Switch Device Mode", systemImage: "arrow.triangle.2.circlepath")
                    }

                    if appMode == "parent" {
                        Button {
                            appMode = "child"
                            onClose()
                        } label: {
                            Label("Switch to Child Mode", systemImage: "figure.child")
                        }
                    } else if appMode == "child" {
                        Button {
                            appMode = "parent"
                            onClose()
                        } label: {
                            Label("Switch to Parent Mode", systemImage: "person.fill")
                        }
                    }

                    Button(role: .destructive) {
                        screenTimeManager.clearAllShields()
                        UserDefaults.standard.removeObject(forKey: "onboardingComplete")
                        UserDefaults.standard.removeObject(forKey: "appMode")
                        UserDefaults.standard.removeObject(forKey: "childId")
                        UserDefaults.standard.removeObject(forKey: "childName")
                        UserDefaults.standard.removeObject(forKey: "targetChildId")
                        UserDefaults.standard.removeObject(forKey: "evlin_chat_history")
                        UserDefaults.standard.removeObject(forKey: "serverURL")
                        NotificationCenter.default.post(name: .evlinClearChat, object: nil)
                        appMode = ""
                        onClose()
                    } label: {
                        Label("Reset Everything (Re-run Onboarding)", systemImage: "arrow.counterclockwise")
                    }
                }

                // MARK: About
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if !serverURL.isEmpty {
                            apiClient.saveServerURL(serverURL)
                        }
                        onClose()
                    }
                }
            }
            .familyActivityPicker(
                isPresented: $isPickerPresented,
                selection: $screenTimeManager.selectedApps
            )
            .onChange(of: screenTimeManager.selectedApps) { _, _ in
                screenTimeManager.saveSelection()
            }
            .onAppear {
                serverURL = apiClient.baseURL
            }
            .sheet(item: $editing) { child in
                ChildEditSheet(child: child) { updated in
                    if let idx = children.firstIndex(where: { $0.id == updated.id }) {
                        children[idx] = updated
                    }
                    editing = nil
                }
            }
            .sheet(isPresented: $adding) {
                ChildEditSheet(child: nil) { newChild in
                    children.append(newChild)
                    adding = false
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private func pairWithCode() {
        Task {
            guard let url = URL(string: "\(apiClient.baseURL)/parent/pair") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(["code": pairingInput])

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pairedId = result["child_id"] as? String,
                      let pairedName = result["child_name"] as? String
                else {
                    await MainActor.run { pairingMessage = "Invalid code" }
                    return
                }
                await MainActor.run {
                    targetChildId = pairedId
                    childName = pairedName
                    pairingMessage = "Paired with \(pairedName)!"
                    pairingInput = ""
                }
            } catch {
                await MainActor.run { pairingMessage = "Connection error" }
            }
        }
    }
}

private struct ChildEditSheet: View {
    let child: ChildProfile?
    var onSave: (ChildProfile) -> Void

    @State private var name: String = ""
    @State private var age: Int = 8

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                    Stepper("Age: \(age)", value: $age, in: 1...18)
                }
            }
            .navigationTitle(child == nil ? "Add child" : "Edit \(child?.name ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let c = child {
                    name = c.name
                    age = c.age
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let id = child?.id ?? name.lowercased()
                        let updated = ChildProfile(
                            id: id, name: name, age: age,
                            avatarURL: child?.avatarURL,
                            accentColor: child?.accentColor ?? .evPrimary,
                            status: child?.status ?? .unlocked,
                            timeLeft: child?.timeLeft ?? "1h",
                            timePct: child?.timePct ?? 0.5,
                            subtitle: child?.subtitle ?? "New family member"
                        )
                        onSave(updated)
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
        .preferredColorScheme(.light)
    }
}
```

- [ ] **Step 2: Deprecate SettingsView.swift**

Prepend to `Evlin iOS/Views/SettingsView.swift` (immediately after `import FamilyControls`):

```swift
// MARK: - DEPRECATED / RETAINED FOR REFERENCE
// Replaced by HomeSettingsSheet (Views/Home/HomeSettingsSheet.swift),
// which consolidates all legacy sections (Connection / Screen Time /
// Device Status / Chat / Mode / About) with a new Children section on top
// and is forced into light color scheme.
// Kept on disk per spec preservation rule. Do not delete. Do not wire back in.
```

- [ ] **Step 3: Build-verify**

Expected: `** BUILD SUCCEEDED **`. The `HomeSettingsSheet` now requires `APIClient` and `ScreenTimeManager` env objects — these are already injected in `Evlin_iOSApp.swift`, so that should just work.

- [ ] **Step 4: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Views/Home/HomeSettingsSheet.swift" "Evlin iOS/Views/SettingsView.swift"
git commit -m "feat(settings): port legacy SettingsView sections into HomeSettingsSheet; force light mode"
```

---

## Task 22: Smoke test + final marker commit

**Files:** none (verification only)

- [ ] **Step 1: Full clean build**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
rm -rf ~/Library/Developer/Xcode/DerivedData
xcodebuild -scheme "Evlin iOS" -destination 'generic/platform=iOS' build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Final marker commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git commit --allow-empty -m "chore: Evlin revision pass complete — ready for review"
```

---

## Self-Review

**Spec coverage check (17 items in spec §2):**

| Spec Item | Task |
|---|---|
| 2.1 App icon border | Task 1 |
| 2.2 Tab bar/page bg swap | Task 2 |
| 2.3 Notifications push | Tasks 19, 20 |
| 2.4 Settings consolidation | Task 21 |
| 2.5a RuleRow edit glyph | Task 5 |
| 2.5b TaskRow redesign | Task 8 |
| 2.5c Enrolled Devices + pill | Tasks 7, 12 |
| 2.5d ProfileCard 4-line | Task 6 |
| 2.6 Remove GlassHeader from Calendar/Chat | Tasks 11, 16 |
| 2.7 Calendar today's events + outer card | Task 16 |
| 2.8 Event card centered overlay | Task 14 |
| 2.9 Calendar FAB | Task 16 |
| 2.10 Current time red line | Task 16 |
| 2.11 Remove Strategic Context | Task 11 |
| 2.12 StrategyCard redesign | Task 10 |
| 2.13 ChatInputBar | Task 4 |
| 2.14 LessonCard editorial | Task 9 |
| 2.15 Category push + detail rebuild | Tasks 17, 18 |
| 2.16 Insights legend fix | Task 3 |
| 2.17 Calendar real dates | Tasks 13, 15, 16 |

All 17 items covered.

**Placeholder scan:** No "TBD" / "TODO" / "implement later" strings. Every code step has complete code. Where edits target existing code, before/after blocks are shown.

**Type consistency:**
- `TaskRow` API: no `isLast` param (Task 8 removed it, Task 12 updates call sites) ✓
- `EventDetailCard` is new name; old `EventDetailSheet` is deprecated stub ✓
- `MonthPickerSheet` binds to `selectedDate: Date` (not `selectedDay: Int`) across Tasks 15, 16 ✓
- `CalendarMockData.events(for:)` is the new API used in CalendarView (Task 16) ✓
- `HomeRoute` enum used consistently in ContentView (Task 19) + HomeView opens via `onOpenNotifications` closure ✓
- `LessonItem` shape changes (Task 9) — both LessonCard and LibraryMockData.lessons updated together in same task ✓
- `HomeSettingsSheet` requires `@EnvironmentObject APIClient / ScreenTimeManager` — these are already injected at the app root (Evlin_iOSApp.swift) ✓

**Scope:** 22 tasks cover all 17 spec items with natural dependencies. No cross-file coupling that would break ordering.

---

**Plan complete.**
