import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Binding var imported: RedactionPreset?
    var onBack: () -> Void
    var onImport: () -> Void
    var onMilestone: () -> Void
    @State private var input = ""
    @State private var positions: Set<UUID> = []
    @State private var feedback: String?
    @State private var openPrivacy = false
    @State private var openPresets: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HeaderButton(title: L.t("action.back"), id: "settings.back", symbol: "chevron.left", action: onBack)
                    PageHeading(title: L.t("settings.title"), id: "settings.title")
                }
                if let imported { importedView(imported) }
                else {
                    if model.milestones.hasCard {
                        Action(title: L.t("milestone.title"), id: "settings.milestone", action: onMilestone)
                    }
                    importCard
                    if let entry = model.entry, entry.layout != nil { makePreset(entry) }
                    if !model.presets.isEmpty { savedPresets }
                    Action(title: L.t("settings.privacy"), id: "settings.privacy", symbol: "hand.raised") { openPrivacy = true }
                }
                if let feedback { Notice(text: feedback).accessibilityIdentifier("preset.feedback") }
            }
            .padding(.horizontal, 19)
            .padding(.vertical, 10)
        }
        .accessibilityIdentifier("settings.scroll")
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $openPrivacy) {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    PageHeading(title: L.t("settings.privacy"))
                    Text(L.t("settings.privacyBody")).foregroundStyle(Theme.muted)
                    Action(title: L.t("action.done"), id: "privacy.close") { openPrivacy = false }
                }
                .padding(20)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("preset.import")).font(.headline)
            Text(L.t("preset.importHint")).font(.footnote).foregroundStyle(Theme.muted)
            TextEditor(text: $input)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .frame(height: 70)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityLabel(L.t("preset.input"))
                .accessibilityIdentifier("preset.input")
                .onChange(of: input) { _, value in
                    if value.utf8.count > PresetCode.maximumLength {
                        input = ""
                        model.notice = L.t("preset.invalid")
                    }
                }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { importActions }
                VStack(spacing: 8) { importActions }
            }
        }
        .card()
        .onAppear {
            if Launch.isUITesting, input.isEmpty, let text = ProcessInfo.processInfo.environment["UI_PRESET_CODE"] {
                input = text
            }
        }
    }

    @ViewBuilder private var importActions: some View {
        if Launch.isUITesting, let text = ProcessInfo.processInfo.environment["UI_PRESET_CODE"] {
            Button(L.t("preset.paste")) { previewCode(text) }
                .frame(minHeight: 44).accessibilityIdentifier("preset.paste")
        } else {
            PasteButton(payloadType: String.self) { values in
                if let value = values.first { previewCode(value) }
            }
            .labelStyle(.titleOnly).frame(minHeight: 44)
            .accessibilityIdentifier("preset.paste")
        }
        Action(title: L.t("preset.preview"), id: "preset.preview", primary: true) {
            previewCode(input)
        }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Action(title: L.t("preset.importFile"), id: "preset.importFile", symbol: "folder", action: onImport)
    }

    private func previewCode(_ code: String) {
        do {
            imported = try PresetCode.decode(code)
            feedback = nil
        } catch {
            model.notice = L.t("preset.invalid")
        }
    }

    private func importedView(_ preset: RedactionPreset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.t("preset.preview")).font(.headline)
            PresetSummary(preset: preset)
            Action(title: L.t("preset.save"), id: "preset.saveImported", symbol: "tray.and.arrow.down", primary: true) {
                model.addPreset(preset)
                imported = nil
                input = ""
                feedback = L.t("preset.saved")
            }
            if model.entry != nil {
                Action(title: L.t("preset.tryRules"), id: "preset.tryImported") {
                    model.applyPreset(preset, positions: false)
                    imported = nil
                    onBack()
                }
            }
            Action(title: L.t("action.cancel"), id: "preset.cancelImport") { imported = nil }
        }
        .card()
    }

    private func makePreset(_ entry: PhotoEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("preset.create")).font(.headline)
            Text(L.t("preset.positionHint")).font(.footnote).foregroundStyle(Theme.muted)
            let candidates = Array(entry.edit.regions.filter { $0.origin != .detected }.prefix(24))
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, region in
                Toggle(L.f("preset.position", index + 1), isOn: Binding(get: { positions.contains(region.id) }, set: {
                    if $0 { positions.insert(region.id) } else { positions.remove(region.id) }
                }))
                .font(.subheadline)
                .accessibilityIdentifier("preset.position." + String(index))
            }
            Action(title: L.t("preset.save"), id: "preset.createSave") {
                guard let layout = entry.layout else { return }
                let preset = RedactionPreset.from(entry.edit.regions, positionIDs: positions, layout: layout)
                model.addPreset(preset)
                positions = []
                feedback = L.t("preset.saved")
            }
        }
        .card()
    }

    private var savedPresets: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("preset.savedList")).font(.headline)
            ForEach(Array(model.presets.enumerated()), id: \.element.id) { index, preset in
                Button {
                    if openPresets.contains(preset.id) { openPresets.remove(preset.id) }
                    else { openPresets.insert(preset.id) }
                } label: {
                    HStack {
                        Text(L.f("preset.item", index + 1))
                        Spacer()
                        Image(systemName: openPresets.contains(preset.id) ? "chevron.up" : "chevron.down")
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("preset.item." + String(index))
                if openPresets.contains(preset.id) {
                    VStack(alignment: .leading, spacing: 8) {
                        PresetSummary(preset: preset)
                        Action(title: L.t("preset.copy"), id: "preset.copy." + String(index), symbol: "doc.on.doc") {
                            do {
                                UIPasteboard.general.string = try PresetCode.encode(preset)
                                feedback = L.t("preset.copied")
                            } catch {
                                model.notice = L.t("preset.invalid")
                            }
                        }
                        Action(title: L.t("preset.saveFile"), id: "preset.file." + String(index), symbol: "folder") {
                            Task { await model.makePresetFile(preset) }
                        }
                        Action(title: L.t("action.remove"), id: "preset.remove." + String(index), symbol: "trash") {
                            openPresets.remove(preset.id)
                            model.removePreset(preset)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .card()
    }
}

struct PresetSummary: View {
    let preset: RedactionPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(preset.rules) { rule in
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.f("preset.rule", rule.kind.title, rule.style.title, rule.strength))
                    if rule.style == .sticker { Text(L.f("editor.sticker", rule.sticker + 1)).foregroundStyle(Theme.muted) }
                }
                .font(.footnote)
            }
            if let layout = preset.layout {
                Text(L.f("preset.positions", preset.positions.count, layout.width, layout.height))
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct PresetPickerView: View {
    @ObservedObject var model: AppModel
    var onClose: () -> Void
    @State private var positionPreset: RedactionPreset?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HeaderButton(title: L.t("action.back"), id: "preset.pickerClose", symbol: "chevron.left", action: onClose)
                    PageHeading(title: L.t("preset.use"))
                }
                ForEach(Array(model.presets.enumerated()), id: \.element.id) { index, preset in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L.f("preset.item", index + 1)).font(.headline)
                        PresetSummary(preset: preset)
                        if Launch.freePeriod || index == 0 {
                            Action(title: L.t("preset.tryRules"), id: "preset.try." + String(index)) {
                                model.applyPreset(preset, positions: false)
                                onClose()
                            }
                        }
                        if Launch.freePeriod && preset.layout == model.entry?.layout && !preset.positions.isEmpty {
                            Action(title: L.t("preset.usePositions"), id: "preset.positions." + String(index)) {
                                positionPreset = preset
                            }
                        }
                    }
                    .card()
                }
            }
            .padding(20)
        }
        .background(Theme.paper.ignoresSafeArea())
        .alert(L.t("preset.usePositions"), isPresented: Binding(get: { positionPreset != nil }, set: { if !$0 { positionPreset = nil } })) {
            Button(L.t("batch.applyMatching")) {
                if let positionPreset { model.applyPreset(positionPreset, positions: true) }
                onClose()
            }
            Button(L.t("action.cancel"), role: .cancel) {}
        } message: { Text(L.t("batch.sameLayout")) }
    }
}
