import Foundation
import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

final class CoreTests: XCTestCase {
    func testCandidateConfirmationIsInvalidatedByEditAndUndo() throws {
        let box = try XCTUnwrap(RegionBox.vision(CGRect(x: 0.2, y: 0.15, width: 0.3, height: 0.2)))
        XCTAssertEqual(box.y, 0.65, accuracy: 0.0001)
        XCTAssertEqual(box.imageRect(in: CGRect(x: 0, y: 0, width: 100, height: 100)).minY, 15, accuracy: 1)
        var edit = RedactionEdit(regions: [RedactionRegion(box: box, kind: .plate)])
        XCTAssertFalse(edit.confirm())
        edit.applyAll()
        XCTAssertEqual(edit.regions[0].rule.style, .solid)
        XCTAssertTrue(edit.confirm())
        edit.update { $0.removeAll() }
        XCTAssertFalse(edit.confirmed)
        edit.undo()
        XCTAssertFalse(edit.confirmed)
        XCTAssertEqual(edit.regions.count, 1)
        edit.undo()
        XCTAssertTrue(edit.hasPending)
    }

    func testPresetPayloadExcludesImageAndIdentifiersAndRejectsInvalidInputs() throws {
        let box = RegionBox(CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.15))
        let manual = RedactionRegion(box: box, kind: .manual, origin: .manual, applied: true)
        let detected = RedactionRegion(box: box, kind: .face)
        let layout = ImageLayout(width: 840, height: 600, orientation: 6)
        let preset = RedactionPreset.from([manual, detected], positionIDs: [manual.id, detected.id], layout: layout)
        let code = try PresetCode.encode(preset)
        let decoded = try PresetCode.decode("\n" + code + "\n")
        XCTAssertEqual(decoded.rules, preset.rules)
        XCTAssertEqual(decoded.positions.count, 1)
        XCTAssertEqual(decoded.positions.first?.box, box)
        XCTAssertEqual(decoded.layout, layout)
        XCTAssertNotEqual(decoded.id, preset.id)
        XCTAssertThrowsError(try PresetCode.decode("PX2:" + String(code.dropFirst(4))))
        XCTAssertThrowsError(try PresetCode.decode("PX1:%bad"))
        XCTAssertThrowsError(try PresetCode.decode("PX1:" + String(repeating: "a", count: PresetCode.maximumLength)))
        let payload = Data("{\"version\":2,\"rules\":[],\"positions\":[]}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        XCTAssertThrowsError(try PresetCode.decode("PX1:" + payload))
        let invalid = RedactionPreset(rules: [RegionRule(kind: .face, style: .mosaic, strength: 101)], layout: nil)
        XCTAssertThrowsError(try PresetCode.encode(invalid))
    }

    func testPlateCandidateRequiresLettersDigitsAndShape() {
        let line = CGRect(x: 0.1, y: 0.3, width: 0.35, height: 0.11)
        XCTAssertTrue(PhotoDetector.isPlateText("B AB 1234", imageAspect: 1, box: line))
        XCTAssertTrue(PhotoDetector.isPlateText("7ABC123", imageAspect: 1, box: line))
        XCTAssertFalse(PhotoDetector.isPlateText("GARAGE", imageAspect: 1, box: line))
        XCTAssertFalse(PhotoDetector.isPlateText("ABCD123", imageAspect: 1, box: CGRect(x: 0, y: 0, width: 0.1, height: 0.4)))
    }

    func testEightEXIFOrientationsMapToUprightDimensionsAndTopLeft() throws {
        try withScratch { folder in
            let colors = [UIColor.red, .green, .blue, .yellow]
            let image = try XCTUnwrap(draw(width: 80, height: 54) { context in
                for (index, color) in colors.enumerated() {
                    color.setFill()
                    context.fill(CGRect(x: (index % 2) * 40, y: (index / 2) * 27, width: 40, height: 27))
                }
            })
            let samples = [[255, 0, 0], [0, 255, 0], [255, 255, 0], [0, 0, 255],
                           [255, 0, 0], [0, 0, 255], [255, 255, 0], [0, 255, 0]]
            for orientation in 1...8 {
                let url = folder.appendingPathComponent("\(orientation).jpg")
                try writeJPEG(image, at: url, properties: [kCGImagePropertyOrientation: orientation])
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let layout = try ImagePipeline.layout(of: source, at: 0)
                let upright = try ImagePipeline.uprightImage(source, at: 0, maxEdge: 80)
                XCTAssertEqual(layout.orientation, UInt32(orientation))
                XCTAssertEqual(upright.width, orientation > 4 ? 54 : 80)
                XCTAssertEqual(upright.height, orientation > 4 ? 80 : 54)
                let actual = try pixel(upright, x: 5, y: 5).map(Int.init)
                for (channel, expected) in zip(actual.prefix(3), samples[orientation - 1]) {
                    XCTAssertEqual(Double(channel), Double(expected), accuracy: 26, "EXIF orientation \(orientation)")
                }
            }
        }
    }

