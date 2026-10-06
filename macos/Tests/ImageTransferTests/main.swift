import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum ImageTransferTests {
    static func main() {
        var tests: [(String, () throws -> Void)] = [
            ("PNG import and category copies retain original ICC and metadata bytes", testPNGImportAndCopyPreserveOriginalBytes),
            ("Changed source does not reuse or overwrite a previous drag export", testChangedSourceKeepsPreviousExport),
            ("Interleaved providers return their own exact PNG and file URL", testInterleavedProvidersKeepImageIdentity)
        ]
        #if IMAGE_TRANSFER_SNAPSHOT_API
        tests.append(("Explicit rendered-image snapshot stays authoritative", testExplicitSnapshotIsAuthoritative))
        #else
        print("BASELINE: snapshot API test unavailable in the old implementation; not counted as passed")
        #endif

        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS: \(name)")
            } catch {
                failures += 1
                print("FAIL: \(name): \(error)")
            }
        }
        print("Image transfer regression: \(tests.count - failures)/\(tests.count) passed")
        if failures > 0 { exit(1) }
    }

    private static func testPNGImportAndCopyPreserveOriginalBytes() throws {
        try withTemporaryStore { directory, store in
            let original = try pngFixture(red: 0.82, green: 0.12, blue: 0.36, marker: "original-import")
            let source = directory.appendingPathComponent("original.png")
            try original.write(to: source)
            let path = try store.storeImageFile(source)
            let storedURL = try require(store.managedImageURL(relativePath: path), "missing imported PNG URL")
            try check(try Data(contentsOf: storedURL) == original, "file import re-encoded the original PNG")

            let directPath = try store.storeImageData(original)
            let directURL = try require(store.managedImageURL(relativePath: directPath), "missing raw PNG URL")
            try check(try Data(contentsOf: directURL) == original, "raw PNG import changed bytes")

            let model = BoardModel(store: store, monitorsClipboard: false)
            model.addImageFiles([source], to: .inbox)
            try waitUntil { model.orderedItems(in: .inbox).count == 1 }
            let item = try require(model.orderedItems(in: .inbox).first, "missing model-imported PNG")
            let modelURL = try require(model.imageURL(for: item), "missing model-imported PNG URL")
            try check(try Data(contentsOf: modelURL) == original, "model file import changed bytes")
            try check(model.copyImage(item.id, to: .reference), "category copy was rejected")
            let copy = try require(model.orderedItems(in: .reference).first, "missing copied PNG")
            let copyURL = try require(model.imageURL(for: copy), "missing copied PNG URL")
            try check(copy.id != item.id && copyURL != modelURL, "category copy reused source identity or path")
            try check(try Data(contentsOf: copyURL) == original, "category copy re-encoded ICC or metadata")
            try check(try Data(contentsOf: source) == original, "original external PNG was changed")
        }
    }

    private static func testChangedSourceKeepsPreviousExport() throws {
        try withTemporaryStore { _, store in
            let firstPNG = try pngFixture(red: 0.92, green: 0.1, blue: 0.2, marker: "first-export")
            let secondPNG = try pngFixture(red: 0.1, green: 0.22, blue: 0.93, marker: "second-export")
            let id = UUID()
            let path = try store.storeImageData(firstPNG, id: id)
            let managedURL = try require(store.managedImageURL(relativePath: path), "missing managed image")
            let firstExport = try store.exportImageForDrag(relativePath: path)
            let firstExportBytes = try Data(contentsOf: firstExport)
            // This isolated overwrite recreates a stale export; no user data is involved.
            try secondPNG.write(to: managedURL, options: .atomic)
            let secondExport = try store.exportImageForDrag(relativePath: path)
            try check(secondExport != firstExport, "new source reused stale export URL")
            try check(try Data(contentsOf: secondExport) == secondPNG, "new drag export does not match current source")
            try check(try Data(contentsOf: firstExport) == firstExportBytes, "old external reference was overwritten")
            try check(try store.exportImageForDrag(relativePath: path) == secondExport, "same current bytes generated an unstable export URL")
            try check(store.isImageDragURL(secondExport, relativePath: path), "current versioned export rejected for category copying")
            try check(!store.isImageDragURL(firstExport, relativePath: path), "stale export accepted as current category image")
        }
    }

    private static func testInterleavedProvidersKeepImageIdentity() throws {
        try withTemporaryStore { _, store in
            let firstPNG = try pngFixture(red: 0.88, green: 0.17, blue: 0.29, marker: "provider-a")
            let secondPNG = try pngFixture(red: 0.12, green: 0.83, blue: 0.47, marker: "provider-b")
            let firstID = UUID()
            let secondID = UUID()
            let firstPath = try store.storeImageData(firstPNG, id: firstID)
            let secondPath = try store.storeImageData(secondPNG, id: secondID)
            let firstItem = BoardItem(id: firstID, kind: .image, category: .inbox, order: 0, imageRelativePath: firstPath)
            let secondItem = BoardItem(id: secondID, kind: .image, category: .inbox, order: 1, imageRelativePath: secondPath)
            try store.saveBoard([firstItem, secondItem])
            let model = BoardModel(store: store, monitorsClipboard: false)
            let firstProvider = model.dragProvider(for: firstItem)
            let secondProvider = model.dragProvider(for: secondItem)
            try check(model.draggedImageID(from: firstProvider) == firstID, "first provider lost source UUID")
            try check(model.draggedImageID(from: secondProvider) == secondID, "second provider lost source UUID")
            try check(firstProvider.canLoadObject(ofClass: NSImage.self) && secondProvider.canLoadObject(ofClass: NSImage.self), "exact PNG providers lost image-object compatibility")

            var firstData: Data?
            var secondData: Data?
            var firstError: Error?
            var secondError: Error?
            var completed = 0
            // Request B before A and let both callbacks overlap.
            secondProvider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, error in
                DispatchQueue.main.async { secondData = data; secondError = error; completed += 1 }
            }
            firstProvider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, error in
                DispatchQueue.main.async { firstData = data; firstError = error; completed += 1 }
            }
            try waitUntil { completed == 2 }
            try check(firstError == nil && secondError == nil, "PNG representation failed: A=\(String(describing: firstError)), B=\(String(describing: secondError))")
            try check(firstData == firstPNG, "provider A returned altered PNG bytes or another image")
            try check(secondData == secondPNG, "provider B returned altered PNG bytes or another image")
            for (provider, expectedPNG, id) in [(secondProvider, secondPNG, secondID), (firstProvider, firstPNG, firstID)] {
                let fileURL = try loadFileURL(provider)
                try check(fileURL.lastPathComponent == id.uuidString.lowercased() + ".png", "file URL no longer identifies source UUID")
                try check(isInsideExportDirectory(fileURL, store: store), "file URL escaped isolated drag exports")
                try check(try Data(contentsOf: fileURL) == expectedPNG, "file URL and PNG representations differ")
                try check(try loadFilePNG(provider) == expectedPNG, "file representation and PNG data differ")
                let repeatedPNG = try loadPNG(provider)
                try check(repeatedPNG == expectedPNG, "repeated delayed provider load changed its image")
            }
        }
    }

    #if IMAGE_TRANSFER_SNAPSHOT_API
    private static func testExplicitSnapshotIsAuthoritative() throws {
        try withTemporaryStore { _, store in
            let snapshotPNG = try pngFixture(red: 0.78, green: 0.15, blue: 0.41, marker: "rendered-snapshot")
            let currentPNG = try pngFixture(red: 0.07, green: 0.82, blue: 0.19, marker: "current-file")
            let unrelatedPNG = try pngFixture(red: 0.06, green: 0.2, blue: 0.94, marker: "unrelated-provider")
            let id = UUID()
            let path = try store.storeImageData(currentPNG, id: id)
            let item = BoardItem(id: id, kind: .image, category: .inbox, order: 0, imageRelativePath: path)
            try store.saveBoard([item])
            let model = BoardModel(store: store, monitorsClipboard: false)
            let snapshotProvider = model.dragProvider(for: item, imageData: snapshotPNG)
            let unrelatedID = UUID()
            let unrelatedPath = try store.storeImageData(unrelatedPNG, id: unrelatedID)
            let unrelatedItem = BoardItem(id: unrelatedID, kind: .image, category: .inbox, order: 1, imageRelativePath: unrelatedPath)
            let unrelatedProvider = model.dragProvider(for: unrelatedItem, imageData: unrelatedPNG)
            try check(try loadPNG(unrelatedProvider) == unrelatedPNG, "unrelated provider lost its snapshot")
            try check(try loadPNG(snapshotProvider) == snapshotPNG, "explicit snapshot was replaced by disk or another provider")
            let snapshotURL = try loadFileURL(snapshotProvider)
            try check(try Data(contentsOf: snapshotURL) == snapshotPNG, "file URL representation ignored rendered snapshot")
            try check(try loadFilePNG(snapshotProvider) == snapshotPNG, "file representation ignored rendered snapshot")
            let managedURL = try require(model.imageURL(for: item), "missing current file")
            try check(try Data(contentsOf: managedURL) == currentPNG, "snapshot export overwrote current managed file")
            try check(try loadPNG(snapshotProvider) == snapshotPNG, "later loading changed the explicit snapshot")
        }
    }
    #endif

    private static func withTemporaryStore(_ body: (URL, LocalStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("station-image-transfer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(dataDirectory: directory.appendingPathComponent("data", isDirectory: true),
                             dragExportsDirectory: directory.appendingPathComponent("exports", isDirectory: true))
        try body(directory, LocalStore(paths: paths))
    }

    private static func pngFixture(red: CGFloat, green: CGFloat, blue: CGFloat, marker: String) throws -> Data {
        let colorSpace = try require(CGColorSpace(name: CGColorSpace.displayP3), "Display P3 unavailable")
        let context = try require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                           space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "fixture context unavailable")
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        context.setFillColor(red: blue, green: red, blue: green, alpha: 1)
        context.fill(CGRect(x: 3, y: 2, width: 3, height: 4))
        let image = try require(context.makeImage(), "fixture CGImage unavailable")
        let bytes = NSMutableData()
        let destination = try require(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil), "PNG fixture writer unavailable")
        CGImageDestinationAddImage(destination, image, nil)
        try check(CGImageDestinationFinalize(destination), "PNG fixture could not be finalized")
        let png = bytes as Data
        try check(png.range(of: Data("iCCP".utf8)) != nil, "fixture lacks embedded ICC profile")
        let endOffset = png.count - 12
        try check(endOffset > 8 && png.subdata(in: endOffset + 4..<endOffset + 8) == Data("IEND".utf8), "fixture lacks final IEND")
        let metadata = Data("StationFixture\0\(marker)".utf8)
        let typeAndPayload = Data("tEXt".utf8) + metadata
        var result = png.prefix(endOffset)
        result.append(bigEndian(UInt32(metadata.count)))
        result.append(typeAndPayload)
        result.append(bigEndian(crc32(typeAndPayload)))
        result.append(png.suffix(12))
        try check(NSBitmapImageRep(data: result) != nil, "ICC/metadata PNG fixture is invalid")
        return result
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    private static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        return crc ^ 0xffffffff
    }

    private static func loadPNG(_ provider: NSItemProvider) throws -> Data {
        var result: Data?
        var failure: Error?
        var finished = false
        provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, error in
            DispatchQueue.main.async { result = data; failure = error; finished = true }
        }
        try waitUntil { finished }
        if let failure { throw failure }
        return try require(result, "provider returned no PNG data")
    }

    private static func loadFileURL(_ provider: NSItemProvider) throws -> URL {
        try check(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), "provider lost public.file-url representation")
        var result: URL?
        var failure: Error?
        var finished = false
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
            DispatchQueue.main.async {
                if let url = value as? URL { result = url }
                else if let url = value as? NSURL { result = url as URL }
                else if let data = value as? Data, let text = String(data: data, encoding: .utf8) {
                    result = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
                } else if let text = value as? String { result = URL(string: text) }
                failure = error
                finished = true
            }
        }
        try waitUntil { finished }
        if let failure { throw failure }
        return try require(result, "provider returned no file URL")
    }

    private static func loadFilePNG(_ provider: NSItemProvider) throws -> Data {
        var result: Data?
        var failure: Error?
        var finished = false
        provider.loadFileRepresentation(forTypeIdentifier: UTType.png.identifier) { url, error in
            // Item-provider temporary URLs are only valid until this callback returns.
            let captured: Result<Data, Error>
            if let error { captured = .failure(error) }
            else {
                captured = Result { try Data(contentsOf: try require(url, "provider returned no PNG file")) }
            }
            DispatchQueue.main.async {
                switch captured {
                case .success(let data): result = data
                case .failure(let error): failure = error
                }
                finished = true
            }
        }
        try waitUntil { finished }
        if let failure { throw failure }
        return try require(result, "provider returned no PNG file bytes")
    }

    private static func isInsideExportDirectory(_ url: URL, store: LocalStore) -> Bool {
        url.isFileURL && url.standardizedFileURL.path.hasPrefix(store.paths.dragExportsDirectory.standardizedFileURL.path + "/")
    }

    private static func waitUntil(_ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try check(predicate(), "asynchronous operation timed out")
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestFailure(description: message) }
    }

    private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw TestFailure(description: message) }
        return value
    }
}
