import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import Vision

enum ExportFormat: String, CaseIterable, Identifiable {
    case jpg, png
    var id: Self { self }
    var type: UTType { self == .jpg ? .jpeg : .png }
    var title: String { L.t("format." + rawValue) }
}

enum PhotoFailure: Error {
    case unavailable, unsupported, insufficientSpace, scan, permission, write, metadata

    var key: String {
        switch self {
        case .unavailable: return "error.unavailable"
        case .unsupported: return "error.unsupported"
        case .insufficientSpace: return "error.space"
        case .scan: return "error.scan"
        case .permission: return "error.permission"
        case .write: return "error.write"
        case .metadata: return "error.metadata"
        }
    }

    static func classify(_ error: Error, fallback: PhotoFailure) -> PhotoFailure {
        if let failure = error as? PhotoFailure { return failure }
        let nsError = error as NSError
        if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError) ||
            (nsError.domain == NSPOSIXErrorDomain && nsError.code == 28) ||
            (nsError.domain == "PHPhotosErrorDomain" && nsError.code == PHPhotosError.Code.notEnoughSpace.rawValue) {
            return .insufficientSpace
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== nsError {
            return classify(underlying, fallback: fallback)
        }
        return fallback
    }
}

struct OpenedImage {
    let preview: CGImage
    let thumbnail: CGImage
    let layout: ImageLayout
}

struct ImagePipeline {
    let context = CIContext(options: [.cacheIntermediates: false])

