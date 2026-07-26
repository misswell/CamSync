import Foundation
import Photos

actor PhotoLibraryService {
    enum PhotoError: LocalizedError {
        case permissionDenied
        case collectionNotFound
        case cannotCreateCollection
        case cannotSaveAsset

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "没有照片权限，请在系统设置中允许访问。"
            case .collectionNotFound: "目标相册或文件夹已不存在。"
            case .cannotCreateCollection: "无法创建相册或文件夹。"
            case .cannotSaveAsset: "照片写入系统相册失败。"
            }
        }
    }

    func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    func collections(inFolder identifier: String?) async throws -> [PhotoCollectionNode] {
        guard await requestAccess() else { throw PhotoError.permissionDenied }
        let fetch: PHFetchResult<PHCollection>
        if let identifier {
            guard let folder = PHCollectionList.fetchCollectionLists(
                withLocalIdentifiers: [identifier], options: nil
            ).firstObject else { throw PhotoError.collectionNotFound }
            fetch = PHCollection.fetchCollections(in: folder, options: nil)
        } else {
            fetch = PHCollection.fetchTopLevelUserCollections(with: nil)
        }

        var nodes: [PhotoCollectionNode] = []
        fetch.enumerateObjects { collection, _, _ in
            if let folder = collection as? PHCollectionList, folder.collectionListType == .folder {
                nodes.append(PhotoCollectionNode(
                    id: folder.localIdentifier,
                    title: folder.localizedTitle ?? "未命名文件夹",
                    kind: .folder,
                    childCount: PHCollection.fetchCollections(in: folder, options: nil).count
                ))
            } else if let album = collection as? PHAssetCollection,
                      album.assetCollectionType == .album {
                nodes.append(PhotoCollectionNode(
                    id: album.localIdentifier,
                    title: album.localizedTitle ?? "未命名相册",
                    kind: .album,
                    childCount: PHAsset.fetchAssets(in: album, options: nil).count
                ))
            }
        }
        return nodes.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .folder }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    func createAlbum(named name: String, inFolder folderID: String?) async throws -> PhotoCollectionNode {
        guard await requestAccess() else { throw PhotoError.permissionDenied }
        var identifier: String?
        try await performChanges {
            identifier = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: name)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let identifier,
              let album = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [identifier], options: nil
              ).firstObject else { throw PhotoError.cannotCreateCollection }
        if let folderID { try await addCollection(album, toFolder: folderID) }
        return PhotoCollectionNode(id: identifier, title: name, kind: .album, childCount: 0)
    }

    func createFolder(named name: String, inFolder parentID: String?) async throws -> PhotoCollectionNode {
        guard await requestAccess() else { throw PhotoError.permissionDenied }
        var identifier: String?
        try await performChanges {
            identifier = PHCollectionListChangeRequest
                .creationRequestForCollectionList(withTitle: name)
                .placeholderForCreatedCollectionList.localIdentifier
        }
        guard let identifier,
              let folder = PHCollectionList.fetchCollectionLists(
                withLocalIdentifiers: [identifier], options: nil
              ).firstObject else { throw PhotoError.cannotCreateCollection }
        if let parentID { try await addCollection(folder, toFolder: parentID) }
        return PhotoCollectionNode(id: identifier, title: name, kind: .folder, childCount: 0)
    }

    func prepare(_ destination: PhotoDestination) async throws -> PhotoDestination {
        guard await requestAccess() else { throw PhotoError.permissionDenied }
        if let identifier = destination.albumIdentifier,
           PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier], options: nil
           ).firstObject != nil {
            return destination
        }

        let node = try await createAlbum(
            named: destination.albumName,
            inFolder: destination.folderIdentifier
        )
        return PhotoDestination(
            albumIdentifier: node.id,
            albumName: node.title,
            folderName: destination.folderName,
            folderIdentifier: destination.folderIdentifier,
            folderPath: destination.folderPath
        )
    }

    func addPhoto(at fileURL: URL, to albumIdentifier: String) async throws -> String {
        let fetch = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumIdentifier], options: nil
        )
        guard let album = fetch.firstObject else { throw PhotoError.collectionNotFound }
        var identifier: String?
        try await performChanges {
            guard let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL),
                  let placeholder = request.placeholderForCreatedAsset else { return }
            identifier = placeholder.localIdentifier
            PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
        }
        guard let identifier else { throw PhotoError.cannotSaveAsset }
        return identifier
    }

    private func addCollection(_ child: PHCollection, toFolder identifier: String) async throws {
        guard let folder = PHCollectionList.fetchCollectionLists(
            withLocalIdentifiers: [identifier], options: nil
        ).firstObject else { throw PhotoError.collectionNotFound }
        try await performChanges {
            PHCollectionListChangeRequest(for: folder)?.addChildCollections([child] as NSArray)
        }
    }

    private func performChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? PhotoError.cannotSaveAsset)
                }
            }
        }
    }
}
