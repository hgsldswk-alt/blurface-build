import Combine
import Foundation
import SwiftUI
import UIKit

struct PhotoEntry: Identifiable {
    let id = UUID()
    var input: PhotoInput
    var source: URL?
    var thumbnail: CGImage?
    var layout: ImageLayout?
    var edit = RedactionEdit()
    var reading = true
    var failure: PhotoFailure?
    var saved = false
    var excluded = false

    var isReady: Bool { !reading && failure == nil && source != nil && !excluded }
    var stateTitle: String {
        if reading { return L.t("batch.reading") }
        if excluded { return L.t("batch.excluded") }
        if failure != nil { return L.t("batch.failed") }
        if saved { return L.t("batch.saved") }
        return L.t(edit.confirmed ? "batch.confirmed" : "batch.pending")
    }
}

struct ExportPresentation: Identifiable {
    enum Destination { case share, files }
    let id = UUID()
    let urls: [URL]
    let destination: Destination
    let exportedIDs: Set<UUID>
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var photos: [PhotoEntry] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var preview: CGImage?
    @Published private(set) var loading = false
    @Published private(set) var writing = false
    @Published private(set) var rendering = false
    @Published private(set) var firstUseReady = false
    @Published private(set) var presets: [RedactionPreset] = []
    @Published private(set) var milestones = Milestones()
    @Published private(set) var shareRequested = false
    @Published private(set) var savedNotice: String?
    @Published var output: ExportPresentation?
    @Published var failure: PhotoFailure?
    @Published var notice: String?
    @Published var format: ExportFormat = .jpg
    @Published var includeBadge = true

    private let storage = PhotoStorage()
    private let defaults: UserDefaults
    private var originalPreview: CGImage?
    private var previewTask: Task<Void, Never>?
    private var scratch: [URL] = []
    private var jobConfig: [UUID: PhotoFailure] = [:]
    private let testing = Launch.isUITesting

    var entry: PhotoEntry? { photos.first { $0.id == selectedID } }
    var isBatch: Bool { photos.count > 1 }
    var canReview: Bool { firstUseReady && photos.isEmpty && !loading && !writing }
    var pendingCount: Int { photos.filter { !$0.excluded && !$0.saved && (!$0.edit.confirmed || !$0.isReady) }.count }
    var confirmedCount: Int { photos.filter { $0.isReady && $0.edit.confirmed && !$0.saved }.count }
    var canSaveCurrent: Bool { entry?.isReady == true && entry?.edit.hasPending == false && preview != nil && !rendering && !writing }
    var storeURL: URL? {
        ShareArtwork.storeURL(appID: Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String)
    }

    init() {
        if Launch.isUITesting {
            let suite = "com.hgsldswk.blurface.ui-testing"
            let tests = UserDefaults(suiteName: suite) ?? .standard
            if Launch.has("-reset") { tests.removePersistentDomain(forName: suite) }
            defaults = tests
        } else {
            defaults = .standard
        }
    }

    func prepare() async {
        guard !firstUseReady else { return }
        do { try await storage.prepare() }
        catch { failure = PhotoFailure.classify(error, fallback: .write) }
        if let data = defaults.data(forKey: "presets"),
           let values = try? JSONDecoder().decode([RedactionPreset].self, from: data) {
            presets = values.filter(\.isValid)
        }
        if let data = defaults.data(forKey: "milestones"),
           let values = try? JSONDecoder().decode(Milestones.self, from: data) { milestones = values }
        if testing && Launch.has("-milestone") { milestones.recordSave(images: 9, at: Date()) }
        firstUseReady = true
    }

    func start(_ inputs: [PhotoInput]) async {
        guard canReview, !inputs.isEmpty else { return }
        guard inputs.count <= Launch.batchLimit else {
            notice = L.f("home.limit", Launch.batchLimit)
            return
        }
        photos = inputs.map { PhotoEntry(input: $0) }
        if photos.count == 1 { selectedID = photos[0].id }
        loading = true
        defer { loading = false }
        for id in photos.map(\.id) { await load(id) }
    }