    func open(_ url: URL) throws -> OpenedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw PhotoFailure.unsupported }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let layout = try Self.layout(of: source, at: index)
        let preview = try Self.uprightImage(source, at: index, maxEdge: 1440)
        let thumbnail = try Self.uprightImage(source, at: index, maxEdge: 150)
        return OpenedImage(preview: preview, thumbnail: thumbnail, layout: layout)
    }

    static func layout(of source: CGImageSource, at index: Int) throws -> ImageLayout {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw PhotoFailure.unsupported
        }
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let rotated = (5...8).contains(orientation)
        let result = ImageLayout(width: rotated ? height : width, height: rotated ? width : height,
                                 orientation: orientation)
        guard result.isValid else { throw PhotoFailure.unsupported }
        return result
    }

    static func uprightImage(_ source: CGImageSource, at index: Int, maxEdge: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw PhotoFailure.unsupported
        }
        return image
    }

    func render(_ image: CGImage, regions: [RedactionRegion]) throws -> CGImage {
        let original = CIImage(cgImage: image)
        let bounds = original.extent
        let applied = regions.filter(\.applied)
        if applied.isEmpty { return image }
        let weak = applied.filter { $0.rule.style == .blur || $0.rule.style == .mosaic }
        let strong = applied.filter { $0.rule.style == .solid || $0.rule.style == .sticker }
        var result = original
        for region in weak + strong {
            let rect = region.box.imageRect(in: bounds)
            guard !rect.isNull, !rect.isEmpty else { continue }
            let layer = try effect(original, rect: rect, rule: region.rule)
            result = layer.composited(over: result)
        }
        guard let rendered = context.createCGImage(result, from: bounds, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw PhotoFailure.write
        }
        return rendered
    }

    private func effect(_ original: CIImage, rect: CGRect, rule: RegionRule) throws -> CIImage {
        let dimension = min(rect.width, rect.height)
        let strength = CGFloat(rule.strength) / 100
        switch rule.style {
        case .solid:
            return block(rect, color: CIColor(red: 0.063, green: 0.149, blue: 0.208))
        case .sticker:
            return sticker(rect, variant: rule.sticker)
        case .mosaic:
            let filter = CIFilter.pixellate()
            filter.inputImage = original.clampedToExtent()
            filter.center = CGPoint(x: rect.midX, y: rect.midY)
            filter.scale = Float(max(3, dimension * (0.04 + strength * 0.34)))
            guard let image = filter.outputImage else { throw PhotoFailure.write }
            return image.cropped(to: rect)
        case .blur:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = original.clampedToExtent()
            filter.radius = Float(min(240, max(2, dimension * (0.025 + strength * 0.20))))
            guard let image = filter.outputImage else { throw PhotoFailure.write }
            return image.cropped(to: rect)
        }
    }

    private func block(_ rect: CGRect, color: CIColor) -> CIImage {
        CIImage(color: color).cropped(to: rect)
    }

    private func sticker(_ rect: CGRect, variant: Int) -> CIImage {
        let base = block(rect, color: CIColor(red: 0.04, green: 0.26, blue: 0.29))
        let unit = min(rect.width, rect.height) * 0.16
        let colors = [CIColor(red: 0.80, green: 0.96, blue: 0.90),
                      CIColor(red: 0.96, green: 0.81, blue: 0.49),
                      CIColor(red: 0.77, green: 0.90, blue: 0.99)]
        let columns = variant + 1
        return (0..<columns).reduce(base) { result, index in
            let dx = CGFloat(index) - CGFloat(columns - 1) / 2
            let tile = CGRect(x: rect.midX + dx * unit * 1.4 - unit / 2,
                              y: rect.midY - unit / 2, width: unit, height: unit)
            return block(tile, color: colors[variant]).composited(over: result)
        }
    }

    func export(source url: URL, regions: [RedactionRegion], format: ExportFormat, to destination: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw PhotoFailure.unavailable }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let layout = try Self.layout(of: source, at: index)
        let image = try Self.uprightImage(source, at: index, maxEdge: max(layout.width, layout.height))
        guard image.width == layout.width && image.height == layout.height else { throw PhotoFailure.write }
        try Self.encodeClean(try render(image, regions: regions), format: format, to: destination)
    }

    static func encodeClean(_ image: CGImage, format: ExportFormat, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil)
        else { throw PhotoFailure.write }
        var options: [CFString: Any] = [:]
        if format == .jpg {
            options[kCGImageDestinationLossyCompressionQuality] = 0.94
            options[kCGImageDestinationEmbedThumbnail] = false
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoFailure.write }
        try verifyClean(url, format: format, width: image.width, height: image.height)
    }

    static func verifyClean(_ url: URL, format: ExportFormat, width: Int, height: Int) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height else { throw PhotoFailure.metadata }
        let privateGroups: [CFString] = [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                                         kCGImagePropertyExifAuxDictionary, "{MakerApple}" as CFString,
                                         "{XMP}" as CFString, "{Thumbnail}" as CFString]
        guard privateGroups.allSatisfy({ properties[$0] == nil }) else { throw PhotoFailure.metadata }
        let forbiddenExif = ["DateTimeOriginal", "DateTimeDigitized", "OffsetTime", "OffsetTimeOriginal",
                             "OffsetTimeDigitized", "SubsecTime", "SubsecTimeOriginal", "SubsecTimeDigitized",
                             "LensSpecification", "LensMake", "LensModel", "LensSerialNumber", "BodySerialNumber",
                             "CameraOwnerName", "UserComment", "ImageUniqueID", "MakerNote"]
        let forbiddenTiff = ["Make", "Model", "Software", "DateTime", "Artist", "Copyright", "ImageDescription"]
        for (key, forbidden) in [(kCGImagePropertyExifDictionary, forbiddenExif),
                                 (kCGImagePropertyTIFFDictionary, forbiddenTiff)] {
            let dictionary = properties[key] as? [String: Any] ?? [:]
            guard forbidden.allSatisfy({ dictionary[$0] == nil }) else { throw PhotoFailure.metadata }
        }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
            let privateNamespaces = ["http://ns.adobe.com/xap/1.0/", "http://ns.adobe.com/xap/1.0/mm/",
                                     "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"]
            guard !tags.contains(where: { tag in
                guard let namespace = CGImageMetadataTagCopyNamespace(tag) else { return false }
                return privateNamespaces.contains(namespace as String)
            }) else { throw PhotoFailure.metadata }
        }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        switch format {
        case .jpg: try verifyJPEGThumbnails(data)
        case .png: try verifyPNGThumbnails(data)
        }
    }

    private static func verifyJPEGThumbnails(_ data: Data) throws {
        guard data.starts(with: [0xFF, 0xD8]) else { throw PhotoFailure.metadata }
        var offset = 2
        while offset < data.count {
            guard data[offset] == 0xFF else { throw PhotoFailure.metadata }
            repeat { offset += 1 } while offset < data.count && data[offset] == 0xFF
            guard offset < data.count else { throw PhotoFailure.metadata }
            let marker = data[offset]
            offset += 1
            if marker == 0xDA { return }
            guard data.count - offset >= 2 else { throw PhotoFailure.metadata }
            let length = Int(data[offset]) * 256 + Int(data[offset + 1])
            guard length >= 2, length <= data.count - offset else { throw PhotoFailure.metadata }
            let segment = data[(offset + 2)..<(offset + length)]
            if marker == 0xE0 && segment.starts(with: "JFIF\0".utf8) {
                let start = segment.startIndex
                guard segment.count >= 14, segment[start + 12] == 0, segment[start + 13] == 0 else {
                    throw PhotoFailure.metadata
                }
            }
            if marker == 0xE0 && segment.starts(with: "JFXX\0".utf8) { throw PhotoFailure.metadata }
            if marker == 0xE1 && segment.starts(with: "Exif\0\0".utf8) {
                try verifyEXIFThumbnail(segment.dropFirst(6))
            }
            offset += length
        }
        throw PhotoFailure.metadata
    }

    private static func verifyPNGThumbnails(_ data: Data) throws {
        guard data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            throw PhotoFailure.metadata
        }
        var offset = 8
        while data.count - offset >= 12 {
            let encodedLength = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            let length = Int(UInt32(bigEndian: encodedLength))
            guard length <= data.count - offset - 12 else { throw PhotoFailure.metadata }
            let type = data[(offset + 4)..<(offset + 8)]
            if type.elementsEqual("IEND".utf8) { return }
            if type.elementsEqual("eXIf".utf8) {
                try verifyEXIFThumbnail(data[(offset + 8)..<(offset + 8 + length)])
            }
            offset += length + 12
        }
        throw PhotoFailure.metadata
    }

    private static func verifyEXIFThumbnail(_ tiff: Data) throws {
        try tiff.withUnsafeBytes { bytes in
            guard bytes.count >= 8 else { throw PhotoFailure.metadata }
            let littleEndian = bytes[0] == 0x49 && bytes[1] == 0x49
            guard littleEndian || (bytes[0] == 0x4D && bytes[1] == 0x4D) else { throw PhotoFailure.metadata }
            let version = bytes.loadUnaligned(fromByteOffset: 2, as: UInt16.self)
            let offset = bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let firstIFD = Int(littleEndian ? UInt32(littleEndian: offset) : UInt32(bigEndian: offset))
            guard (littleEndian ? UInt16(littleEndian: version) : UInt16(bigEndian: version)) == 42,
                  firstIFD >= 8, firstIFD <= bytes.count - 2 else { throw PhotoFailure.metadata }
            let entries = bytes.loadUnaligned(fromByteOffset: firstIFD, as: UInt16.self)
            let entryCount = Int(littleEndian ? UInt16(littleEndian: entries) : UInt16(bigEndian: entries))
            let nextIFD = firstIFD + 2 + 12 * entryCount
            guard nextIFD <= bytes.count - 4, bytes.loadUnaligned(fromByteOffset: nextIFD, as: UInt32.self) == 0 else {
                throw PhotoFailure.metadata
            }
        }
    }
}

