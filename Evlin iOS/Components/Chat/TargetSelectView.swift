//
//  TargetSelectView.swift
//  Evlin iOS
//
//  P5 calendar-in-chat: multi-checkbox keyed by STABLE id
//  (child_profile_id / child_device_id). Confirm returns ids, NEVER labels
//  (spec §5.1), so duplicate-name children / same-label devices stay
//  resolvable. PlanArch-native — NOT the CardPayload/CardID MissingInfoCard.
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
            Text(title).font(.headline)
            ForEach(groups) { g in
                if !g.childName.isEmpty {
                    Text(g.childName).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(g.options) { opt in
                    Button { toggle(opt.id) } label: {
                        HStack {
                            Image(systemName: selected.contains(opt.id) ? "checkmark.square.fill" : "square")
                                .foregroundColor(selected.contains(opt.id) ? .accentColor : .secondary)
                            Text(opt.label); Spacer()
                        }
                    }.buttonStyle(.plain).padding(.vertical, 4)
                }
            }
            HStack {
                Button("Cancel", action: onCancel).buttonStyle(.bordered)
                Spacer()
                Button("Confirm") {
                    onConfirm(allOptions.map(\.id).filter { selected.contains($0) })
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
        }
        .padding(16)
        .background(Color(.systemBackground)).cornerRadius(12)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}
