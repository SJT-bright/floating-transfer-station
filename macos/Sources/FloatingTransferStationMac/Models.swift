import Foundation

enum BoardCategory: String, Codable, CaseIterable, Identifiable {
    case customerOriginal = "CustomerOriginal"
    case reference = "Reference"
    case prompt = "Prompt"
    case inbox = "Inbox"

    static let visibleCases: [BoardCategory] = [
        .customerOriginal,
        .reference,
        .prompt,
        .inbox
    ]

    var id: String { rawValue }

    var defaultDisplayName: String {
        switch self {
        case .customerOriginal:
            return "人物资产"
        case .reference:
            return "场景"
        case .prompt:
            return "提示词"
        case .inbox:
            return "待分类"
        }
    }
}

enum BoardItemKind: String, Codable {
    case image = "Image"
    case text = "Text"
}

struct BoardItem: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: BoardItemKind
    var category: BoardCategory
    var order: Int
    var createdAt: Date
    var text: String?
    var imageRelativePath: String?
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        kind: BoardItemKind,
        category: BoardCategory,
        order: Int,
        createdAt: Date = Date(),
        text: String? = nil,
        imageRelativePath: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.category = category
        self.order = order
        self.createdAt = createdAt
        self.text = text
        self.imageRelativePath = imageRelativePath
        self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case category
        case order
        case createdAt
        case text
        case imageRelativePath
        case isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(BoardItemKind.self, forKey: .kind)
        category = try container.decode(BoardCategory.self, forKey: .category)
        order = try container.decode(Int.self, forKey: .order)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        imageRelativePath = try container.decodeIfPresent(String.self, forKey: .imageRelativePath)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

struct BoardSnapshot: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var items: [BoardItem]

    init(schemaVersion: Int = currentSchemaVersion, items: [BoardItem] = []) {
        self.schemaVersion = schemaVersion
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        let decodedItems = try container.decodeIfPresent(
            [LossyDecodable<BoardItem>].self,
            forKey: .items
        ) ?? []
        items = decodedItems.compactMap(\.value)
    }
}

struct WindowSettings: Codable, Equatable {
    var panelWidth: Double
    var windowHeight: Double
    var top: Double
    var categoryNames: [String: String]

    static let `default` = WindowSettings(
        panelWidth: 360,
        windowHeight: 640,
        top: 80,
        categoryNames: [:]
    )

    init(
        panelWidth: Double,
        windowHeight: Double,
        top: Double,
        categoryNames: [String: String] = [:]
    ) {
        self.panelWidth = panelWidth
        self.windowHeight = windowHeight
        self.top = top
        self.categoryNames = categoryNames
    }

    func displayName(for category: BoardCategory) -> String {
        categoryNames[category.rawValue] ?? category.defaultDisplayName
    }

    private enum CodingKeys: String, CodingKey {
        case panelWidth
        case windowHeight
        case top
        case categoryNames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panelWidth = try container.decodeIfPresent(Double.self, forKey: .panelWidth) ?? 360
        windowHeight = try container.decodeIfPresent(Double.self, forKey: .windowHeight) ?? 640
        top = try container.decodeIfPresent(Double.self, forKey: .top) ?? 80
        categoryNames = try container.decodeIfPresent(
            [String: String].self,
            forKey: .categoryNames
        ) ?? [:]
    }
}
