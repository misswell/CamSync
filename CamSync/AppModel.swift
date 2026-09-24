import Foundation
import Photos
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var device: DeviceRecord?
    @Published var sourceURL: URL?
    @Published var folders: [SourceFolder] = []
    @Published var currentFolderPath = ""
    @Published var items: [MediaItem] = []
    @Published var selection = Set<String>()
    @Published var settings = DeviceSettings()
    @Published var progress: SyncProgress?
    @Published var isScanning = false
    @Published var statusMessage = "选择相机、SD 卡或外部存储中的照片和视频文件夹"
    @Published var errorMessage: String?
    @Published var completionMessage: String?
    @Published var syncedHistoryCount = 0
    @Published var failedHistoryCount = 0
    @Published var showPreviouslySynced = false
    @Published var knownDevices: [DeviceRecord] = []
    @Published var availableDeviceIDs = Set<String>()
    @Published var isPreparingDownloadIndex = false
    @Published var isCancellingSync = false
    @Published var downloadFormatFilter: MediaFormatFilter = .all

    private let database: SyncDatabase
    private let deviceService = ExternalDeviceService()
    private let photoLibrary = PhotoLibraryService()
    private let coordinator: SyncCoordinator
    private var securityScopedURL: URL?
    private var deviceCatalog: [MediaItem] = []
    private var indexedFolderPath: String?
    private var activeSyncTask: Task<Void, Never>?

    init() {
        do {
            let database = try SyncDatabase()
            self.database = database
            let transfer = TransferService(photoLibrary: photoLibrary)
            self.coordinator = SyncCoordinator(database: database, transferService: transfer)
        } catch {
            fatalError("无法打开同步数据库：\(error)")
        }
    }

    var visibleItems: [MediaItem] {
        if showPreviouslySynced { return items }
        return items.filter { $0.state != .synced }
    }

    var newItemCount: Int { items.lazy.filter { $0.state != .synced }.count }
    var selectedItems: [MediaItem] { items.filter { selection.contains($0.id) } }
    var downloadScopeItems: [MediaItem] {
        indexedFolderPath == currentFolderPath ? deviceCatalog : items
    }
    private var filteredDownloadScopeItems: [MediaItem] {
        downloadScopeItems.filter { downloadFormatFilter.matches($0) }
    }
    var downloadScopeCount: Int { filteredDownloadScopeItems.count }
    var downloadScopeNewCount: Int { filteredDownloadScopeItems.lazy.filter { $0.state != .synced }.count }
    var canSync: Bool { !selection.isEmpty && settings.destination != nil && progress == nil }
    var canNavigateBack: Bool { !currentFolderPath.isEmpty }
    var currentFolderName: String {
        currentFolderPath.isEmpty ? (device?.displayName ?? "设备") : URL(fileURLWithPath: currentFolderPath).lastPathComponent
    }
    var currentFolderBreadcrumb: String {
        currentFolderPath.isEmpty ? "设备根目录" : currentFolderPath.replacingOccurrences(of: "/", with: "  ›  ")
    }

    func restore() async {
        do {
            knownDevices = try await database.devices()
            await refreshDeviceAvailability()
        } catch {
            statusMessage = "请选择已连接的设备"
        }
    }

    func refreshDeviceAvailability() async {
        do {
            knownDevices = try await database.devices()
            var available = Set<String>()
            for record in knownDevices {
                var stale = false
                guard let url = try? URL(
                    resolvingBookmarkData: record.bookmark,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ), !stale else { continue }
                let accessed = url.startAccessingSecurityScopedResource()
                let reachable = (try? url.checkResourceIsReachable()) == true
                if accessed { url.stopAccessingSecurityScopedResource() }
                if reachable {
                    available.insert(record.id)
                    if record.volumeName == nil,
                       let volumeName = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName {
                        try? await database.upsertDevice(DeviceRecord(
                            id: record.id,
                            displayName: record.displayName,
                            volumeName: volumeName,
                            bookmark: record.bookmark,
                            lastConnectedAt: record.lastConnectedAt
                        ))
                    }
                }
            }
            availableDeviceIDs = available
            knownDevices = try await database.devices()
        } catch {
            // 可用性检测失败不影响用户手动选择设备。
        }
    }

    func connect(record: DeviceRecord) async throws {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: record.bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else {
            throw ExternalDeviceService.ScanError.unreadableDirectory
        }
        try await connect(url: url, knownRecord: record)
    }

    func connect(url: URL, knownRecord: DeviceRecord? = nil) async throws {
        stopAccessingSource()
        let accessed = url.startAccessingSecurityScopedResource()
        if accessed { securityScopedURL = url }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let id: String
            if let knownRecord {
                id = knownRecord.id
            } else {
                id = await deviceService.identity(for: url)
            }
            let record = DeviceRecord(
                id: id,
                displayName: url.lastPathComponent,
                volumeName: (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? knownRecord?.volumeName,
                bookmark: bookmark,
                lastConnectedAt: Date()
            )
            try await database.upsertDevice(record)
            device = record
            sourceURL = url
            settings = try await database.settings(deviceID: id)
            let savedPath = settings.lastSourceFolderPath ?? ""
            do {
                try await openFolder(relativePath: savedPath)
            } catch {
                try await openFolder(relativePath: "")
            }
            await refreshHistory()
            knownDevices = try await database.devices()
            availableDeviceIDs.insert(id)
            statusMessage = "当前设备已连接，点击即可浏览文件"
        } catch {
            stopAccessingSource()
            throw error
        }
    }

    func scan() async throws {
        try await openFolder(relativePath: currentFolderPath)
    }

    func openFolder(_ folder: SourceFolder) async {
        do {
            try await openFolder(relativePath: folder.relativePath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func navigateToParentFolder() async {
        guard !currentFolderPath.isEmpty else { return }
        let parent = (currentFolderPath as NSString).deletingLastPathComponent
        do {
            try await openFolder(relativePath: parent == "." ? "" : parent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openFolder(relativePath: String) async throws {
        guard let sourceURL, let device else { return }
        isScanning = true
        statusMessage = "正在读取文件夹…"
        defer { isScanning = false }
        let content = try await deviceService.contents(
            rootURL: sourceURL,
            relativePath: relativePath
        )
        let synced = try await database.syncedItemIDs(
            deviceID: device.id,
            itemIDs: content.mediaItems.map(\.id)
        )
        currentFolderPath = relativePath
        folders = content.folders
        items = content.mediaItems.map { item in
            var updated = item
            updated.state = synced.contains(item.id) ? .synced : .neverSynced
            return updated
        }
        deviceCatalog.removeAll(keepingCapacity: false)
        indexedFolderPath = nil
        selection.removeAll()
        settings.lastSourceFolderPath = relativePath
        await persistSettings()
        statusMessage = "\(currentFolderName)：\(folders.count) 个文件夹，\(items.count) 个媒体文件"
    }

    func prepareDownloadIndex() async {
        guard indexedFolderPath != currentFolderPath,
              !isPreparingDownloadIndex,
              let sourceURL,
              let device else { return }
        isPreparingDownloadIndex = true
        let path = currentFolderPath
        defer { isPreparingDownloadIndex = false }
        do {
            let catalog = try await ExternalDeviceService().scan(
                rootURL: sourceURL,
                relativePath: path
            )
            let synced = try await database.syncedItemIDs(
                deviceID: device.id,
                itemIDs: catalog.map(\.id)
            )
            guard self.device?.id == device.id, currentFolderPath == path else { return }
            deviceCatalog = catalog.map { item in
                var updated = item
                updated.state = synced.contains(item.id) ? .synced : .neverSynced
                return updated
            }
            indexedFolderPath = path
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func downloadCount(since date: Date) -> Int {
        filteredDownloadScopeItems.lazy.filter { $0.createdAt >= date && $0.state != .synced }.count
    }

    func toggleSelection(_ item: MediaItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    func setSelection(itemID: String, selected: Bool) {
        if selected {
            selection.insert(itemID)
        } else {
            selection.remove(itemID)
        }
    }

    func selectAllVisible() {
        selectAll(visibleItems)
    }

    func selectAll(_ items: [MediaItem]) {
        let ids = Set(items.map(\.id))
        if ids.isSubset(of: selection) {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
    }

    func setAutomaticSync(_ enabled: Bool) async {
        settings.automaticSyncEnabled = enabled
        await persistSettings()
    }

    func setEarliestDate(_ date: Date?) async {
        settings.earliestCreationDate = date
        selection = selection.intersection(Set(visibleItems.map(\.id)))
        await persistSettings()
    }

    func setPhotoDestination(_ destination: PhotoDestination) async {
        settings.destination = .photoLibrary(destination)
        await persistSettings()
    }

    func setFileDestination(url: URL) async throws {
        settings.destination = .files(try fileDestination(for: url))
        await persistSettings()
    }

    func fileDestination(for url: URL) throws -> FileDestination {
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return FileDestination(bookmark: bookmark, displayName: url.lastPathComponent)
    }

    func setFileDestination(_ destination: FileDestination) async {
        settings.destination = .files(destination)
        await persistSettings()
    }

    func photoCollections(inFolder identifier: String?) async throws -> [PhotoCollectionNode] {
        try await photoLibrary.collections(inFolder: identifier)
    }

    func createPhotoAlbum(named name: String, inFolder identifier: String?) async throws -> PhotoCollectionNode {
        try await photoLibrary.createAlbum(named: name, inFolder: identifier)
    }

    func createPhotoFolder(named name: String, inFolder identifier: String?) async throws -> PhotoCollectionNode {
        try await photoLibrary.createFolder(named: name, inFolder: identifier)
    }

    func syncSelection() async {
        let selected = selectedItems
        let force = selected.contains { $0.state == .synced }
        await startSync(selected, force: force)
    }

    func syncNewItems() async {
        let candidates = visibleItems.filter { $0.state != .synced }
        await startSync(candidates, force: false)
    }

    func syncCurrentNew() async {
        await startSync(filteredDownloadScopeItems.filter { $0.state != .synced }, force: false)
    }

    func syncCurrentAll() async {
        await startSync(filteredDownloadScopeItems, force: true)
    }

    func syncCurrent(since date: Date) async {
        await startSync(filteredDownloadScopeItems.filter { $0.createdAt >= date && $0.state != .synced }, force: false)
    }

    func cancelSync() {
        guard let activeSyncTask else { return }
        isCancellingSync = true
        activeSyncTask.cancel()
    }

    func clearHistory() async {
        do {
            try await database.clearHistory(deviceID: device?.id)
            if sourceURL != nil { try await scan() }
            deviceCatalog.removeAll(keepingCapacity: false)
            indexedFolderPath = nil
            await refreshHistory()
            completionMessage = "该设备的同步历史已清除"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteDevice(_ record: DeviceRecord) async {
        guard progress == nil else { return }
        do {
            try await database.deleteDevice(id: record.id)
            knownDevices.removeAll { $0.id == record.id }
            availableDeviceIDs.remove(record.id)

            if device?.id == record.id {
                stopAccessingSource()
                device = nil
                sourceURL = nil
                folders.removeAll()
                currentFolderPath = ""
                items.removeAll()
                selection.removeAll()
                settings = DeviceSettings()
                syncedHistoryCount = 0
                failedHistoryCount = 0
                deviceCatalog.removeAll(keepingCapacity: false)
                indexedFolderPath = nil
                downloadFormatFilter = .all
                statusMessage = "选择相机、SD 卡或外部存储中的照片和视频文件夹"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshHistory() async {
        guard let device else { return }
        do {
            let counts = try await database.historyCount(deviceID: device.id)
            syncedHistoryCount = counts.synced
            failedHistoryCount = counts.failed
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startSync(_ candidates: [MediaItem], force: Bool) async {
        guard activeSyncTask == nil else { return }
        isCancellingSync = false
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSync(candidates, force: force)
        }
        activeSyncTask = task
        await task.value
        activeSyncTask = nil
        isCancellingSync = false
    }

    private func performSync(_ candidates: [MediaItem], force: Bool) async {
        guard !candidates.isEmpty else {
            completionMessage = "当前范围内没有可传输的照片或视频"
            return
        }
        guard var destination = settings.destination else {
            errorMessage = "请先选择保存相册或文件夹"
            return
        }
        guard let device else {
            errorMessage = "设备已断开，请重新连接后再试"
            return
        }
        do {
            if case .photoLibrary(let photo) = destination {
                let prepared = try await photoLibrary.prepare(photo)
                destination = .photoLibrary(prepared)
                settings.destination = destination
                await persistSettings()
            }
            try Task.checkCancellation()
            progress = SyncProgress(total: candidates.count)
            let summary = await coordinator.run(
                items: candidates,
                deviceID: device.id,
                destination: destination,
                maxConcurrent: settings.maxConcurrentTransfers,
                force: force
            ) { [weak self] value in
                self?.progress = value
            }
            progress = nil
            let displayedIDs = items.map(\.id) + deviceCatalog.map(\.id)
            let synced = try await database.syncedItemIDs(
                deviceID: device.id,
                itemIDs: displayedIDs
            )
            for index in items.indices {
                items[index].state = synced.contains(items[index].id) ? .synced : .neverSynced
            }
            if summary.cancelled > 0 {
                selection.subtract(synced)
            } else {
                selection.removeAll()
            }
            for index in deviceCatalog.indices {
                deviceCatalog[index].state = synced.contains(deviceCatalog[index].id) ? .synced : .neverSynced
            }
            await refreshHistory()
            if summary.cancelled > 0 {
                completionMessage = "传输已取消：成功 \(summary.succeeded)，失败 \(summary.failed)，未传输 \(summary.cancelled)"
            } else {
                completionMessage = "同步完成：成功 \(summary.succeeded)，失败 \(summary.failed)，跳过 \(summary.skipped)"
            }
        } catch is CancellationError {
            progress = nil
            completionMessage = "传输已取消"
        } catch {
            progress = nil
            errorMessage = error.localizedDescription
        }
    }

    private func persistSettings() async {
        guard let device else { return }
        do {
            try await database.saveSettings(settings, deviceID: device.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopAccessingSource() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }
}
