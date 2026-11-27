import SwiftUI

struct EditorView: View {
    @ObservedObject var model: AppModel
    let entry: PhotoEntry
    var onBack: () -> Void
    var onExport: () -> Void
    var onSettings: () -> Void
    var onMilestone: () -> Void
    @State private var selected: UUID?
    @State private var tool: PhotoCanvas.Tool = .select
    @State private var zoom: CGFloat = 1
    @State private var layoutPrompt = false
    @State private var layoutTargets: Set<UUID> = []
    @State private var presetsShown = false
    @State private var templateFeedback: String?

    private var region: RedactionRegion? { entry.edit.regions.first { $0.id == selected } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if entry.reading { ProgressView(L.t("editor.scanning")).frame(maxWidth: .infinity).padding(26) }
                if let error = entry.failure { errors(error) }
                if let image = model.preview {
                    editorCard(image)
                    if entry.failure == nil {
                        if entry.edit.regions.isEmpty {
                            Notice(text: L.t("editor.none"), warning: true, icon: "exclamationmark.triangle")
                                .accessibilityIdentifier("editor.zero")
                        }
                        saveActions
                        if entry.edit.hasPending {
                            Notice(text: L.t("editor.review"), warning: true, icon: "exclamationmark.triangle")
                                .accessibilityIdentifier("editor.review")
                        } else if !entry.edit.regions.isEmpty {
                            Notice(text: L.t("editor.checkedByYou"), icon: "checkmark.shield")
                        }
                    }
                    if let region { editControls(region) }
                    if entry.failure == nil { secondaryActions }
                }
                if let message = model.savedNotice {
                    Notice(text: message, icon: "checkmark.circle").accessibilityIdentifier("export.saved")
                }
                if model.milestones.hasCard {
                    Action(title: L.t("milestone.title"), id: "editor.milestone", symbol: "rectangle.portrait") {
                        onMilestone()
                    }
                }
            }
            .padding(.horizontal, 19)
            .padding(.vertical, 10)
        }
        .accessibilityIdentifier("editor.scroll")
        .sheet(isPresented: $layoutPrompt) { layoutConfirmation }
        .sheet(isPresented: $presetsShown) { PresetPickerView(model: model, onClose: { presetsShown = false }) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            HeaderButton(title: L.t(model.isBatch ? "batch.title" : "work.back"), id: "editor.back", symbol: "chevron.left", action: onBack)
                .disabled(model.loading || model.writing)
            PageHeading(title: L.t(entry.edit.hasPending ? "editor.candidates" : "editor.title"),
                        subtitle: entry.layout.map { L.f("editor.dimensions", $0.width, $0.height) }, id: "editor.title")
            HeaderButton(title: L.t("settings.title"), id: "editor.settings", symbol: "gearshape", action: onSettings)
                .disabled(model.loading || model.writing)
        }
    }

    private func errors(_ error: PhotoFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Notice(text: L.t(error.key), warning: true, icon: "exclamationmark.triangle")
                .accessibilityIdentifier("editor.failure")
            Action(title: L.t("action.retry"), id: "editor.retry") { Task { await model.retry(entry.id) } }
            if case .scan = error {
                Action(title: L.t("editor.manualReview"), id: "editor.manualReview") { model.allowManualReview() }
            }
        }
        .disabled(model.loading || model.writing)
    }

    private func editorCard(_ image: CGImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if entry.edit.hasPending { detectionCounts }
            PhotoCanvas(image: image, regions: entry.edit.regions, selected: $selected,
                        tool: $tool, zoom: $zoom, add: addBox, move: moveBox)
                .frame(height: 225)
                .overlay(alignment: .topTrailing) {
                    if model.rendering { ProgressView().padding(9).background(.white, in: Circle()).padding(7) }
                }
            toolBar
            if tool == .draw {
                Text(L.t("editor.drawHint")).font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .card()
        .disabled(model.writing || entry.reading || entry.failure != nil)
    }

    private var detectionCounts: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { countTags }
            VStack(alignment: .leading, spacing: 4) { countTags }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.counts")
    }

    @ViewBuilder private var countTags: some View {
        ForEach([RegionKind.face, .plate, .text], id: \.self) { kind in
            StatusTag(text: L.f("editor.categoryCount", kind.title, entry.edit.regions.filter { $0.rule.kind == kind }.count))
        }
    }

    private var toolBar: some View {
        HStack(spacing: 6) {
            toolButton("editor.add", "plus.viewfinder", active: tool == .draw) {
                tool = tool == .draw ? .select : .draw
            }
            .accessibilityAction(named: Text(L.t("editor.addCentered"))) {
                if let box = RegionBox.clipped(CGRect(x: 0.38, y: 0.38, width: 0.24, height: 0.24)) { addBox(box) }
            }
            toolButton("editor.zoomOut", "minus.magnifyingglass") {
                zoom = max(1, zoom / 1.5)
            }.disabled(zoom <= 1)
            toolButton("editor.zoomIn", "plus.magnifyingglass") {
                zoom = min(5, zoom * 1.5)
            }.disabled(zoom >= 5)
            toolButton("editor.pan", "hand.draw", active: tool == .pan) {
                tool = tool == .pan ? .select : .pan
            }.disabled(zoom <= 1)
            Spacer(minLength: 0)
            toolButton("editor.undo", "arrow.uturn.backward") {
                model.undo()
            }.disabled(!entry.edit.canUndo)
        }
    }

    private func toolButton(_ key: String, _ symbol: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(active ? Color.white : Theme.accent)
                .frame(minWidth: 44, minHeight: 44)
                .background(active ? Theme.accent : Theme.paper, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.t(key))
        .accessibilityIdentifier(key)
    }

    @ViewBuilder private var saveActions: some View {
        if entry.edit.hasPending {
            Action(title: L.t("editor.applyAll"), id: "editor.applyAll", symbol: "square.dashed", primary: true) {
                selected = nil
                model.applyAll(batch: false)
            }
            .disabled(model.loading || model.writing)
        } else if model.isBatch {
            Action(title: L.t(entry.edit.confirmed ? "batch.confirmed" : "batch.confirm"),
                   id: "editor.confirm", symbol: "checkmark.circle", primary: true) {
                if model.confirm(entry.id) { onBack() }
            }
            .disabled(!model.canSaveCurrent || model.loading || entry.edit.confirmed)
        } else {
            Action(title: L.t("export.savePhotos"), id: "editor.save", symbol: "square.and.arrow.down", primary: true) {
                Task { await model.toPhotos(current: true) }
            }
            .disabled(!model.canSaveCurrent || model.loading)
            VStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { quickDelivery }
                    VStack(spacing: 8) { quickDelivery }
                }
                Action(title: L.t("share.withBadge"), id: "editor.shareCard", symbol: "qrcode") {
                    Task { await model.makeExport(current: true, destination: .share, includeBadge: true) }
                }
            }
            .disabled(!model.canSaveCurrent || model.loading)
        }
    }

    @ViewBuilder private var quickDelivery: some View {
        Action(title: L.t("export.files"), id: "editor.files", symbol: "folder") {
            Task { await model.makeExport(current: true, destination: .files, includeBadge: false) }
        }
        Action(title: L.t("export.shareClean"), id: "editor.shareClean", symbol: "square.and.arrow.up") {
            Task { await model.makeExport(current: true, destination: .share, includeBadge: false) }
        }
    }

    private var secondaryActions: some View {
        VStack(spacing: 8) {
            if !model.isBatch && !entry.edit.hasPending {
                Action(title: L.t("export.options"), id: "editor.export", symbol: "slider.horizontal.3", action: onExport)
                    .disabled(!model.canSaveCurrent)
            }
            if !entry.edit.regions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(entry.edit.regions.enumerated()), id: \.element.id) { index, item in
                            Button {
                                selected = item.id
                                tool = .select
                            } label: {
                                StatusTag(text: L.f("editor.region", item.rule.kind.title, index + 1), warning: !item.applied)
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("editor.region." + String(index))
                            .accessibilityAddTraits(selected == item.id ? .isSelected : [])
                        }
                    }
                }
            }
            if !model.presets.isEmpty {
                Action(title: L.t("preset.use"), id: "editor.presets") { presetsShown = true }
            }
        }
    }

    private func editControls(_ region: RedactionRegion) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L.t("editor.selected")).font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(RedactionStyle.allCases, id: \.self) { style in
                        Button {
                            update(region.id) { $0.rule.style = style; $0.applied = true }
                        } label: {
                            StatusTag(text: style.title, warning: region.rule.style == style).frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("editor.style." + style.rawValue)
                        .accessibilityAddTraits(region.rule.style == style ? .isSelected : [])
                    }
                }
            }
            if region.rule.style == .blur || region.rule.style == .mosaic {
                Text(L.f("editor.strength", region.rule.strength)).font(.footnote)
                Slider(value: Binding(get: { Double(region.rule.strength) }, set: { strength in
                    update(region.id) { $0.rule.strength = Int(strength) }
                }), in: 5...100, step: 5)
                .accessibilityLabel(L.t("editor.strengthLabel"))
                .accessibilityIdentifier("editor.strength")
                Notice(text: L.t("editor.weakWarning"), warning: true)
            } else if region.rule.style == .sticker {
                HStack {
                    ForEach(0..<3) { variant in
                        Button {
                            update(region.id) { $0.rule.sticker = variant }
                        } label: {
                            StatusTag(text: L.f("editor.sticker", variant + 1), warning: region.rule.sticker == variant)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("editor.sticker." + String(variant))
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { regionActions(region) }
                VStack(spacing: 8) { regionActions(region) }
            }
                if model.isBatch && Launch.freePeriod && region.origin != .detected && region.applied {
                Action(title: L.t("batch.copyFrame"), id: "editor.copyFrame") {
                    layoutTargets = []
                    layoutPrompt = true
                }
                    .disabled(model.loading)
            }
            if let templateFeedback { Text(templateFeedback).font(.footnote).accessibilityIdentifier("editor.templateResult") }
        }
        .card()
        .disabled(model.writing || entry.failure != nil)
    }

    @ViewBuilder private func regionActions(_ region: RedactionRegion) -> some View {
        Action(title: L.t("editor.shrink"), id: "editor.shrink") { resize(region, scale: 0.87) }
        Action(title: L.t("editor.grow"), id: "editor.grow") { resize(region, scale: 1.15) }
        Action(title: L.t("action.remove"), id: "editor.remove", symbol: "trash") {
            model.change { $0.removeAll { $0.id == region.id } }
            selected = nil
        }
    }

    private var layoutConfirmation: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeading(title: L.t("batch.copyFrame"))
            Notice(text: L.t("batch.sameLayout"), warning: true)
            ScrollView {
                VStack(spacing: 5) {
                    let matches = model.photos.enumerated().filter {
                        $0.element.id != entry.id && $0.element.isReady && $0.element.layout == entry.layout
                    }
                    if matches.isEmpty { Notice(text: L.t("batch.noMatching")) }
                    ForEach(Array(matches), id: \.element.id) { index, candidate in
                        Toggle(isOn: Binding(get: { layoutTargets.contains(candidate.id) }, set: {
                            if $0 { layoutTargets.insert(candidate.id) } else { layoutTargets.remove(candidate.id) }
                        })) {
                            HStack(spacing: 8) {
                                if let thumbnail = candidate.thumbnail {
                                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFit().frame(width: 65)
                                }
                                Text(L.f("batch.item", index + 1))
                            }
                        }
                        .accessibilityIdentifier("editor.layoutTarget." + String(index))
                    }
                }
            }
            Action(title: L.t("batch.applyMatching"), id: "editor.confirmLayout", primary: true) {
                if let region, let layout = entry.layout {
                    let count = model.copyPositions([region], from: layout, to: layoutTargets)
                    templateFeedback = L.f("batch.templateApplied", count)
                }
                layoutPrompt = false
            }
            .disabled(layoutTargets.isEmpty)
            Action(title: L.t("action.cancel"), id: "editor.cancelLayout") { layoutPrompt = false }
        }
        .padding(20)
        .padding(.top, 14)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func addBox(_ box: RegionBox) {
        let region = RedactionRegion(box: box, kind: .manual, origin: .manual, applied: true)
        model.change { $0.append(region) }
        selected = region.id
        tool = .select
    }

    private func moveBox(_ id: UUID, _ box: RegionBox) { update(id) { $0.box = box } }

    private func resize(_ region: RedactionRegion, scale: CGFloat) {
        let rect = region.box.rect
        let changed = rect.insetBy(dx: rect.width * (1 - scale) / 2, dy: rect.height * (1 - scale) / 2)
        if let box = RegionBox.clipped(changed) { moveBox(region.id, box) }
    }

    private func update(_ id: UUID, _ change: (inout RedactionRegion) -> Void) {
        model.change { regions in
            if let index = regions.firstIndex(where: { $0.id == id }) { change(&regions[index]) }
        }
    }
}

