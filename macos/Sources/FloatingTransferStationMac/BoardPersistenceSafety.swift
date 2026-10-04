import Foundation

enum BoardPersistenceSafety {
    static func warning(for url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["items"] is [Any] else {
                return "看板文件结构异常，已保护原文件并停止写入。"
            }

            let schemaVersion = (root["schemaVersion"] as? NSNumber)?.intValue ?? 0
            guard schemaVersion == BoardSnapshot.currentSchemaVersion else {
                return "看板数据版本不受当前应用支持，已保护原文件并停止写入。"
            }

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
            _ = try decoder.decode(BoardSnapshot.self, from: data)
            return nil
        } catch {
            return "看板文件损坏或无法读取，已保护原文件并停止写入。"
        }
    }
}