    func testOpaqueCoverAndStickerStayOpaqueWithOverlappingBlur() throws {
        let image = try XCTUnwrap(draw(width: 100, height: 100) { context in
            UIColor.red.withAlphaComponent(0.15).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        })
        let box = RegionBox(CGRect(x: 0.22, y: 0.15, width: 0.28, height: 0.30))
        var blur = RedactionRegion(box: box, kind: .face, applied: true)
        blur.rule.style = .blur
        let pipe = ImagePipeline()
        for style in [RedactionStyle.solid, .sticker] {
            var cover = RedactionRegion(box: box, kind: .text, applied: true)
            cover.rule.style = style
            let result = try pipe.render(image, regions: [cover, blur])
            XCTAssertEqual(try pixel(result, x: 27, y: 20)[3], 255)
            XCTAssertLessThan(try pixel(result, x: 27, y: 20)[0], 90)
            XCTAssertLessThan(try pixel(result, x: 70, y: 20)[3], 80)
        }
    }

    func testExportJPGAndPNGStripCaptureMetadataAtOriginalPixelSize() throws {
        try withScratch { folder in
            let image = try XCTUnwrap(draw(width: 120, height: 80) { context in
                UIColor.orange.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            })
            let source = folder.appendingPathComponent("source.jpg")
            try writeJPEG(image, at: source, properties: [
                kCGImagePropertyGPSDictionary: ["Latitude": 48.8, "LatitudeRef": "N", "Longitude": 2.3, "LongitudeRef": "E"],
                kCGImagePropertyExifDictionary: ["DateTimeOriginal": "2024:01:01 10:11:00", "LensModel": "Test Lens"],
                kCGImagePropertyTIFFDictionary: ["Make": "Test camera", "Model": "Test 1"],
                kCGImagePropertyIPTCDictionary: ["Keywords": ["private"], "City": "Somewhere"]
            ])
            let original = try properties(source)
            XCTAssertNotNil(original[kCGImagePropertyGPSDictionary])
            let masking = RedactionRegion(box: RegionBox(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)),
                                          kind: .plate, applied: true)
            let engine = ImagePipeline()
            for format in ExportFormat.allCases {
                let file = folder.appendingPathComponent("clean." + format.rawValue)
                try engine.export(source: source, regions: [masking], format: format, to: file)
                let reread = try properties(file)
                XCTAssertEqual(reread[kCGImagePropertyPixelWidth] as? Int, 120)
                XCTAssertEqual(reread[kCGImagePropertyPixelHeight] as? Int, 80)
                XCTAssertNil(reread[kCGImagePropertyGPSDictionary])
                XCTAssertNil(reread[kCGImagePropertyIPTCDictionary])
                let exif = reread[kCGImagePropertyExifDictionary] as? [String: Any]
                XCTAssertNil(exif?["DateTimeOriginal"])
                XCTAssertNil(exif?["LensModel"])
                XCTAssertNil((reread[kCGImagePropertyTIFFDictionary] as? [String: Any])?["Make"])
            }
        }
    }

    func testVerificationRejectsEmbeddedEXIFThumbnail() throws {
        try withScratch { folder in
            let image = try XCTUnwrap(draw(width: 120, height: 80) { context in
                UIColor.orange.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            })
            let thumbnail = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: 8, height: 8)))
            let thumbnailURL = folder.appendingPathComponent("thumbnail.jpg")
            try writeJPEG(thumbnail, at: thumbnailURL, properties: [:])
            let thumbnailData = try Data(contentsOf: thumbnailURL)

            var exif = Data("Exif\0\0".utf8)
            exif.append(contentsOf: [
                0x49, 0x49, 42, 0, 8, 0, 0, 0,
                0, 0, 14, 0, 0, 0,
                3, 0,
                3, 1, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0,
                1, 2, 4, 0, 1, 0, 0, 0, 56, 0, 0, 0,
                2, 2, 4, 0, 1, 0, 0, 0
            ])
            var thumbnailLength = UInt32(thumbnailData.count).littleEndian
            withUnsafeBytes(of: &thumbnailLength) { exif.append(contentsOf: $0) }
            exif.append(contentsOf: [0, 0, 0, 0])
            exif.append(thumbnailData)

            let output = folder.appendingPathComponent("output.jpg")
            try ImagePipeline.encodeClean(image, format: .jpg, to: output)
            var jpeg = try Data(contentsOf: output)
            let length = try XCTUnwrap(UInt16(exactly: exif.count + 2))
            var app1 = Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(truncatingIfNeeded: length)])
            app1.append(exif)
            let insertion = jpeg.starts(with: [0xFF, 0xD8, 0xFF, 0xE0])
                ? 4 + Int(jpeg[4]) * 256 + Int(jpeg[5]) : 2
            jpeg.insert(contentsOf: app1, at: insertion)
            try jpeg.write(to: output)
            let reread = try properties(output)
            XCTAssertEqual(reread[kCGImagePropertyPixelWidth] as? Int, 120)
            XCTAssertEqual(reread[kCGImagePropertyPixelHeight] as? Int, 80)
            XCTAssertThrowsError(try ImagePipeline.verifyClean(output, format: .jpg, width: 120, height: 80)) {
                guard case .metadata? = $0 as? PhotoFailure else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

    func testCoreReviewRequiresThreeActionsOnTwoLocalDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23)))
        let nextDay = firstDay.addingTimeInterval(2 * 3600)
        let empty = try JSONDecoder().decode(CoreReviewProgress.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isEligible)
        var progress = CoreReviewProgress.recording(empty, at: firstDay, calendar: calendar)
        var twoDays = progress
        twoDays.record(at: nextDay, calendar: calendar)
        XCTAssertFalse(twoDays.isEligible)
        progress.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(progress.isEligible)

        var sameDay = progress
        sameDay.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(sameDay.isEligible)

        let data = try JSONEncoder().encode(progress)
        progress = try JSONDecoder().decode(CoreReviewProgress.self, from: data)
        progress.record(at: nextDay, calendar: calendar)
        XCTAssertTrue(progress.isEligible)
    }

    func testMilestoneAndReviewCadence() {
        let day: TimeInterval = 86_400
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        var milestones = Milestones()
        milestones.recordSave(images: 9, at: start)
        XCTAssertFalse(milestones.hasCard)
        milestones.recordSave(images: 1, at: start)
        XCTAssertTrue(milestones.hasCard)
        milestones.recordSave(images: 1, at: start)
        XCTAssertFalse(milestones.registerReviewIfEligible(at: start))
        milestones.recordSave(images: 1, at: start + day)
        XCTAssertTrue(milestones.registerReviewIfEligible(at: start + day))
        XCTAssertFalse(milestones.registerReviewIfEligible(at: start + 89 * day))
        XCTAssertTrue(milestones.registerReviewIfEligible(at: start + 92 * day))
        XCTAssertFalse(milestones.registerReviewIfEligible(at: start + 200 * day))
        XCTAssertTrue(milestones.registerReviewIfEligible(at: start + 370 * day))
    }

    func testQRReadbackAndMilestoneSize() throws {
        XCTAssertNil(ShareArtwork.storeURL(appID: nil))
        XCTAssertNil(ShareArtwork.storeURL(appID: ""))
        XCTAssertNil(ShareArtwork.storeURL(appID: "https://example.com/photo"))
        let url = try XCTUnwrap(ShareArtwork.storeURL(appID: "123456789"))
        XCTAssertEqual(url.absoluteString, "https://apps.apple.com/app/id123456789")
        let card = try ShareArtwork.make(photo: nil, count: 10, includeBadge: true, storeURL: url)
        XCTAssertEqual(card.width, 1080)
        XCTAssertEqual(card.height, 1350)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let detected = detector.features(in: CIImage(cgImage: card)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertTrue(detected.contains(url.absoluteString))
    }

    func testPhotoShareBadgeAddsQRCodeBelowTheCleanImage() throws {
        let photo = try XCTUnwrap(draw(width: 80, height: 60) { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        })
        let url = try XCTUnwrap(ShareArtwork.storeURL(appID: "123456789"))
        let clean = try ShareArtwork.make(photo: photo, count: 0, includeBadge: false, storeURL: url)
        let branded = try ShareArtwork.make(photo: photo, count: 0, includeBadge: true, storeURL: url)
        XCTAssertEqual(clean.width, branded.width)
        XCTAssertEqual(branded.height, clean.height + 215)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        XCTAssertTrue(detector.features(in: CIImage(cgImage: clean)).isEmpty)
        let urls = detector.features(in: CIImage(cgImage: branded)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(urls, [url.absoluteString])
    }

    func testHostlessLocalization() {
        XCTAssertEqual(L.t("editor.applyAll"), "Redact all")
        XCTAssertFalse(L.f("home.limit", 3).contains("lld"))
    }

    private func withScratch(_ block: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try block(folder)
    }

    private func draw(width: Int, height: Int, painter: (UIGraphicsImageRendererContext) -> Void) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .image { painter($0) }.cgImage
    }

    private func writeJPEG(_ image: CGImage, at url: URL, properties: [CFString: Any]) throws {
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(output))
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
