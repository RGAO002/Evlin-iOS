//
//  TargetSelectView.swift
//  Evlin iOS
//
//  P5 calendar-in-chat: multi-checkbox keyed by STABLE id
//  (child_profile_id / child_device_id). Confirm returns ids, NEVER labels
//  (spec §5.1), so duplicate-name children / same-label devices stay
//  resolvable. PlanArch-native — NOT the CardPayload/CardID MissingInfoCard.
//
//  This card is GLOBAL: it serves calendar's "who's this for?"
//  (target.child_select) AND lock/block's "which device?" (target.device_select).
//  So it wears the neutral navy `evPrimary` accent, NOT the calendar red.
//

import SwiftUI

struct TargetSelectionModel {
    let options: [TargetOption]
    private(set) var selected: Set<String> = []
    var selectedIds: [String] { options.map(\.id).filter { selected.contains($0) } }
    mutating func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

/// Multi-checkbox keyed by STABLE id (child_profile_id / child_device_id), with
/// optional child-name group headers (device select). Confirm returns ids, never
/// labels (§5.1). PlanArch-native — NOT the CardPayload/CardID MissingInfoCard.
struct TargetSelectView: View {
    let title: String
    let groups: [TargetGroup]          // flat selects pass one group with name ""
    let onConfirm: ([String]) -> Void
    let onCancel: () -> Void

    @State private var selected: Set<String> = []
    private var allOptions: [TargetOption] { groups.flatMap(\.options) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.2")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
                    .frame(width: 34, height: 34)
                    .background(Color.evPrimaryContainer,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title).font(.headline).foregroundStyle(Color.evOnSurface)
                Spacer(minLength: 0)
            }
            VStack(spacing: 8) {
                ForEach(groups) { g in
                    if !g.childName.isEmpty {
                        Text(g.childName).font(.caption).foregroundStyle(Color.evOnSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                    ForEach(g.options) { opt in
                        Button { toggle(opt.id) } label: { optionRow(opt) }
                            .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 10) {
                neutralButton("Cancel", action: onCancel)
                primaryButton("Confirm", enabled: !selected.isEmpty) {
                    onConfirm(allOptions.map(\.id).filter { selected.contains($0) })
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLowest,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.evOutlineVariant.opacity(0.6), lineWidth: 1))
    }

    private func optionRow(_ opt: TargetOption) -> some View {
        let on = selected.contains(opt.id)
        return HStack(spacing: 11) {
            Text(opt.label).font(.subheadline.weight(.medium)).foregroundStyle(Color.evOnSurface)
            Spacer(minLength: 0)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(on ? Color.evPrimary : Color.clear)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(on ? Color.evPrimary : Color.evOutline, lineWidth: 1.5)
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(Color.evSurfaceContainerLow,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func primaryButton(_ title: String, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .foregroundStyle(.white)
                .background(Color.evPrimary.opacity(enabled ? 1 : 0.35),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func neutralButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .foregroundStyle(Color.evOnSurface)
                .background(Color.evSurfaceContainer,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}