    func retry(_ id: UUID) async {
        guard !loading, !writing, let index = index(id), photos[index].failure != nil else { return }
        loading = true
        defer { loading = false }
        photos[index].reading = true
        photos[index].failure = nil
        if testing && Launch.has("-recover"), case .sample(.unavailable) = photos[index].input {
            photos[index].input = .sample(.street)
        }
        await load(id)
    }

    private func load(_ id: UUID) async {
        guard let initialIndex = index(id) else { return }
        let input = photos[initialIndex].input
        do {
            let loaded = try await storage.load(input, retrySource: photos[initialIndex].source)
            guard let index = index(id) else { return }
            photos[index].source = loaded.source
            photos[index].layout = loaded.image.layout
            photos[index].thumbnail = loaded.image.thumbnail
            switch loaded.scan {
            case .success(let regions):
                photos[index].edit = RedactionEdit(regions: regions)
            case .failure(let error):
                photos[index].failure = error
            }
            if selectedID == id { setOriginal(loaded.image.preview) }
        } catch {
            guard let index = index(id) else { return }
            photos[index].source = nil
            photos[index].failure = PhotoFailure.classify(error, fallback: .unavailable)
        }
        if let index = index(id) { photos[index].reading = false }
    }

    func select(_ id: UUID?) async {
        previewTask?.cancel()
        selectedID = id
        preview = nil
        originalPreview = nil
        rendering = false
        savedNotice = nil
        guard let id, let entry, let source = entry.source else { return }
        rendering = true
        do {
            let image = try await storage.openPreview(source)
            guard selectedID == id else { return }
            setOriginal(image)
        } catch {
            guard selectedID == id, let index = index(id) else { return }
            photos[index].failure = PhotoFailure.classify(error, fallback: .unavailable)
            photos[index].source = nil
            photos[index].edit.resetConfirmation()
            await storage.remove(source)
            guard selectedID == id else { return }
            rendering = false
        }
    }

    private func setOriginal(_ image: CGImage) {
        originalPreview = image
        refreshPreview()
    }

    private func refreshPreview(countsAsCoreAction: Bool = false) {
        previewTask?.cancel()
        guard let originalPreview, let entry else { return }
        let applied = entry.edit.regions.filter(\.applied)
        if applied.isEmpty {
            rendering = false
            preview = originalPreview
            return
        }
        rendering = true
        previewTask = Task {
            do {
                let image = try await storage.preview(originalPreview, regions: applied)
                guard !Task.isCancelled, selectedID == entry.id else { return }
                preview = image
                rendering = false
                if countsAsCoreAction && failure == nil && notice == nil { CoreReview.shared.record() }
            } catch {
                guard !Task.isCancelled, selectedID == entry.id else { return }
                preview = nil
                rendering = false
                failure = PhotoFailure.classify(error, fallback: .write)
            }
        }
    }

    func change(_ changes: (inout [RedactionRegion]) -> Void) {
        guard let selectedID, let index = index(selectedID), !writing, !photos[index].reading else { return }
        let before = photos[index].edit
        photos[index].edit.update(changes)
        if before != photos[index].edit { edited(index) }
    }

    func undo() {
        guard let selectedID, let index = index(selectedID), !writing else { return }
        photos[index].edit.undo()
        edited(index)
    }

    func applyAll(batch: Bool) {
        guard !writing else { return }
        for index in photos.indices where photos[index].isReady && (batch || photos[index].id == selectedID) {
            if photos[index].edit.hasPending {
                photos[index].edit.applyAll()
                edited(index)
            }
        }
    }

    func allowManualReview() {
        guard let selectedID, let index = index(selectedID), photos[index].source != nil,
              case .scan? = photos[index].failure, !loading else { return }
        photos[index].failure = nil
    }

    func confirm(_ id: UUID) -> Bool {
        guard let index = index(id), photos[index].isReady else { return false }
        return photos[index].edit.confirm()
    }

    func exclude(_ id: UUID) {
        guard let index = index(id), !loading, !writing else { return }
        photos[index].excluded.toggle()
        photos[index].edit.resetConfirmation()
    }

