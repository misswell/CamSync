import Foundation
import UniformTypeIdentifiers

enum SyncItemState: String, Codable, Sendable {
    case neverSynced
    case transferring
    case synced
    case failed
}

enum MediaFormatFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case jpeg
    case raw
    case video
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部格式"
        case .jpeg: "JPG / JPEG"
        case .raw: "RAW"
        case .video: "视频"
        case .other: "其他图片格式"
        }
    }

    func matches(_ item: MediaItem) -> Bool {
        self == .all || item.formatCategory == self
    }
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

    var formatCategory: MediaFormatFilter {
        let fileExtension = sourceURL.pathExtension.lowercased()
        if Self.isVideo(fileExtension: fileExtension) { return .video }
        if fileExtension == "jpg" || fileExtension == "jpeg" {
            return .jpeg
        }

        if Self.rawExtensions.contains(fileExtension),
           UTType(filenameExtension: fileExtension)?.conforms(to: .rawImage) != false {
            return .raw
        }
        return .other
    }

    var isVideo: Bool { formatCategory == .video }

    static func isVideo(fileExtension: String) -> Bool {
        if videoExtensions.contains(fileExtension) { return true }
        guard let type = UTType(filenameExtension: fileExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mts", "m2ts", "mpg", "mpeg", "3gp", "3g2",
        "mkv", "webm", "wmv", "mxf", "r3d", "braw", "crm"
    ]

    private static let rawExtensions: Set<String> = [
        "3fr", "ari", "arw", "bay", "cr2", "cr3", "crw", "dcr", "dcs", "dng",
        "drf", "erf", "fff", "iiq", "k25", "kdc", "mef", "mos", "mrw", "nef",
        "nrw", "orf", "pef", "raf", "raw", "rwl", "rw2", "sr2", "srf",
        "srw", "x3f"
    ]
}

struct SourceFolder: Identifiable, Hashable, Sendable {
    var id: String { relativePath }
    let name: String
    let relativePath: String
    let url: URL
}

struct SourceDirectoryContent: Sendable {
    let folders: [SourceFolder]
    let mediaItems: [MediaItem]
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
