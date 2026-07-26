import CryptoKit
import Foundation
import UniformTypeIdentifiers

actor ExternalDeviceService {
    enum ScanError: LocalizedError {
        case unreadableDirectory

        var errorDescription: String? { "无法读取所选设备或文件夹，请确认设备仍已连接。" }
    }

    func identity(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey, .nameKey])
        let volume = values?.volumeIdentifier.map { String(describing: $0) } ?? "unknown-volume"
        return Self.sha256("\(volume)|\(url.standardizedFileURL.path)")
    }

    func contents(
        rootURL: URL,
        relativePath: String
    ) throws -> SourceDirectoryContent {
        let directory = relativePath.isEmpty
            ? rootURL
            : rootURL.appendingPathComponent(relativePath, isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isHiddenKey, .fileSizeKey,
            .creationDateKey, .contentModificationDateKey, .contentTypeKey
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        var folders: [SourceFolder] = []
        var images: [MediaItem] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys), values.isHidden != true else { continue }
            let childPath = relativePath.isEmpty ? url.lastPathComponent : "\(relativePath)/\(url.lastPathComponent)"
            if values.isDirectory == true {
                folders.append(SourceFolder(name: url.lastPathComponent, relativePath: childPath, url: url))
            } else if values.isRegularFile == true,
                      Self.isSupportedMedia(fileURL: url, type: values.contentType) {
                images.append(Self.mediaItem(
                    url: url,
                    relativePath: childPath,
                    values: values
                ))
            }
        }
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        images.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.fileName < rhs.fileName }
            return lhs.createdAt > rhs.createdAt
        }
        return SourceDirectoryContent(folders: folders, images: images)
    }

    func scan(rootURL: URL, relativePath: String = "") throws -> [MediaItem] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isHiddenKey, .fileSizeKey, .creationDateKey,
            .contentModificationDateKey, .contentTypeKey
        ]
        let scanURL = relativePath.isEmpty
            ? rootURL
            : rootURL.appendingPathComponent(relativePath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: scanURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw ScanError.unreadableDirectory
        }

        let rootPath = rootURL.standardizedFileURL.path
        var items: [MediaItem] = []
        for case let fileURL as URL in enumerator {
            autoreleasepool {
                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      values.isHidden != true,
                      Self.isSupportedMedia(fileURL: fileURL, type: values.contentType)
                else { return }

                let path = fileURL.standardizedFileURL.path
                let relativeStart = path.index(path.startIndex, offsetBy: min(rootPath.count + 1, path.count))
                let relativePath = String(path[relativeStart...])
                items.append(Self.mediaItem(
                    url: fileURL,
                    relativePath: relativePath,
                    values: values
                ))
            }
        }
        return items.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.relativePath < rhs.relativePath }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private static func isSupportedMedia(fileURL: URL, type: UTType?) -> Bool {
        if let type, type.conforms(to: .image) { return true }
        guard let inferred = UTType(filenameExtension: fileURL.pathExtension) else { return false }
        return inferred.conforms(to: .image)
    }

    private static func mediaItem(
        url: URL,
        relativePath: String,
        values: URLResourceValues
    ) -> MediaItem {
        let size = Int64(values.fileSize ?? 0)
        let modified = values.contentModificationDate ?? .distantPast
        let created = values.creationDate ?? modified
        let key = sha256("\(relativePath)|\(size)|\(modified.timeIntervalSince1970)")
        return MediaItem(
            id: key,
            sourceURL: url,
            relativePath: relativePath,
            fileName: url.lastPathComponent,
            byteSize: size,
            createdAt: created,
            modifiedAt: modified,
            state: .neverSynced
        )
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
