import AppKit
import Foundation

struct AppPaths {
    let dataDirectory: URL
    let boardFile: URL
    let settingsFile: URL
    let imagesDirectory: URL

    init(dataDirectory: URL) {
        let normalized = dataDirectory.standardizedFileURL
        self.dataDirectory = normalized
        boardFile = normalized.appendingPathComponent("board.json", isDirectory: false)
        settingsFile = normalized.appendingPathComponent("settings.json", isDirectory: false)
        imagesDirectory = normalized.appendingPathComponent("images", isDirectory: true)
    }

    static var `default`: AppPaths {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return AppPaths(
            dataDirectory: base
                .appendingPathComponent("悬浮中转站", isDirectory: true)
                .appendingPathComponent("Data", isDirectory: true)
        )
    }
}

final class LocalStore {
    let paths: AppPaths

    private let fileManager: FileManager

    init(paths: AppPaths = .default, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func loadBoard() -> [BoardItem] {
        let snapshot: BoardSnapshot = loadWithBackup(
            from: paths.boardFile,
            fallback: BoardSnapshot()
        )
        guard snapshot.schemaVersion == BoardSnapshot.currentSchemaVersion else {
            return []
        }

        let emptyID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        var seenIDs = Set<UUID>()
        return snapshot.items.filter { item in
            guard item.id != emptyID,
                  item.order >= 0,
                  seenIDs.insert(item.id).inserted
            else {
                return false
            }

            switch item.kind {
            case .text:
                return !(item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image:
                guard let relativePath = item.imageRelativePath,
                      let imageURL = managedImageURL(relativePath: relativePath)
                else {
                    return false
                }
                return fileManager.fileExists(atPath: imageURL.path)
            }
        }
    }

    func saveBoard(_ items: [BoardItem]) throws {
        let snapshot = BoardSnapshot(items: items)
        try atomicWrite(encode(snapshot), to: paths.boardFile)
    }

    func loadSettings() -> WindowSettings {
        loadWithBackup(from: paths.settingsFile, fallback: .default)
    }

    func saveSettings(_ settings: WindowSettings) throws {
        try atomicWrite(encode(settings), to: paths.settingsFile)
    }

    func storeImage(_ image: NSImage, id: UUID = UUID()) throws -> String {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }

        try fileManager.createDirectory(
            at: paths.imagesDirectory,
            withIntermediateDirectories: true
        )
        let fileName = "\(id.uuidString.lowercased()).png"
        let destination = paths.imagesDirectory.appendingPathComponent(fileName)
        try png.write(to: destination, options: .atomic)
        return "images/\(fileName)"
    }

    func storeImageFile(_ source: URL, id: UUID = UUID()) throws -> String {
        guard source.isFileURL,
              let image = NSImage(contentsOf: source)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try storeImage(image, id: id)
    }

    func managedImageURL(relativePath: String) -> URL? {
        let normalizedRelativePath = relativePath.replacingOccurrences(of: "\\", with: "/")
        let candidate = paths.dataDirectory
            .appendingPathComponent(normalizedRelativePath)
            .standardizedFileURL
        let allowedRoot = paths.imagesDirectory.standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(allowedRoot) else {
            return nil
        }
        return candidate
    }

    @discardableResult
    func deleteManagedImage(relativePath: String?) -> Bool {
        guard let relativePath,
              let imageURL = managedImageURL(relativePath: relativePath)
        else {
            return false
        }
        guard fileManager.fileExists(atPath: imageURL.path) else {
            return true
        }

        do {
            try fileManager.removeItem(at: imageURL)
            return true
        } catch {
            return false
        }
    }

    private func loadWithBackup<Value: Decodable>(
        from primaryURL: URL,
        fallback: Value
    ) -> Value {
        if fileManager.fileExists(atPath: primaryURL.path) {
            do {
                return try decode(Value.self, from: primaryURL)
            } catch {
                preserveCorruptFile(primaryURL)
            }
        }

        let backupURL = URL(fileURLWithPath: primaryURL.path + ".bak")
        do {
            return try decode(Value.self, from: backupURL)
        } catch {
            return fallback
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }

            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: url.path) {
            let backupURL = URL(fileURLWithPath: url.path + ".bak")
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: url, to: backupURL)
        }

        try data.write(to: url, options: .atomic)
    }

    private func preserveCorruptFile(_ url: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmssSSS"
        let suffix = "corrupt-\(formatter.string(from: Date()))-\(UUID().uuidString.lowercased()).bak"
        let destination = URL(fileURLWithPath: url.path + ".\(suffix)")
        try? fileManager.copyItem(at: url, to: destination)
    }
}