    private func edited(_ index: Int) {
        photos[index].saved = false
        jobConfig[photos[index].id] = nil
        savedNotice = nil
        if photos[index].id == selectedID { refreshPreview(countsAsCoreAction: true) }
    }

    func copyPositions(_ regions: [RedactionRegion], from layout: ImageLayout, to targets: Set<UUID>) -> Int {
        guard Launch.freePeriod, !loading, !writing, !regions.isEmpty else { return 0 }
        var count = 0
        for index in photos.indices where targets.contains(photos[index].id) && photos[index].id != selectedID &&
                photos[index].isReady && photos[index].layout == layout {
            let before = photos[index].edit
            photos[index].edit.update { work in
                for region in regions where !work.contains(where: { $0.box == region.box && $0.rule == region.rule && $0.applied }) {
                    var copy = RedactionRegion(box: region.box, kind: .manual, origin: .template, applied: true)
                    copy.rule = region.rule
                    work.append(copy)
                }
            }
            if photos[index].edit != before {
                edited(index)
                count += 1
            }
        }
        return count
    }

    func applyPreset(_ preset: RedactionPreset, positions: Bool) {
        let canApplyPositions = Launch.freePeriod && positions && entry?.layout == preset.layout
        change { regions in
            for index in regions.indices { regions[index].rule = preset.rule(for: regions[index].rule.kind) }
            if canApplyPositions {
                for position in preset.positions where !regions.contains(where: { $0.box == position.box && $0.rule == position.rule && $0.applied }) {
                    var added = RedactionRegion(box: position.box, kind: .manual, origin: .template, applied: true)
                    added.rule = position.rule
                    regions.append(added)
                }
            }
        }
    }

    func addPreset(_ preset: RedactionPreset) {
        guard preset.isValid else { return }
        var updated = presets
        if Launch.freePeriod || presets.isEmpty { updated.insert(preset, at: 0) } else { updated[0] = preset }
        persistPresets(updated)
    }

    func removePreset(_ preset: RedactionPreset) { persistPresets(presets.filter { $0.id != preset.id }) }

