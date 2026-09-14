import XCTest
import Photos

/// End-to-end check of the real CamSync code path:
///   fixture (original name) -> TransferService UUID staging file -> PhotoLibraryService.addPhoto
/// and reads the stored resource name back with PHAssetResource.assetResources(for:).
final class FileNamePreservationTests: XCTestCase {
    private let service = PhotoLibraryService()
    private var albumID: String!

    override func setUp() async throws {
        print("RESULT authorization before: \(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)")
        let granted = await service.requestAccess()
        print("RESULT authorization after: \(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue) granted=\(granted)")
        XCTAssertTrue(granted, "photo library access not granted to the test host")
        let album = try await service.createAlbum(named: "CamSync Verify \(UUID().uuidString.prefix(8))", inFolder: nil)
        albumID = album.id
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: name, withExtension: ext)
        XCTAssertNotNil(url, "missing fixture \(name).\(ext)")
        return url!
    }

    /// Runs the real TransferService against a fixture and returns the imported
    /// asset plus the resource filename Photos actually stored.
    @discardableResult
    private func transferAndReadBack(fixtureURL: URL, originalFileName: String) async throws -> (asset: PHAsset, storedName: String?) {
        let values = try fixtureURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        let item = MediaItem(
            id: UUID().uuidString,
            sourceURL: fixtureURL,
            relativePath: originalFileName,
            fileName: originalFileName,
            byteSize: Int64(values.fileSize ?? 0),
            createdAt: values.creationDate ?? Date(),
            modifiedAt: values.contentModificationDate ?? Date(),
            state: .neverSynced
        )
        let destination = SyncDestination.photoLibrary(PhotoDestination(
            albumIdentifier: albumID,
            albumName: "CamSync Verify"
        ))
        let transfer = TransferService(photoLibrary: service)
        let result = try await transfer.transfer(item, to: destination)

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [result.destinationLocator], options: nil)
        guard let asset = assets.firstObject else {
            XCTFail("asset \(result.destinationLocator) not found after import")
            throw XCTSkip("asset missing")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let photo = resources.first { $0.type == .photo } ?? resources.first
        return (asset, photo?.originalFilename)
    }

    func testJPEGKeepsOriginalFileName() async throws {
        let url = try fixture("src", "jpg")
        let (asset, stored) = try await transferAndReadBack(fixtureURL: url, originalFileName: "IMG_1234.JPG")
        print("RESULT jpg: \(asset.localIdentifier) -> \(stored ?? "<nil>")")
        XCTAssertEqual(stored, "IMG_1234.JPG")
    }

    func testHEICKeepsOriginalFileName() async throws {
        let url = try fixture("src", "heic")
        let (asset, stored) = try await transferAndReadBack(fixtureURL: url, originalFileName: "IMG_5678.HEIC")
        print("RESULT heic: \(asset.localIdentifier) -> \(stored ?? "<nil>")")
        XCTAssertEqual(stored, "IMG_5678.HEIC")
    }

    func testPNGKeepsOriginalFileName() async throws {
        let url = try fixture("src", "png")
        let (asset, stored) = try await transferAndReadBack(fixtureURL: url, originalFileName: "Screenshot_0001.PNG")
        print("RESULT png: \(asset.localIdentifier) -> \(stored ?? "<nil>")")
        XCTAssertEqual(stored, "Screenshot_0001.PNG")
    }

    func testMixedCaseAndNikonExtensionArePreserved() async throws {
        let url = try fixture("src", "nef")
        let (asset, stored) = try await transferAndReadBack(fixtureURL: url, originalFileName: "DSC_0001.NEF")
        print("RESULT nef-named fixture: \(asset.localIdentifier) -> \(stored ?? "<nil>")")
        XCTAssertEqual(stored, "DSC_0001.NEF")
    }

    func testStagingFilesAreCleanedUpAfterImport() async throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("CamSyncStaging", isDirectory: true)
        let url = try fixture("src", "jpg")
        try await transferAndReadBack(fixtureURL: url, originalFileName: "IMG_9999.JPG")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        print("RESULT staging leftovers: \(leftovers)")
        let uuidNamed = leftovers.filter { UUID(uuidString: ($0 as NSString).deletingPathExtension) != nil }
        XCTAssertTrue(uuidNamed.isEmpty, "UUID staging files were not cleaned up: \(uuidNamed)")
    }

    /// Negative control: proves the harness actually detects the bug the old
    /// PHAssetChangeRequest API had (UUID staging name becoming the asset name).
    func testControlOldAPIWouldStoreUUIDName() async throws {
        let url = try fixture("src", "jpg")
        let uuidName = UUID().uuidString + ".JPG"
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(uuidName)
        try FileManager.default.copyItem(at: url, to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }

        let album = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID], options: nil
        ).firstObject!
        var identifier: String?
        var importError: Error?
        let imported = expectation(description: "old API import")

        PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: staging),
                  let placeholder = request.placeholderForCreatedAsset else { return }
            identifier = placeholder.localIdentifier
            PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
        } completionHandler: { success, error in
            if !success { importError = error }
            imported.fulfill()
        }

        await fulfillment(of: [imported], timeout: 60)
        XCTAssertNil(importError, "control import failed: \(String(describing: importError))")
        let assetID = try XCTUnwrap(identifier, "old API produced no placeholder")
        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject)
        let stored = PHAssetResource.assetResources(for: asset).first?.originalFilename
        print("RESULT control (old API): \(stored ?? "<nil>")")
        XCTAssertEqual(stored, uuidName, "control no longer reproduces the old UUID-naming behaviour")
    }
}