struct PhotoCanvas: View {
    enum Tool { case select, draw, pan }
    let image: CGImage
    let regions: [RedactionRegion]
    @Binding var selected: UUID?
    @Binding var tool: Tool
    @Binding var zoom: CGFloat
    var add: (RegionBox) -> Void
    var move: (UUID, RegionBox) -> Void
    @State private var pan: CGSize = .zero
    @GestureState private var drag: DragGesture.Value?
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let base = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
            let scale = min(5, max(1, zoom * magnification)) * base
            let width = CGFloat(image.width) * scale
            let height = CGFloat(image.height) * scale
            let offset = boundedPan(in: size, width: width, height: height, drag: tool == .pan ? drag?.translation : nil)
            let visible = CGRect(x: (size.width - width) / 2 + offset.width,
                                 y: (size.height - height) / 2 + offset.height, width: width, height: height)
            ZStack(alignment: .topLeading) {
                Theme.tint
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: width, height: height)
                    .position(x: visible.midX, y: visible.midY)
                ForEach(regions) { region in
                    if !region.applied || selected == region.id {
                        let rect = screenRect(region.box, in: visible)
                        Rectangle()
                            .strokeBorder(selected == region.id ? Color.yellow : Theme.accent,
                                          style: StrokeStyle(lineWidth: 2, dash: region.applied ? [] : [5, 3]))
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                if tool == .draw, let drag {
                    let rect = dragRect(drag).intersection(visible)
                    if !rect.isEmpty {
                        Rectangle().strokeBorder(Color.yellow, lineWidth: 2)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($drag) { value, state, _ in state = value }
                .onEnded { value in handle(value, visible: visible, viewport: size) })
            .simultaneousGesture(MagnifyGesture()
                .updating($magnification) { value, state, _ in state = value.magnification }
                .onEnded { value in zoom = max(1, min(5, zoom * value.magnification)) })
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L.t("editor.preview"))
        .accessibilityIdentifier("editor.canvas")
        .onChange(of: zoom) { _, next in
            if next == 1 {
                pan = .zero
                if tool == .pan { tool = .select }
            }
        }
    }

    private func handle(_ drag: DragGesture.Value, visible: CGRect, viewport: CGSize) {
        switch tool {
        case .draw:
            let rect = dragRect(drag).intersection(visible)
            if rect.width >= 6, rect.height >= 6, let box = normalized(rect, in: visible) { add(box) }
        case .pan:
            pan = boundedPan(in: viewport, width: visible.width, height: visible.height, drag: drag.translation)
        case .select:
            guard visible.contains(drag.startLocation) else { return }
            let found = regions.last(where: { screenRect($0.box, in: visible).contains(drag.startLocation) })
            selected = found?.id
            if let found, hypot(drag.translation.width, drag.translation.height) >= 5 {
                var rect = screenRect(found.box, in: visible)
                rect.origin.x = min(max(visible.minX, rect.minX + drag.translation.width), visible.maxX - rect.width)
                rect.origin.y = min(max(visible.minY, rect.minY + drag.translation.height), visible.maxY - rect.height)
                if let box = normalized(rect, in: visible) { move(found.id, box) }
            }
        }
    }

    private func dragRect(_ value: DragGesture.Value) -> CGRect {
        CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
               width: abs(value.translation.width), height: abs(value.translation.height))
    }

    private func screenRect(_ box: RegionBox, in visible: CGRect) -> CGRect {
        CGRect(x: visible.minX + box.x * visible.width, y: visible.minY + box.y * visible.height,
               width: box.width * visible.width, height: box.height * visible.height)
    }

    private func normalized(_ rect: CGRect, in visible: CGRect) -> RegionBox? {
        RegionBox.clipped(CGRect(x: (rect.minX - visible.minX) / visible.width, y: (rect.minY - visible.minY) / visible.height,
                                 width: rect.width / visible.width, height: rect.height / visible.height))
    }

    private func boundedPan(in viewport: CGSize, width: CGFloat, height: CGFloat, drag: CGSize?) -> CGSize {
        let dx = max(0, (width - viewport.width) / 2)
        let dy = max(0, (height - viewport.height) / 2)
        return CGSize(width: min(dx, max(-dx, pan.width + (drag?.width ?? 0))),
                      height: min(dy, max(-dy, pan.height + (drag?.height ?? 0))))
    }
}
