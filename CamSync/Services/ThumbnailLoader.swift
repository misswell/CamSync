import AVFoundation
import ImageIO
import UIKit

actor ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private let limiter = ThumbnailDecodeLimiter(limit: 3)
    private var inFlight: [NSURL: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 180
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for url: URL, maxPixelSize: CGFloat = 360) async -> UIImage? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let limiter = limiter
        let task = Task.detached(priority: .utility) {
            await limiter.acquire()
            let image = Self.decodeThumbnail(from: url, maxPixelSize: maxPixelSize)
            await limiter.release()
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        guard let image else { return nil }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    nonisolated private static func decodeThumbnail(from url: URL, maxPixelSize: CGFloat) -> UIImage? {
        if MediaItem.isVideo(fileExtension: url.pathExtension.lowercased()) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            guard let frame = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
            return UIImage(cgImage: frame)
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        // 第一阶段只取相机文件中已有的 EXIF/HEIF/RAW 内嵌预览，不解码原图。
        let embeddedOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: false
        ]
        if let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, embeddedOptions as CFDictionary) {
            return UIImage(cgImage: embedded)
        }

        // 没有内嵌预览时才让 ImageIO 在解码源头降采样，仍不创建全尺寸 UIImage。
        let fallbackOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, fallbackOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: thumbnail)
    }
}

private actor ThumbnailDecodeLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = max(1, limit)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
