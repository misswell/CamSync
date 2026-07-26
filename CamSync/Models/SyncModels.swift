import Foundation
import UniformTypeIdentifiers

enum SyncItemState: String, Codable, Sendable {
    case neverSynced
    case transferring
    case synced
    case failed
}

struct MediaItem: Identifiable, Hashable, Sendable {
    let id: String
    let sourceURL: URL
    let relativePath: String
    let fileName: String
    let byteSize: Int64
    let createdAt: Date
    let modifiedAt: Date
    var state: SyncItemState

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

struct SourceFolder: Identifiable, Hashable, Sendable {
    var id: String { relativePath }
    let name: String
    let relativePath: String
    let url: URL
}

struct SourceDirectoryContent: Sendable {
    let folders: [SourceFolder]
    let images: [MediaItem]
}

struct DeviceRecord: Identifiable, Sendable {
    let id: String
    let displayName: String
    let volumeName: String?
    let bookmark: Data
    let lastConnectedAt: Date

    var historyDisplayName: String {
        guard let volumeName, !volumeName.isEmpty, volumeName != displayName else { return displayName }
        return "\(volumeName) · \(displayName)"
    }
}

enum DestinationKind: String, Codable, CaseIterable, Sendable {
    case photoLibrary
    case files

    var title: String {
        switch self {
        case .photoLibrary: "系统相册"
        case .files: "文件或 iCloud"
        }
    }
}

struct PhotoDestination: Codable, Hashable, Sendable {
    var albumIdentifier: String?
    var albumName: String
    var folderName: String?
    var folderIdentifier: String? = nil
    var folderPath: [String]? = nil
}

enum PhotoCollectionKind: String, Hashable, Sendable {
    case folder
    case album
}

struct PhotoCollectionNode: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let kind: PhotoCollectionKind
    let childCount: Int
}

struct FileDestination: Codable, Hashable, Sendable {
    var bookmark: Data
    var displayName: String
}

enum SyncDestination: Codable, Hashable, Sendable {
    case photoLibrary(PhotoDestination)
    case files(FileDestination)

    var kind: DestinationKind {
        switch self {
        case .photoLibrary: .photoLibrary
        case .files: .files
        }
    }

    var displayName: String {
        switch self {
        case .photoLibrary(let value):
            let folders = value.folderPath ?? value.folderName.map { [$0] } ?? []
            if !folders.isEmpty {
                return "照片 · \((folders + [value.albumName]).joined(separator: "/"))"
            }
            return "照片 · \(value.albumName)"
        case .files(let value):
            return "文件 · \(value.displayName)"
        }
    }
}

struct DeviceSettings: Codable, Sendable {
    var automaticSyncEnabled = false
    var earliestCreationDate: Date?
    var destination: SyncDestination?
    var maxConcurrentTransfers = 3
    var lastSourceFolderPath: String?
}

struct SyncProgress: Sendable {
    var total = 0
    var completed = 0
    var succeeded = 0
    var failed = 0
    var currentFileNames: [String] = []

    var fraction: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }
}

struct SyncSummary: Sendable {
    let succeeded: Int
    let failed: Int
    let skipped: Int
    let cancelled: Int
}

struct SyncAttemptToken: Sendable {
    let id: Int64
    let itemID: String
}

struct SyncResult: Sendable {
    let destinationLocator: String
    let contentHash: String
}
