import StoreKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct BlurFaceApp: App {
    var body: some Scene {
        WindowGroup { RootView().preferredColorScheme(.light) }
    }
}

@MainActor
struct RootView: View {
    enum Page: Equatable { case work, settings, export, milestone }
    enum InputKind: Equatable { case photos, preset }

    @StateObject private var model = AppModel()
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: Page = .work
    @State private var exportIsCurrent = true
    @State private var photoPicker = false
    @State private var importer = false
    @State private var inputKind = InputKind.photos
    @State private var discard = false
    @State private var importedPreset: RedactionPreset?
    @State private var readingPreset = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.writing || model.shareRequested {
                VStack(spacing: 5) {
                    if model.writing { ProgressView(L.t("export.working")).font(.footnote) }
                    if model.shareRequested {
                        Text(L.t("share.ready")).font(.footnote)
                            .accessibilityIdentifier("share.requested")
                    }
                }
                .padding(7)
                .frame(maxWidth: .infinity)
                .background(Theme.tint)
            }
        }
        .background(Theme.paper.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        .sheet(isPresented: $photoPicker) {
            SystemPhotoPicker(limit: Launch.batchLimit, continuous: false) { inputs in
                photoPicker = false
                Task { await model.start(inputs) }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .sheet(item: $model.output) { output in
            outputSheet(output).interactiveDismissDisabled()
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: inputKind == .photos ? [.image] : [.plainText],
                      allowsMultipleSelection: inputKind == .photos, onCompletion: importFiles)
        .alert(L.t("alert.title"), isPresented: alertShown) {
            Button(L.t("action.ok"), role: .cancel) { clearAlert() }
        } message: {
            Text(model.failure.map { L.t($0.key) } ?? model.notice ?? "")
        }
        .confirmationDialog(L.t("work.discardTitle"), isPresented: $discard, titleVisibility: .visible) {
            Button(L.t("work.discard"), role: .destructive) { Task { await model.finish() } }
            Button(L.t("action.cancel"), role: .cancel) {}
        } message: {
            Text(L.t("work.discardMessage"))
        }
        .task { await model.prepare() }
        .onChange(of: page) { _, _ in model.clearShareFeedback() }
        .reviewAfterCoreAction(when: ratingSurface && (model.canReview || model.preview != nil)) { requestReview() }
        .task(id: reviewEligible) {
            guard reviewEligible else { return }
            do { try await Task.sleep(for: .seconds(4)) }
            catch { return }
            if !Task.isCancelled, reviewEligible { model.requestExportReview { requestReview() } }
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .work:
            if let entry = model.entry {
                EditorView(model: model, entry: entry, onBack: closeEditor,
                           onExport: { showExport(current: true) },
                           onSettings: { page = .settings }, onMilestone: { page = .milestone })
                    .id(entry.id)
            } else if model.isBatch {
                BatchView(model: model, onBack: closeWork,
                          onExport: { showExport(current: false) }, onMilestone: { page = .milestone })
            } else {
                home
            }
        case .settings:
            SettingsView(model: model, imported: $importedPreset, onBack: { page = .work },
                         onImport: { showFiles(.preset) }, onMilestone: { page = .milestone })
        case .export:
            ExportView(model: model, isCurrent: exportIsCurrent, onBack: { page = .work },
                       onMilestone: { page = .milestone })
        case .milestone:
            MilestoneView(model: model, onBack: { page = .work })
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PageHeading(title: L.t("app.title"), subtitle: L.t("home.subtitle"), id: "home.title")
                HeaderButton(title: L.t("settings.title"), id: "home.settings", symbol: "gearshape") { page = .settings }
            }
            VStack(spacing: 8) {
                HStack {
                    Text(L.t("home.photos")).font(.headline)
                    Spacer()
                    Button(L.t("home.multi")) {
                        if Launch.isUITesting {
                            let samples: [Fixture] = [.street, .doc, .land, .doc]
                            Task { await model.start(samples.map { .sample($0) }) }
                        } else { photoPicker = true }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("home.multi")
                    .disabled(!model.firstUseReady)
                }
                if Launch.isUITesting {
                    fixturePicker
                } else {
                    SystemPhotoPicker(limit: 1, continuous: true) { inputs in
                        Task { await model.start(inputs) }
                    }
                    .frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .allowsHitTesting(model.firstUseReady)
                }
            }
            .card()
            .frame(maxHeight: .infinity)
            Action(title: L.t("home.files"), id: "home.files", symbol: "folder") { showFiles(.photos) }
                .disabled(!model.firstUseReady)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { homePresetActions }
                VStack(spacing: 8) { homePresetActions }
            }
            .disabled(readingPreset)
            Text(L.t("home.live")).foregroundStyle(Theme.muted).font(.caption)
        }
        .padding(.horizontal, 19)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var homePresetActions: some View {
        Action(title: L.t("preset.import"), id: "home.importPreset", symbol: "doc.on.clipboard") { page = .settings }
        Action(title: L.t("preset.importFile"), id: "home.importPresetFile", symbol: "folder") { showFiles(.preset) }
    }

    private var fixturePicker: some View {
        let samples: [Fixture] = [.street, .land, .doc, .land, .doc, .street]
        return VStack(spacing: 4) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(samples.indices, id: \.self) { index in
                    Button {
                        openFixture(samples[index])
                    } label: {
                        GeometryReader { proxy in
                            Image(samples[index].resource)
                                .resizable().scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L.f("fixture.photo", index + 1))
                    .accessibilityIdentifier("fixture.photo." + String(index))
                }
            }
            if Launch.has("-recover") || Launch.has("-scan-failure") {
                Action(title: L.t("fixture.failure"), id: "fixture.failure") {
                    openFixture(Launch.has("-scan-failure") ? .scanFailure : .unavailable)
                }
            }
            Spacer(minLength: 0)
        }
        .disabled(!model.firstUseReady)
    }

    private func openFixture(_ fixture: Fixture) {
        Task { await model.start([.sample(fixture)]) }
    }

    @ViewBuilder private func outputSheet(_ output: ExportPresentation) -> some View {
        switch output.destination {
        case .share:
            ActivitySheet(urls: output.urls) { Task { await model.completeOutput(output, saved: false) } }
        case .files:
            SaveFilesSheet(urls: output.urls) { saved in Task { await model.completeOutput(output, saved: saved) } }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                if inputKind == .preset { model.notice = L.t("preset.invalid") }
                else { model.failure = .unavailable }
            }
        case .success(let urls):
            if inputKind == .preset, let url = urls.first {
                openPresetFile(url)
            } else if inputKind == .photos {
                Task { await model.start(urls.map { .file($0) }) }
            }
        }
    }

    private func openPresetFile(_ url: URL, removeAfterReading: Bool = false) {
        readingPreset = true
        let origin = page
        let entryID = model.entry?.id
        Task {
            defer {
                readingPreset = false
                if removeAfterReading { try? FileManager.default.removeItem(at: url) }
            }
            do {
                let preset = try await model.readPreset(url)
                guard page == origin, model.entry?.id == entryID, !model.loading else { return }
                importedPreset = preset
                page = .settings
            } catch { model.notice = L.t("preset.invalid") }
        }
    }

    private func showFiles(_ kind: InputKind) {
        guard !readingPreset else { return }
        if Launch.isUITesting && kind == .photos {
            openFixture(.street)
            return
        }
        if Launch.isUITesting && kind == .preset, let text = ProcessInfo.processInfo.environment["UI_PRESET_CODE"] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
            do {
                try Data(text.utf8).write(to: file)
                openPresetFile(file, removeAfterReading: true)
            } catch { model.notice = L.t("preset.invalid") }
            return
        }
        inputKind = kind
        importer = true
    }

    private func showExport(current: Bool) {
        exportIsCurrent = current
        page = .export
    }

    private func closeEditor() {
        if model.isBatch { Task { await model.select(nil) } }
        else { closeWork() }
    }

    private func closeWork() {
        if model.photos.allSatisfy({ $0.saved || $0.excluded }) { Task { await model.finish() } }
        else { discard = true }
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { model.failure != nil || model.notice != nil }, set: { if !$0 { clearAlert() } })
    }

    private func clearAlert() {
        model.failure = nil
        model.notice = nil
    }

    private var reviewEligible: Bool {
        scenePhase == .active && ratingSurface && model.canReview
    }

    private var ratingSurface: Bool {
        page == .work && !importer && !photoPicker && !discard && !readingPreset && importedPreset == nil && !model.loading && !model.writing && !model.rendering
            && model.output == nil && model.failure == nil && model.notice == nil
    }
}