enum PhotoDetector {
    static func detect(_ image: CGImage) throws -> [RedactionRegion] {
        let faces = VNDetectFaceRectanglesRequest()
        let words = VNRecognizeTextRequest()
        words.recognitionLevel = .accurate
        words.automaticallyDetectsLanguage = true
        words.usesLanguageCorrection = false
        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumAspectRatio = 0.12
        rectangles.maximumAspectRatio = 0.75
        rectangles.minimumSize = 0.04
        rectangles.minimumConfidence = 0.25
        rectangles.maximumObservations = 30
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do {
            try handler.perform([faces, words, rectangles])
        } catch {
            throw PhotoFailure.scan
        }
        let faceRegions: [RedactionRegion] = (faces.results ?? []).compactMap { face in
            RegionBox.vision(face.boundingBox, padding: 0.18).map { .init(box: $0, kind: .face) }
        }
        let pixelAspect = CGFloat(image.width) / CGFloat(image.height)
        let textRegions: [RedactionRegion] = (words.results ?? []).compactMap { observation in
            let box = observation.boundingBox
            let value = observation.topCandidates(1).first?.string ?? ""
            if isPlateText(value, imageAspect: pixelAspect, box: box),
               let plate = matchingPlate(in: rectangles.results ?? [], textBox: box, imageAspect: pixelAspect) {
                return RegionBox.vision(plate.union(box), padding: 0.12).map { .init(box: $0, kind: .plate) }
            }
            return RegionBox.vision(box, padding: 0.09).map { .init(box: $0, kind: .text) }
        }
        return faceRegions + textRegions
    }

    private static func matchingPlate(in rectangles: [VNRectangleObservation], textBox: CGRect,
                                      imageAspect: CGFloat) -> CGRect? {
        rectangles.map(\.boundingBox).filter { rect in
            let aspect = rect.width * imageAspect / max(0.001, rect.height)
            let expanded = rect.insetBy(dx: -rect.width * 0.12, dy: -rect.height * 0.18)
            return (1.35...7.5).contains(aspect) && rect.width <= textBox.width * 2.8 &&
                rect.height <= textBox.height * 3.5 && expanded.contains(textBox)
        }.min { first, second in
            first.width * first.height < second.width * second.height
        }
    }

    static func isPlateText(_ text: String, imageAspect: CGFloat, box: CGRect) -> Bool {
        let aspect = box.width * imageAspect / max(0.001, box.height)
        guard (1.3...11).contains(aspect) else { return false }
        let token = text.uppercased().replacingOccurrences(of: "[· .–-]", with: "", options: .regularExpression)
        guard (4...10).contains(token.count),
              token.range(of: "^[A-ZÄÖÜ0-9\\p{Han}]+$", options: .regularExpression) != nil,
              token.unicodeScalars.contains(where: CharacterSet.letters.contains),
              token.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) else { return false }
        return true
    }
}
