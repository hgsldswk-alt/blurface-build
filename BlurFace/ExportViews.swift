import SwiftUI

struct ExportView: View {
    @ObservedObject var model: AppModel
    let isCurrent: Bool
    var onBack: () -> Void
    var onMilestone: () -> Void
    @State private var shareVersion = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HeaderButton(title: L.t("action.back"), id: "export.back", symbol: "chevron.left", action: onBack)
                        .disabled(model.writing)
                    PageHeading(title: L.t(shareVersion ? "share.title" : "export.options"),
                                subtitle: L.t("export.subtitle"), id: "export.title")
                }
                if shareVersion {
                    photoPreview
                    if model.includeBadge { badgePreview }
                    Toggle(L.t("share.includeBadge"), isOn: $model.includeBadge)
                        .accessibilityIdentifier("share.badge").card()
                    Action(title: L.t("share.open"), id: "export.shareCard", symbol: "square.and.arrow.up", primary: true) {
                        Task { await model.makeExport(current: isCurrent, destination: .share, includeBadge: model.includeBadge) }
                    }
                    Action(title: L.t("export.cleanOptions"), id: "export.cleanOptions") { shareVersion = false }
                } else {
                    photoPreview
                    formatChoices
                    Notice(text: L.t("export.clean"), icon: "checkmark.shield")
                    Action(title: L.t("export.savePhotos"), id: "export.photos", symbol: "square.and.arrow.down", primary: true) {
                        Task { await model.toPhotos(current: isCurrent) }
                    }.disabled(!canExport)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { otherExports }
                        VStack(spacing: 8) { otherExports }
                    }
                    Action(title: L.t("share.create"), id: "export.makeCard") { shareVersion = true }
                        .disabled(!canExport)
                }
                if let message = model.savedNotice {
                    Notice(text: message, icon: "checkmark.circle").accessibilityIdentifier("export.saved")
                }
                if model.milestones.hasCard {
                    Action(title: L.t("milestone.title"), id: "export.milestone", action: onMilestone)
                }
            }
            .padding(.horizontal, 19)
            .padding(.vertical, 10)
        }
        .accessibilityIdentifier("export.scroll")
        .disabled(model.writing)
    }

    private var canExport: Bool { isCurrent ? model.canSaveCurrent : model.confirmedCount > 0 }

    @ViewBuilder private var photoPreview: some View {
        if isCurrent, let preview = model.preview {
            Image(decorative: preview, scale: 1)
                .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 245)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .card()
                .accessibilityLabel(L.t("editor.preview"))
        } else {
            Notice(text: L.f("export.confirmedOnly", model.confirmedCount), icon: "checkmark.circle")
        }
    }

    private var formatChoices: some View {
        HStack(spacing: 8) {
            Text(L.t("export.format")).font(.subheadline.weight(.semibold))
            Spacer()
            ForEach(ExportFormat.allCases) { format in
                Button {
                    model.format = format
                } label: {
                    Text(format.title).font(.footnote.weight(.semibold))
                        .foregroundStyle(model.format == format ? Color.white : Theme.accent)
                        .padding(.horizontal, 11).frame(minHeight: 44)
                        .background(model.format == format ? Theme.accent : Theme.tint, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("export.format." + format.rawValue)
                .accessibilityAddTraits(model.format == format ? .isSelected : [])
            }
        }
        .card()
    }

    @ViewBuilder private var otherExports: some View {
        Action(title: L.t("export.files"), id: "export.files", symbol: "folder") {
            Task { await model.makeExport(current: isCurrent, destination: .files, includeBadge: false) }
        }.disabled(!canExport)
        Action(title: L.t("export.shareClean"), id: "export.share", symbol: "square.and.arrow.up") {
            Task { await model.makeExport(current: isCurrent, destination: .share, includeBadge: false) }
        }.disabled(!canExport)
    }

    private var badgePreview: some View {
        HStack(alignment: .center, spacing: 11) {
            if model.storeURL == nil {
                Text(L.t("share.qrPlaceholder")).font(.caption2)
                    .multilineTextAlignment(.center).frame(width: 65, height: 65)
                    .background(Theme.tint, in: RoundedRectangle(cornerRadius: 7))
            } else {
                Image(systemName: "qrcode").font(.title).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L.t("app.title")).font(.headline)
                Text(L.t("share.hashtag")).font(.footnote).foregroundStyle(Theme.accent)
            }
            Spacer()
        }
        .card()
    }
}

struct MilestoneView: View {
    @ObservedObject var model: AppModel
    var onBack: () -> Void
    @State private var includeBadge = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HeaderButton(title: L.t("action.back"), id: "milestone.back", symbol: "chevron.left", action: onBack)
                    PageHeading(title: L.t("milestone.title"), id: "milestone.title")
                }
                VStack(spacing: 12) {
                    Text(model.milestones.savedImages.formatted())
                        .font(.system(size: 85, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent)
                    Text(L.f("milestone.copies", model.milestones.savedImages))
                        .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    if includeBadge { Text(L.t("share.hashtag")).font(.footnote).foregroundStyle(Theme.accent) }
                }
                .padding(26)
                .frame(maxWidth: .infinity, minHeight: 235)
                .background(Theme.tint, in: RoundedRectangle(cornerRadius: 18))
                Toggle(L.t("share.includeBadge"), isOn: $includeBadge)
                    .accessibilityIdentifier("milestone.badge").card()
                Action(title: L.t("share.open"), id: "milestone.share", symbol: "square.and.arrow.up", primary: true) {
                    Task { await model.makeMilestone(destination: .share, includeBadge: includeBadge) }
                }
                Action(title: L.t("export.files"), id: "milestone.files", symbol: "folder") {
                    Task { await model.makeMilestone(destination: .files, includeBadge: includeBadge) }
                }
            }
            .padding(.horizontal, 19)
            .padding(.vertical, 10)
        }
        .disabled(model.writing)
    }
}
