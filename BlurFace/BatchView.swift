import SwiftUI

struct BatchView: View {
    enum Filter: String, CaseIterable {
        case all, pending, confirmed, failed
        var title: String { L.t("filter." + rawValue) }

        func includes(_ photo: PhotoEntry, exportFailed: Bool) -> Bool {
            switch self {
            case .all: return true
            case .pending: return !photo.excluded && photo.failure == nil && !exportFailed && !photo.edit.confirmed
            case .confirmed: return !photo.excluded && !exportFailed && photo.edit.confirmed
            case .failed: return !photo.excluded && (photo.failure != nil || exportFailed)
            }
        }
    }

    @ObservedObject var model: AppModel
    var onBack: () -> Void
    var onExport: () -> Void
    var onMilestone: () -> Void
    @State private var filter = Filter.all

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                HeaderButton(title: L.t("work.back"), id: "batch.back", symbol: "chevron.left", action: onBack)
                    .disabled(model.loading || model.writing)
                PageHeading(title: L.t("batch.title"), subtitle: L.f("batch.total", model.photos.count), id: "batch.title")
            }
            Notice(text: L.t("batch.review"), warning: true, icon: "exclamationmark.triangle")
            filters
            ScrollView {
                LazyVStack(spacing: 8) {
                    let visible = model.photos.enumerated().filter {
                        filter.includes($0.element, exportFailed: model.exportFailure($0.element.id) != nil)
                    }
                    if visible.isEmpty { Notice(text: L.t("batch.empty")) }
                    ForEach(Array(visible), id: \.element.id) { index, photo in row(index: index, photo: photo) }
                }
            }
            .accessibilityIdentifier("batch.scroll")
            if model.loading {
                ProgressView(L.t("editor.scanning")).font(.footnote).frame(maxWidth: .infinity)
            }
            if let message = model.savedNotice {
                Notice(text: message, icon: "checkmark.circle").accessibilityIdentifier("export.saved")
            }
            bottomActions
        }
        .padding(.horizontal, 19)
        .padding(.vertical, 10)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Filter.allCases, id: \.self) { option in
                    Button {
                        filter = option
                    } label: {
                        Text(option.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(filter == option ? Color.white : Theme.accent)
                            .padding(.horizontal, 11)
                            .frame(minHeight: 44)
                            .background(filter == option ? Theme.accent : .white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("batch.filter." + option.rawValue)
                    .accessibilityAddTraits(filter == option ? .isSelected : [])
                }
            }
        }
    }

    private func row(index: Int, photo: PhotoEntry) -> some View {
        let exportError = model.exportFailure(photo.id)
        return HStack(spacing: 8) {
            Button {
                Task { await model.select(photo.id) }
            } label: {
                HStack(spacing: 8) {
                    Group {
                        if let image = photo.thumbnail {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                        } else {
                            Image(systemName: photo.reading ? "photo" : "exclamationmark.triangle")
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(width: 47, height: 40).background(Theme.tint).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L.f("batch.item", index + 1)).font(.subheadline.weight(.semibold))
                        Text(exportError.map { L.t($0.key) } ?? photo.stateTitle)
                            .font(.caption)
                            .foregroundStyle(photo.failure != nil || exportError != nil ? Theme.warn : Theme.muted)
                            .accessibilityIdentifier("batch.status." + String(index))
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.accent)
                }
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("batch.item." + String(index))
            .disabled(photo.reading || photo.excluded || model.writing)
            if !photo.saved {
                Button {
                    model.exclude(photo.id)
                } label: {
                    Image(systemName: photo.excluded ? "arrow.uturn.backward" : "minus.circle")
                        .foregroundStyle(Theme.accent).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L.t(photo.excluded ? "batch.include" : "batch.exclude"))
                .accessibilityIdentifier("batch.exclude." + String(index))
                .disabled(model.loading || model.writing)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
    }

    private var bottomActions: some View {
        VStack(spacing: 7) {
            if model.photos.contains(where: { $0.isReady && $0.edit.hasPending }) {
                Action(title: L.t("editor.applyAll"), id: "batch.applyAll", symbol: "square.dashed", primary: true) {
                    model.applyAll(batch: true)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { exportActions }
                VStack(spacing: 8) { exportActions }
            }
            if model.milestones.hasCard {
                Action(title: L.t("milestone.title"), id: "batch.milestone", action: onMilestone)
            }
        }
        .disabled(model.loading || model.writing)
    }

    @ViewBuilder private var exportActions: some View {
        Action(title: L.t("export.options"), id: "batch.export", action: onExport)
            .disabled(model.confirmedCount == 0)
        Action(title: L.f("batch.save", model.confirmedCount), id: "batch.save", primary: true) {
            Task { await model.toPhotos(current: false) }
        }
        .disabled(model.confirmedCount == 0)
    }
}
