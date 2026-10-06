import AppKit
import ImageIO

final class ImagePreview: NSObject {
    let data: Data
    let image: NSImage
    let cost: Int

    init(data: Data, image: CGImage) {
        self.data = data
        self.image = NSImage(cgImage: image, size: .zero)
        cost = data.count + image.bytesPerRow * image.height
    }
}

// All mutable work is confined to queue; cached snapshots are immutable.
final class ImagePreviewStore: @unchecked Sendable {
    static let shared = ImagePreviewStore()
    private let cache = NSCache<NSString, ImagePreview>()
    private let queue = DispatchQueue(label: "station.image-previews", qos: .userInitiated)

    init() {
        cache.countLimit = 40
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func load(_ url: URL) async -> ImagePreview? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let result: ImagePreview? = autoreleasepool {
                    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
                    let key = "\(url.path)-\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(values.fileSize ?? 0)" as NSString
                    if let cached = cache.object(forKey: key) { return cached }
                    guard let data = try? Data(contentsOf: url), let preview = Self.decode(data) else { return nil }
                    cache.setObject(preview, forKey: key, cost: preview.cost)
                    return preview
                }
                continuation.resume(returning: result)
            }
        }
    }

    static func decode(_ data: Data) -> ImagePreview? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 720,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return ImagePreview(data: data, image: image)
    }
}
