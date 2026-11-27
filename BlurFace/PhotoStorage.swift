import Foundation
import Photos
import UniformTypeIdentifiers
import UIKit

enum PhotoInput {
    case picker(NSItemProvider)
    case file(URL)
    case sample(Fixture)
}

enum Fixture: String, CaseIterable {
    case street, land, doc, unavailable, scanFailure

    var detectorRegions: [RedactionRegion]? {
        switch self {
        case .street:
            return [(CGRect(x: 238, y: 94, width: 40, height: 42), RegionKind.face),
                    (CGRect(x: 144, y: 173, width: 54, height: 21), .plate),
                    (CGRect(x: 31, y: 73, width: 110, height: 25), .text)].map { rect, kind in
                let normalized = rect.applying(CGAffineTransform(scaleX: 1 / 344.0, y: 1 / 230.0))
                return RedactionRegion(box: RegionBox(normalized), kind: kind)
            }
        case .doc:
            return [RedactionRegion(box: RegionBox(CGRect(x: 0.29, y: 0.34, width: 0.42, height: 0.20)), kind: .text)]
        case .land: return []
        case .unavailable, .scanFailure: return nil
        }
    }

    var resource: String { self == .scanFailure ? "street" : rawValue }
}

actor PhotoStorage {
    struct Loaded {
        let source: URL
        let image: OpenedImage
        let scan: Result<[RedactionRegion], PhotoFailure>
    }

    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(Launch.isUITesting ? "blurface-tests" : "blurface-v1", isDirectory: true)
    private var pipeline: ImagePipeline?

    func prepare() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
        try ensureDirectory(root)
    }

    func clearInputs() {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("inputs", isDirectory: true))
    }

    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    func load(_ input: PhotoInput, retrySource: URL?) async throws -> Loaded {
        let source: URL
        if let retrySource {
            source = retrySource
        } else {
            let folder = root.appendingPathComponent("inputs", isDirectory: true)
            try ensureDirectory(folder)
            source = folder.appendingPathComponent(UUID().uuidString)
            do {
                switch input {
                case .picker(let provider): try await Self.copy(provider, to: source)
                case .file(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try Self.withCoordinatedRead(url) { try Self.copyFile($0, to: source) }
                case .sample(let fixture):
                    guard let file = Bundle.main.url(forResource: fixture.resource, withExtension: "png", subdirectory: nil),
                          fixture != .unavailable else { throw PhotoFailure.unavailable }
                    try Self.copyFile(file, to: source)
                }
            } catch {
                remove(source)
                throw PhotoFailure.classify(error, fallback: .unavailable)
            }
        }
        do {
            return try autoreleasepool {
                let opened = try engine.open(source)
                let scan: Result<[RedactionRegion], PhotoFailure>
                if case .sample(let fixture) = input {
                    if let regions = fixture.detectorRegions { scan = .success(regions) }
                    else { scan = .failure(.scan) }
                } else {
                    do { scan = .success(try PhotoDetector.detect(opened.preview)) }
                    catch { scan = .failure(.scan) }
                }
                return Loaded(source: source, image: opened, scan: scan)
            }
        } catch {
            remove(source)
            throw PhotoFailure.classify(error, fallback: .unsupported)
        }
    }

    func openPreview(_ url: URL) throws -> CGImage {
        try autoreleasepool { try engine.open(url).preview }
    }

    func preview(_ image: CGImage, regions: [RedactionRegion]) throws -> CGImage {
        try autoreleasepool { try engine.render(image, regions: regions) }
    }

    func export(_ source: URL, regions: [RedactionRegion], format: ExportFormat) throws -> URL {
        let destination = try outputURL(format)
        do {
            try autoreleasepool { try engine.export(source: source, regions: regions, format: format, to: destination) }
            try Self.protect(destination)
            return destination
        } catch {
            remove(destination)
            throw PhotoFailure.classify(error, fallback: .write)
        }
    }

    func shareCard(clean: URL?, count: Int, includeBadge: Bool, format: ExportFormat, storeURL: URL?) throws -> URL {
        let destination = try outputURL(format)
        do {
            try autoreleasepool {
                let image = try clean.map { try engine.open($0).preview }
                let card = try ShareArtwork.make(photo: image, count: count, includeBadge: includeBadge, storeURL: storeURL)
                try ImagePipeline.encodeClean(card, format: format, to: destination)
                try Self.protect(destination)
            }
            return destination
        } catch {
            remove(destination)
            throw PhotoFailure.classify(error, fallback: .write)
        }
    }

    func writePreset(_ code: String) throws -> URL {
        let folder = root.appendingPathComponent("exports", isDirectory: true)
        try ensureDirectory(folder)
        let file = folder.appendingPathComponent("PixelVeil-" + UUID().uuidString + ".txt")
        try Data(code.utf8).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return file
    }

    func readPreset(_ url: URL) throws -> RedactionPreset {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Self.withCoordinatedRead(url) { file in
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: PresetCode.maximumLength + 1),
                  let text = String(data: data, encoding: .utf8) else { throw PresetCode.Failure.invalid }
            return try PresetCode.decode(text)
        }
    }

    private static func withCoordinatedRead<T>(_ url: URL, _ read: @escaping (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges,
                                                         error: &coordinationError) { file in
            result = Result { try read(file) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw PhotoFailure.unavailable }
        return try result.get()
    }

    private var engine: ImagePipeline {
        if let pipeline { return pipeline }
        let value = ImagePipeline()
        pipeline = value
        return value
    }

    private func outputURL(_ format: ExportFormat) throws -> URL {
        let folder = root.appendingPathComponent("exports", isDirectory: true)
        try ensureDirectory(folder)
        let filename = "PixelVeil-" + String(UUID().uuidString.prefix(8)) + "." + format.rawValue
        return folder.appendingPathComponent(filename)
    }

    private func ensureDirectory(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = path
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: url.path)
    }

    private static func copyFile(_ url: URL, to destination: URL) throws {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        try Data().write(to: destination, options: [.completeFileProtectionUntilFirstUserAuthentication])
        let output = try FileHandle(forWritingTo: destination)
        do {
            while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty { try output.write(contentsOf: chunk) }
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
    }

    private static func copy(_ provider: NSItemProvider, to destination: URL) async throws {
        guard let type = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else { throw PhotoFailure.unsupported }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? PhotoFailure.unavailable)
                    return
                }
                do {
                    try copyFile(url, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum Album {
    static func save(_ file: URL) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard status == .authorized || status == .limited else { throw PhotoFailure.permission }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
            }
        } catch {
            throw PhotoFailure.classify(error, fallback: .write)
        }
    }
}
