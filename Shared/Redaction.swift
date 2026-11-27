import Foundation
import CoreGraphics

enum RegionKind: String, Codable, CaseIterable, Hashable {
    case face, plate, text, manual

    var title: String { L.t("region." + rawValue) }
    var defaultStyle: RedactionStyle { self == .face ? .mosaic : .solid }
}

enum RedactionStyle: String, Codable, CaseIterable, Hashable {
    case mosaic, blur, solid, sticker

    var title: String { L.t("style." + rawValue) }
}

struct RegionBox: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = Double(rect.minX)
        y = Double(rect.minY)
        width = Double(rect.width)
        height = Double(rect.height)
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) &&
        x >= 0 && y >= 0 && width >= 0.005 && height >= 0.005 &&
        x + width <= 1.000_000_001 && y + height <= 1.000_000_001
    }

    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func vision(_ box: CGRect, padding: CGFloat = 0) -> RegionBox? {
        let upright = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        return clipped(upright.insetBy(dx: -box.width * padding, dy: -box.height * padding))
    }

    static func clipped(_ rect: CGRect) -> RegionBox? {
        let clipped = rect.intersection(unit)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let box = RegionBox(clipped)
        return box.isValid ? box : nil
    }

    func imageRect(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + x * bounds.width, y: bounds.minY + (1 - y - height) * bounds.height,
               width: width * bounds.width, height: height * bounds.height)
            .integral.intersection(bounds)
    }
}

struct RegionRule: Codable, Equatable, Hashable, Identifiable {
    var kind: RegionKind
    var style: RedactionStyle
    var strength: Int
    var sticker = 0
    var id: RegionKind { kind }
    var isValid: Bool { (1...100).contains(strength) && (0...2).contains(sticker) }

    static func standard(_ kind: RegionKind) -> RegionRule {
        RegionRule(kind: kind, style: kind.defaultStyle, strength: 90)
    }
}

struct RedactionRegion: Identifiable, Equatable {
    enum Origin: Equatable { case detected, manual, template }

    let id = UUID()
    var box: RegionBox
    var rule: RegionRule
    let origin: Origin
    var applied: Bool

    init(box: RegionBox, kind: RegionKind, origin: Origin = .detected, applied: Bool = false) {
        self.box = box
        rule = .standard(kind)
        self.origin = origin
        self.applied = applied
    }
}

struct RedactionEdit: Equatable {
    private(set) var regions: [RedactionRegion] = []
    private(set) var confirmed = false
    private var history: [[RedactionRegion]] = []
    var hasPending: Bool { regions.contains { !$0.applied } }
    var canUndo: Bool { !history.isEmpty }

    init(regions: [RedactionRegion] = []) { self.regions = regions }

    mutating func update(_ change: (inout [RedactionRegion]) -> Void) {
        var updated = regions
        change(&updated)
        guard updated != regions else { return }
        if history.count >= 30 { history.removeFirst() }
        history.append(regions)
        regions = updated
        confirmed = false
    }

    mutating func applyAll() {
        update { regions in
            for index in regions.indices { regions[index].applied = true }
        }
    }

    mutating func undo() {
        guard let previous = history.popLast() else { return }
        regions = previous
        confirmed = false
    }

    @discardableResult mutating func confirm() -> Bool {
        guard !hasPending else { return false }
        confirmed = true
        return true
    }

    mutating func resetConfirmation() { confirmed = false }
}

struct ImageLayout: Codable, Equatable {
    var width: Int
    var height: Int
    var orientation: UInt32

    var isValid: Bool {
        (1...100_000).contains(width) && (1...100_000).contains(height) && (1...8).contains(orientation)
    }
}

struct PresetPosition: Codable, Equatable, Hashable {
    var box: RegionBox
    var rule: RegionRule
}

struct RedactionPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var rules: [RegionRule]
    var positions: [PresetPosition] = []
    var layout: ImageLayout?

    var isValid: Bool {
        (1...RegionKind.allCases.count).contains(rules.count) &&
        Set(rules.map(\.kind)).count == rules.count && rules.allSatisfy(\.isValid) &&
        positions.count <= 24 &&
        positions.allSatisfy { $0.box.isValid && $0.rule.isValid && $0.rule.kind == .manual } &&
        (positions.isEmpty ? layout == nil : layout?.isValid == true)
    }

    func rule(for kind: RegionKind) -> RegionRule { rules.first { $0.kind == kind } ?? .standard(kind) }

    static func from(_ regions: [RedactionRegion], positionIDs: Set<UUID>, layout: ImageLayout) -> RedactionPreset {
        let rules = RegionKind.allCases.map { kind in
            regions.last { $0.rule.kind == kind }?.rule ?? .standard(kind)
        }
        let positions = regions.filter { $0.origin != .detected && positionIDs.contains($0.id) }
            .prefix(24).map { PresetPosition(box: $0.box, rule: $0.rule) }
        return RedactionPreset(rules: rules, positions: positions, layout: positions.isEmpty ? nil : layout)
    }
}

enum PresetCode {
    enum Failure: Error { case invalid }
    private struct Payload: Codable {
        let version: Int
        let rules: [RegionRule]
        let positions: [PresetPosition]
        let layout: ImageLayout?
    }

    static let maximumLength = 12_000
    private static let prefix = "PX1:"

    static func encode(_ preset: RedactionPreset) throws -> String {
        guard preset.isValid else { throw Failure.invalid }
        let payload = Payload(version: 1, rules: preset.rules, positions: preset.positions, layout: preset.layout)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let token = try encoder.encode(payload).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard token.utf8.count + prefix.utf8.count <= maximumLength else { throw Failure.invalid }
        return prefix + token
    }

    static func decode(_ text: String) throws -> RedactionPreset {
        guard text.utf8.count <= maximumLength else { throw Failure.invalid }
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix(prefix) else { throw Failure.invalid }
        let token = String(code.dropFirst(prefix.count))
        guard !token.isEmpty, token.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
        }) else { throw Failure.invalid }
        let standard = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.version == 1 else {
            throw Failure.invalid
        }
        let preset = RedactionPreset(rules: payload.rules, positions: payload.positions, layout: payload.layout)
        guard preset.isValid else { throw Failure.invalid }
        return preset
    }
}
