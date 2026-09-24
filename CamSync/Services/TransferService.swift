import CryptoKit
import Foundation

final class TransferService: @unchecked Sendable {
    enum TransferError: LocalizedError {
        case destinationUnavailable
        case cannotOpenSource
        case cannotWriteDestination

        var errorDescription: String? {
            switch self {
            case .destinationUnavailable: "目标文件夹当前不可用。"
            case .cannotOpenSource: "源文件已断开或无法读取。"
            case .cannotWriteDestination: "无法写入目标位置。"
            }
        }
    }

    private let photoLibrary: PhotoLibraryService

    init(photoLibrary: PhotoLibraryService) {
        self.photoLibrary = photoLibrary
    }

    func transfer(_ item: MediaItem, to destination: SyncDestination) async throws -> SyncResult {
        try Task.checkCancellation()
        switch destination {
        case .photoLibrary(let photoDestination):
            guard let albumID = photoDestination.albumIdentifier else {
                throw PhotoLibraryService.PhotoError.collectionNotFound
            }
            let stagingURL = try stagingURL(for: item)
            defer { try? FileManager.default.removeItem(at: stagingURL) }
            let digest = try copyAndHash(from: item.sourceURL, to: stagingURL)
            try Task.checkCancellation()
            let assetID = try await photoLibrary.addMedia(
                at: stagingURL,
                originalFileName: item.fileName,
                isVideo: item.isVideo,
                to: albumID
            )
            return SyncResult(destinationLocator: assetID, contentHash: digest)

        case .files(let fileDestination):
            var stale = false
            let folder = try URL(
                resolvingBookmarkData: fileDestination.bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard !stale else { throw TransferError.destinationUnavailable }
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            let requestedURL = folder.appendingPathComponent(item.relativePath)
            if FileManager.default.fileExists(atPath: requestedURL.path),
               let existing = try? hash(of: requestedURL),
               let source = try? hash(of: item.sourceURL),
               existing == source {
                try Task.checkCancellation()
                return SyncResult(destinationLocator: requestedURL.path, contentHash: source)
            }
            let finalURL = try availableDestinationURL(root: folder, relativePath: item.relativePath)
            try FileManager.default.createDirectory(
                at: finalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let temporary = finalURL.deletingLastPathComponent()
                .appendingPathComponent(".camsync-\(UUID().uuidString).partial")
            do {
                let digest = try copyAndHash(from: item.sourceURL, to: temporary)
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: temporary, to: finalURL)
                return SyncResult(destinationLocator: finalURL.path, contentHash: digest)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
    }

    private func stagingURL(for item: MediaItem) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CamSyncStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(item.sourceURL.pathExtension)
    }

    private func availableDestinationURL(root: URL, relativePath: String) throws -> URL {
        let requested = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: requested.path) else { return requested }
        let directory = requested.deletingLastPathComponent()
        let stem = requested.deletingPathExtension().lastPathComponent
        let ext = requested.pathExtension
        for suffix in 1...10_000 {
            var name = "\(stem) (\(suffix))"
            if !ext.isEmpty { name += ".\(ext)" }
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw TransferError.cannotWriteDestination
    }

    private func copyAndHash(from source: URL, to destination: URL) throws -> String {
        guard let input = InputStream(url: source), let output = OutputStream(url: destination, append: false) else {
            throw TransferError.cannotOpenSource
        }
        input.open()
        output.open()
        defer {
            input.close()
            output.close()
        }

        var hasher = SHA256()
        let capacity = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        while true {
            try Task.checkCancellation()
            let read = input.read(buffer, maxLength: capacity)
            if read < 0 { throw input.streamError ?? TransferError.cannotOpenSource }
            if read == 0 { break }
            let data = Data(bytes: buffer, count: read)
            hasher.update(data: data)
            var written = 0
            while written < read {
                let count = output.write(buffer.advanced(by: written), maxLength: read - written)
                if count <= 0 { throw output.streamError ?? TransferError.cannotWriteDestination }
                written += count
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func hash(of source: URL) throws -> String {
        guard let input = InputStream(url: source) else { throw TransferError.cannotOpenSource }
        input.open()
        defer { input.close() }
        var hasher = SHA256()
        let capacity = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        while true {
            try Task.checkCancellation()
            let read = input.read(buffer, maxLength: capacity)
            if read < 0 { throw input.streamError ?? TransferError.cannotOpenSource }
            if read == 0 { break }
            hasher.update(data: Data(bytes: buffer, count: read))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
