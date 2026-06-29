import SwiftUI

/// Pure `"hh:mm a"` ⇄ `Date` time-of-day bridge for the event editor.
///
/// The model stores wall-clock times as `"hh:mm a"` strings (e.g. `"08:00 AM"`,
/// `"4:51 PM"`) and the save path (`CalendarTimeWire.utcISO`) parses exactly
/// that format. The native wheel `DatePicker` needs a `Date`, so this helper
/// bridges between the two WITHOUT changing what gets stored — only the
/// hour/minute components matter (the day is irrelevant; the save path
/// re-combines the parsed h:m with the event's real day).
enum EventTimeBridge {
    /// Shared formatter, configured exactly like the save-path parser
    /// (`en_US_POSIX`, `"hh:mm a"`) so anything we format here round-trips
    /// cleanly through `CalendarTimeWire.utcISO`.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "hh:mm a"
        return f
    }()

    /// `"hh:mm a"` → a `Date` whose hour/minute carry the time-of-day. Falls
    /// back to `Date()` when the string can't be parsed so the picker always
    /// has a valid value to bind to.
    static func parse(_ s: String) -> Date {
        formatter.date(from: s.trimmingCharacters(in: .whitespaces)) ?? Date()
    }

    /// `Date` → `"hh:mm a"` (e.g. `"04:51 PM"`) — the exact format the model
    /// stores and the save path parses.
    static func format(_ d: Date) -> String {
        formatter.string(from: d)
    }

    /// Whole-minute delta between two `"hh:mm a"` strings (end − start),
    /// using only hour/minute. Used to highlight the matching duration preset.
    static func minutes(from start: String, to end: String) -> Int {
        let cal = Calendar.current
        let s = cal.dateComponents([.hour, .minute], from: parse(start))
        let e = cal.dateComponents([.hour, .minute], from: parse(end))
        let sm = (s.hour ?? 0) * 60 + (s.minute ?? 0)
        let em = (e.hour ?? 0) * 60 + (e.minute ?? 0)
        return em - sm
    }

    /// `start + minutes`, formatted back to `"hh:mm a"`. Keeps only
    /// hour/minute (same-day events; a day wrap is harmless because the save
    /// path only reads h:m). Falls back to the start string on failure.
    static func adding(_ minutes: Int, to start: String) -> String {
        let base = parse(start)
        guard let bumped = Calendar.current.date(byAdding: .minute, value: minutes, to: base) else {
            return start
        }
        return format(bumped)
    }
}

/// Composite time editor: two tappable Starts/Ends cells, a native wheel
/// `DatePicker` that stays COLLAPSED until a cell is tapped (Apple-Calendar
/// inline-reveal), and a connected duration segmented control. Reads/writes
/// `"hh:mm a"` strings only — the model type and save path are untouched.
struct EventTimePicker: View {
    @Binding var start: String
    @Binding var end: String

    private enum Field { case start, end }
    /// `nil` = collapsed (no wheel). A non-nil value reveals the wheel bound to
    /// that field. Tapping the already-open cell again collapses it.
    @State private var active: Field?

    /// Graceful inline unfold — same calm, high-damping spring the App Controls
    /// accordion uses (no "fly down from the top"; an opacity + height reveal).
    private static let revealAnimation: Animation = .spring(response: 0.34, dampingFraction: 0.9)

    /// Duration presets, in minutes, with their display labels.
    private static let durations: [(minutes: Int, label: String)] = [
        (15, "15m"), (30, "30m"), (45, "45m"), (60, "1h"), (90, "1.5h"), (120, "2h"),
    ]

    /// The wheel binds here: read the active field's string as a `Date`;
    /// writing formats back into the active field's `"hh:mm a"` string. When
    /// nothing is active the get falls back to `start` (the wheel isn't shown
    /// then, so the value is never displayed).
    private var activeDate: Binding<Date> {
        Binding(
            get: { EventTimeBridge.parse(active == .end ? end : start) },
            set: { newDate in
                let s = EventTimeBridge.format(newDate)
                if active == .end { end = s } else { start = s }
            }
        )
    }

    /// Currently-selected duration preset (matches the live start→end delta),
    /// or nil for a custom span.
    private var selectedDuration: Int? {
        let delta = EventTimeBridge.minutes(from: start, to: end)
        return Self.durations.map(\.minutes).first { $0 == delta }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Two tappable cells side by side.
            HStack(spacing: 8) {
                timeCell(title: "Starts", value: start, field: .start)
                timeCell(title: "Ends", value: end, field: .end)
            }

            // Native wheel — only present once a cell is tapped. Reduced height
            // (a full wheel is ~216pt and felt too big/abrupt) and clipped so it
            // reads as a compact inline drawer.
            if active != nil {
                DatePicker("", selection: activeDate, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .frame(height: 168)
                    .clipped()
                    .tint(Color.evPrimary)
                    .transition(.opacity)
            }

            // Duration row: label + connected segmented control.
            HStack(spacing: 10) {
                Text("Duration")
                    .font(.custom("Inter", size: 13).weight(.semibold))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                durationSegments
            }
        }
        .animation(Self.revealAnimation, value: active)
    }

    /// Toggle a cell: open its wheel, or collapse if it's already the open one.
    private func toggle(_ field: Field) {
        withAnimation(Self.revealAnimation) {
            active = (active == field) ? nil : field
        }
    }

    /// One Starts/Ends cell. The open one is tinted with the accent and its
    /// chevron points up; tapping reveals/collapses the wheel below.
    private func timeCell(title: String, value: String, field: Field) -> some View {
        let isActive = active == field
        return Button {
            toggle(field)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.uppercased())
                        .font(.custom("Inter", size: 10).weight(.heavy))
                        .tracking(1.0)
                        .foregroundStyle(isActive ? Color.evPrimary : Color.evOnSurfaceVariant)
                    Text(value)
                        .font(.custom("Manrope", size: 17).weight(.heavy))
                        .foregroundStyle(isActive ? Color.evPrimary : Color.evOnSurface)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(isActive ? Color.evPrimary : Color.evOnSurfaceVariant)
                    .rotationEffect(.degrees(isActive ? 180 : 0))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? Color.evPrimary.opacity(0.08) : Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isActive ? Color.evPrimary : Color.evOutlineVariant,
                                  lineWidth: isActive ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Connected (flush) segmented control: one rounded bordered container,
    /// segments separated by hairlines, active segment filled with accent.
    /// Tapping a preset sets `end = start + N` and makes Ends active.
    private var durationSegments: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.durations.enumerated()), id: \.element.minutes) { index, item in
                let isSel = selectedDuration == item.minutes
                Button {
                    // Quick-set the span WITHOUT forcing the wheel open (it stays
                    // collapsed by default; if it's already open on Ends it updates
                    // live). Tapping the time cells is the only way to reveal it.
                    end = EventTimeBridge.adding(item.minutes, to: start)
                } label: {
                    Text(item.label)
                        .font(.custom("Inter", size: 11).weight(.heavy))
                        .foregroundStyle(isSel ? .white : Color.evOnSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(isSel ? Color.evPrimary : Color.clear)
                }
                .buttonStyle(.plain)

                // Hairline divider between segments (not after the last).
                if index < Self.durations.count - 1 {
                    Rectangle()
                        .fill(Color.evOutlineVariant)
                        .frame(width: 1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.evOutlineVariant, lineWidth: 1)
        )
    }
}