    private func persistPresets(_ values: [RedactionPreset]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: "presets")
        presets = values
    }

    func toPhotos(current: Bool) async {
        guard !writing, !loading else { return }
        let entries = exportEntries(current: current)
        guard !entries.isEmpty else { return }
        let format = format
        var successes = 0
        var firstFailure: PhotoFailure?
        writing = true
        savedNotice = nil
        for entry in entries {
            guard let source = entry.source else { continue }
            var file: URL?
            do {
                try testExportFailure()
                let url = try await storage.export(source, regions: entry.edit.regions, format: format)
                file = url
                if testing && Launch.has("-denied") { throw PhotoFailure.permission }
                if !testing { try await Album.save(url) }
                if let index = index(entry.id) {
                    photos[index].saved = true
                    successes += 1
                }
                jobConfig[entry.id] = nil
            } catch {
                let error = PhotoFailure.classify(error, fallback: .write)
                jobConfig[entry.id] = error
                if firstFailure == nil { firstFailure = error }
            }
            if let file { await storage.remove(file) }
        }
        writing = false
        if successes > 0 { recordSave(successes) }
        failure = firstFailure
    }

    func makeExport(current: Bool, destination: ExportPresentation.Destination, includeBadge: Bool) async {
        guard !writing, !loading else { return }
        let entries = exportEntries(current: current)
        guard !entries.isEmpty else { return }
        let format = format
        await withOutputs(destination: destination, exportedIDs: Set(entries.map(\.id))) {
            var urls: [URL] = []
            do {
                for entry in entries {
                    guard let source = entry.source else { continue }
                    try testExportFailure()
                    let clean = try await storage.export(source, regions: entry.edit.regions, format: format)
                    if includeBadge {
                        do {
                            let artwork = try await storage.shareCard(clean: clean, count: 0, includeBadge: true,
                                                                      format: format, storeURL: storeURL)
                            urls.append(artwork)
                        } catch {
                            await storage.remove(clean)
                            throw error
                        }
                        await storage.remove(clean)
                    } else {
                        urls.append(clean)
                    }
                }
                return urls
            } catch {
                for url in urls { await storage.remove(url) }
                throw error
            }
        }
    }

    func makeMilestone(destination: ExportPresentation.Destination, includeBadge: Bool) async {
        guard milestones.hasCard else { return }
        await withOutputs(destination: destination, exportedIDs: []) {
            [try await storage.shareCard(clean: nil, count: milestones.savedImages, includeBadge: includeBadge,
                                         format: .png, storeURL: storeURL)]
        }
    }

    func readPreset(_ url: URL) async throws -> RedactionPreset {
        try await storage.readPreset(url)
    }

    func makePresetFile(_ preset: RedactionPreset) async {
        await withOutputs(destination: .files, exportedIDs: []) {
            [try await storage.writePreset(PresetCode.encode(preset))]
        }
    }

    func completeOutput(_ presentation: ExportPresentation, saved: Bool) async {
        if saved && !presentation.exportedIDs.isEmpty {
            for index in photos.indices where presentation.exportedIDs.contains(photos[index].id) {
                photos[index].saved = true
                jobConfig[photos[index].id] = nil
            }
            recordSave(presentation.exportedIDs.count)
        }
        output = nil
        let finished = Set(presentation.urls)
        scratch.removeAll { finished.contains($0) }
        for url in finished { await storage.remove(url) }
    }

    private func withOutputs(destination: ExportPresentation.Destination, exportedIDs: Set<UUID>,
                             _ produce: () async throws -> [URL]) async {
        guard !writing && output == nil else { return }
        writing = true
        shareRequested = false
        defer { writing = false }
        do {
            let urls = try await produce()
            guard !urls.isEmpty else { throw PhotoFailure.write }
            if testing {
                shareRequested = true
                if case .files = destination, !exportedIDs.isEmpty {
                    let presentation = ExportPresentation(urls: urls, destination: destination, exportedIDs: exportedIDs)
                    await completeOutput(presentation, saved: true)
                } else {
                    for url in urls { await storage.remove(url) }
                }
            } else {
                scratch += urls
                output = ExportPresentation(urls: urls, destination: destination, exportedIDs: exportedIDs)
            }
        } catch {
            failure = PhotoFailure.classify(error, fallback: .write)
        }
    }

    private func exportEntries(current: Bool) -> [PhotoEntry] {
        if current {
            guard canSaveCurrent, let id = selectedID, confirm(id), let entry else { return [] }
            return [entry]
        }
        return photos.filter { $0.isReady && $0.edit.confirmed && !$0.saved }
    }

    func exportFailure(_ id: UUID) -> PhotoFailure? { jobConfig[id] }
    func clearShareFeedback() { shareRequested = false }

    func finish() async {
        guard !loading && !writing else { return }
        loading = true
        previewTask?.cancel()
        await storage.clearInputs()
        for url in scratch { await storage.remove(url) }
        scratch = []
        photos = []
        selectedID = nil
        preview = nil
        originalPreview = nil
        rendering = false
        shareRequested = false
        savedNotice = nil
        jobConfig = [:]
        loading = false
    }

    private func recordSave(_ count: Int) {
        milestones.recordSave(images: count, at: Date())
        if let data = try? JSONEncoder().encode(milestones) { defaults.set(data, forKey: "milestones") }
        savedNotice = L.f("export.saved", count)
    }

    func requestExportReview(_ request: () -> Void) {
        var next = milestones
        guard !testing, canReview, output == nil, failure == nil, notice == nil,
              CoreReview.shared.attempt(ifEligible: { next.registerReviewIfEligible(at: Date()) }, request) else { return }
        milestones = next
        if let data = try? JSONEncoder().encode(milestones) { defaults.set(data, forKey: "milestones") }
    }

    private func testExportFailure() throws {
        if testing && Launch.has("-no-space") { throw PhotoFailure.insufficientSpace }
    }

    private func index(_ id: UUID) -> Int? { photos.firstIndex { $0.id == id } }
}
