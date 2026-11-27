import SwiftUI

enum Theme {
    static let paper = Color(red: 0.945, green: 0.961, blue: 0.973)
    static let ink = Color(red: 0.063, green: 0.149, blue: 0.208)
    static let accent = Color(red: 0, green: 0.408, blue: 0.459)
    static let muted = Color(red: 0.278, green: 0.376, blue: 0.427)
    static let line = Color(red: 0.847, green: 0.898, blue: 0.914)
    static let tint = Color(red: 0.882, green: 0.945, blue: 0.941)
    static let warm = Color(red: 1, green: 0.949, blue: 0.863)
    static let warn = Color(red: 0.475, green: 0.267, blue: 0.055)
}

struct Action: View {
    var title: String
    let id: String
    var symbol: String?
    var primary = false
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                Text(title).multilineTextAlignment(.center)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(primary ? Color.white : Theme.accent)
            .frame(maxWidth: .infinity, minHeight: primary ? 48 : 44)
            .padding(.horizontal, 8)
            .background(primary ? Theme.accent : Color.white, in: RoundedRectangle(cornerRadius: 13))
            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(primary ? Theme.accent : Theme.line) }
            .opacity(enabled ? 1 : 0.50)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct HeaderButton: View {
    var title: String
    let id: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(.white, in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}

struct PageHeading: View {
    let title: String
    var subtitle: String?
    var id: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title.bold())
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(id ?? "")
            if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(Theme.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Notice: View {
    var text: String
    var warning = false
    var icon: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let icon { Image(systemName: icon).accessibilityHidden(true) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(warning ? Theme.warn : Theme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(warning ? Theme.warm : Theme.tint, in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .contain)
    }
}

struct StatusTag: View {
    let text: String
    var warning = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(warning ? Theme.warn : Theme.accent)
            .background(warning ? Theme.warm : Theme.tint, in: Capsule())
    }
}

extension View {
    func card() -> some View {
        padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 19))
            .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(Theme.line) }
    }
}
