//
//  TagsEditor.swift
//  Replicould — Devices feature
//
//  The device inspector's editable "Tags" row: the device's current tags as
//  removable chips plus an inline field to add one, sending the whole new set
//  through `.tagsEdited` on every change.
//

import ComposableArchitecture
import GameModels
import SwiftUI
import UI

/// The editable "Tags" row in the details card: the device's current tags as
/// removable chips plus an inline field to add one. Every edit sends the *whole*
/// new set through `.tagsEdited` (the PATCH replaces all tags at once); the chips
/// update once the authoritative device row reconciles back, so they reflect
/// confirmed state rather than an optimistic guess.
struct TagsEditor: View {
    let device: Device
    let store: StoreOf<DevicesFeature>

    @State private var newTag: String = ""
    @FocusState private var focused: Bool

    private var trimmedTag: String { newTag.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Enabled once the field holds a non-empty tag the device doesn't already carry.
    private var canAdd: Bool { !trimmedTag.isEmpty && !device.tags.contains(trimmedTag) }

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Text("Tags")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
                .frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.s) {
                if !device.tags.isEmpty {
                    FlowLayout(spacing: Space.xs) {
                        ForEach(device.tags, id: \.self) { tag in
                            chip(tag)
                        }
                    }
                }
                addField
            }
            Spacer(minLength: 0)
        }
    }

    /// One removable tag chip — the tag text with a trailing ✕ that drops it.
    private func chip(_ tag: String) -> some View {
        HStack(spacing: Space.xs) {
            Text(tag)
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextSecondary)
                .textSelection(.enabled)
            Button {
                remove(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: IconSize.s, weight: .bold))
                    .foregroundStyle(.rcTextTertiary)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove tag \(tag)")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 7)
        .background(.rcSurfaceRaisedStrong, in: Capsule())
        .overlay(Capsule().strokeBorder(.rcSeparator, lineWidth: Hairline.thin))
    }

    /// The inline add-a-tag field: a compact input with a + affordance, committing
    /// on Return or the button.
    private var addField: some View {
        HStack(spacing: Space.xs) {
            TextField("Add tag…", text: $newTag)
                .textFieldStyle(.plain)
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextPrimary)
                .focused($focused)
                .onSubmit(commit)
            Button {
                commit()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: IconSize.s, weight: .bold))
                    .foregroundStyle(canAdd ? Color.rcAccent : .rcTextTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityLabel("Add tag")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, Space.s)
        .frame(maxWidth: 200)
        .background(.rcSurfaceRaisedStrong, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(focused ? Color.rcAccentBorder : .rcSeparator, lineWidth: focused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    private func commit() {
        let tag = trimmedTag
        newTag = ""
        guard !tag.isEmpty, !device.tags.contains(tag) else { return }
        store.send(.tagsEdited(deviceCode: device.deviceCode, tags: device.tags + [tag]))
    }

    private func remove(_ tag: String) {
        store.send(.tagsEdited(deviceCode: device.deviceCode, tags: device.tags.filter { $0 != tag }))
    }
}
