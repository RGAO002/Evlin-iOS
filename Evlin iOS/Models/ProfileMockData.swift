import SwiftUI

struct RuleItem: Identifiable, Hashable {
    let id: String
    var iconSystemName: String
    var title: String
    var detail: String
    var on: Bool
    var tone: RuleRow.Tone
}

struct ProfileEvent: Identifiable, Hashable {
    let id = UUID()
    let time: String
    let title: String
    let location: String?
}

struct DeviceItem: Identifiable, Hashable {
    let id = UUID()
    let iconSystemName: String
    let name: String
    let detail: String
    let locked: Bool

    /// Build a Profile "Enrolled Devices" row from a backend
    /// `EnrolledDeviceDTO` (`GET /family` / `GET /me/profile`). The display
    /// string is composed server-side (§1.7); we fall back to the model/OS
    /// fields when it's absent. `locked` is not carried by this DTO (it's a
    /// runtime lock concept), so it defaults to `false`.
    init(dto: EnrolledDeviceDTO) {
        let friendlyModel = dto.device_model.map(DeviceModelMap.friendlyName(for:))
        let display = Self.friendlyDisplay(dto: dto, friendlyModel: friendlyModel)
        self.iconSystemName = dto.mode == "parent" ? "iphone.gen3" : "ipad.and.iphone"
        self.name = dto.label ?? friendlyModel ?? dto.display ?? "Device"
        self.detail = display
        self.locked = false
    }

    /// Direct memberwise-style initializer for the mock fixtures below.
    init(iconSystemName: String, name: String, detail: String, locked: Bool) {
        self.iconSystemName = iconSystemName
        self.name = name
        self.detail = detail
        self.locked = locked
    }

    private static func friendlyDisplay(dto: EnrolledDeviceDTO, friendlyModel: String?) -> String {
        guard let model = friendlyModel else {
            return dto.display ?? [dto.device_model, dto.os_version].compactMap { $0 }.joined(separator: " · ")
        }
        let platform = (dto.platform ?? "").lowercased()
        if platform == "ios" {
            let major = dto.os_version?.split(separator: ".", maxSplits: 1).first.map(String.init)
            let os = ["iOS", major].compactMap { $0 }.joined(separator: " ")
            return [model, os.isEmpty ? nil : os].compactMap { $0 }.joined(separator: " · ")
        }
        if let raw = dto.device_model, let display = dto.display, raw != model {
            return display.replacingOccurrences(of: raw, with: model)
        }
        return dto.display ?? [model, dto.os_version].compactMap { $0 }.joined(separator: " · ")
    }
}

/// PREVIEW-ONLY fixtures. The runtime Profile surface no longer reads any of
/// these: tasks come from the BigKid backend when the child owns the paired
/// device (else an honest "No tasks yet" empty state), devices come from
/// `FamilyStore` (else "No devices enrolled yet"), and rules render a
/// "coming soon" state because there is no rules backend. `devices(for:)`
/// is still used as a fallback ONLY when the child id isn't present in
/// `FamilyStore` at all (i.e. #Preview hosts).
enum ProfileMockData {
    /// Mutable per-child task store. Seeded lazily from `defaultTasks(for:)`
    /// the first time a child is read. PREVIEW-ONLY — `TaskDetailSheet`'s
    /// #Preview blocks read `tasks(for:)`; the runtime task path is the
    /// BigKid backend.
    static var runtimeTasks: [String: [TaskItem]] = [:]

    static func rules(for childId: String, dailyLimitMinutes: Int = 120) -> [RuleItem] {
        [
            .init(id: "screen", iconSystemName: "timer",
                  title: "Daily Screen Time",
                  detail: "\(ProfileMockData.formatLimit(dailyLimitMinutes)) limit per day",
                  on: true, tone: .primary),
            .init(id: "downtime", iconSystemName: "moon",
                  title: "Downtime", detail: "8:00 PM – 7:00 AM",
                  on: true, tone: .tertiary),
            .init(id: "bed", iconSystemName: "moon.fill",
                  title: "Bedtime", detail: "8:00 PM",
                  on: true, tone: .tertiary),
        ]
    }

    /// Format minutes into a human-readable limit string.
    /// 15 → "15m", 90 → "1h 30m", 120 → "2h", 180 → "3h"
    static func formatLimit(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    /// Reads from `runtimeTasks`, seeding from `defaultTasks` on first
    /// access. Callers should treat the returned array as authoritative
    /// and re-fetch after any mutation via `setTasks(...)` or
    /// `updateTask(...)`.
    static func tasks(for childId: String) -> [TaskItem] {
        if let cached = runtimeTasks[childId] { return cached }
        let seeded = defaultTasks(for: childId)
        runtimeTasks[childId] = seeded
        return seeded
    }

    static func setTasks(_ tasks: [TaskItem], for childId: String) {
        runtimeTasks[childId] = tasks
    }

    /// Replace one task in `runtimeTasks` (matched by id). Returns the
    /// updated full list for the child.
    @discardableResult
    static func updateTask(_ task: TaskItem, for childId: String) -> [TaskItem] {
        var list = tasks(for: childId)
        if let i = list.firstIndex(where: { $0.id == task.id }) {
            list[i] = task
        } else {
            list.append(task)
        }
        runtimeTasks[childId] = list
        return list
    }

    @discardableResult
    static func deleteTask(_ taskId: Int, for childId: String) -> [TaskItem] {
        var list = tasks(for: childId)
        list.removeAll(where: { $0.id == taskId })
        runtimeTasks[childId] = list
        return list
    }

    private static func defaultTasks(for childId: String) -> [TaskItem] {
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

    static func events(for childId: String) -> [ProfileEvent] {
        switch childId {
        case "liam":
            return [
                .init(time: "8:00 AM", title: "Clean Table", location: "Kitchen"),
                .init(time: "1:30 PM", title: "Math Practice", location: "Study Room"),
                .init(time: "4:00 PM", title: "Soccer Practice", location: "City Park"),
            ]
        case "maya":
            return [
                .init(time: "10:00 AM", title: "Piano Practice", location: "Living Room"),
                .init(time: "3:30 PM", title: "Art Class", location: "Art Studio"),
            ]
        default:
            return [
                .init(time: "2:00 PM", title: "Reading Time", location: "Bedroom"),
                .init(time: "7:30 PM", title: "Story Time", location: "Bedroom"),
            ]
        }
    }

    static func devices(for childId: String) -> [DeviceItem] {
        [
            .init(iconSystemName: "iphone", name: "iPhone 13", detail: "Primary device", locked: false),
            .init(iconSystemName: "ipad", name: "iPad", detail: "Homework only", locked: true),
            .init(iconSystemName: "laptopcomputer", name: "MacBook Air", detail: "School hours 9-3", locked: false),
        ]
    }
}
