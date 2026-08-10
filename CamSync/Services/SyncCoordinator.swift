import Foundation

actor SyncCoordinator {
    private enum ProcessOutcome: Sendable {
        case success
        case failure
        case skipped
        case cancelled
    }

    private let database: SyncDatabase
    private let transferService: TransferService

    init(database: SyncDatabase, transferService: TransferService) {
        self.database = database
        self.transferService = transferService
    }

    func run(
        items: [MediaItem],
        deviceID: String,
        destination: SyncDestination,
        maxConcurrent: Int,
        force: Bool,
        progress: @MainActor @escaping (SyncProgress) -> Void
    ) async -> SyncSummary {
        let orderedItems = items.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.relativePath < rhs.relativePath
            }
            return lhs.createdAt < rhs.createdAt
        }
        var state = SyncProgress(total: orderedItems.count)
        await progress(state)
        var iterator = orderedItems.makeIterator()
        var skipped = 0

        await withTaskGroup(of: (MediaItem, ProcessOutcome).self) { group in
            let workerCount = min(max(1, maxConcurrent), 3, orderedItems.count)
            for _ in 0..<workerCount {
                if let item = iterator.next() {
                    state.currentFileNames.append(item.fileName)
                    group.addTask { await self.process(item, deviceID: deviceID, destination: destination, force: force) }
                }
            }
            await progress(state)

            while let (item, outcome) = await group.next() {
                state.completed += 1
                state.currentFileNames.removeAll { $0 == item.fileName }
                switch outcome {
                case .success:
                    state.succeeded += 1
                case .failure:
                    state.failed += 1
                case .skipped:
                    skipped += 1
                case .cancelled:
                    break
                }
                await progress(state)

                if Task.isCancelled {
                    group.cancelAll()
                } else if let next = iterator.next() {
                    state.currentFileNames.append(next.fileName)
                    await progress(state)
                    group.addTask { await self.process(next, deviceID: deviceID, destination: destination, force: force) }
                }
            }
        }
        let cancelled = max(0, items.count - state.succeeded - state.failed - skipped)
        return SyncSummary(
            succeeded: state.succeeded,
            failed: state.failed,
            skipped: skipped,
            cancelled: cancelled
        )
    }

    private func process(
        _ item: MediaItem,
        deviceID: String,
        destination: SyncDestination,
        force: Bool
    ) async -> (MediaItem, ProcessOutcome) {
        do {
            try Task.checkCancellation()
            guard let token = try await database.beginAttempt(item: item, deviceID: deviceID, force: force) else {
                return (item, .skipped)
            }
            do {
                try Task.checkCancellation()
                let result = try await transferService.transfer(item, to: destination)
                try await database.finishSuccess(
                    token: token,
                    item: item,
                    deviceID: deviceID,
                    destination: destination,
                    result: result
                )
                return (item, .success)
            } catch is CancellationError {
                try? await database.finishCancelled(token: token)
                return (item, .cancelled)
            } catch {
                try? await database.finishFailure(token: token, error: error)
                return (item, .failure)
            }
        } catch is CancellationError {
            return (item, .cancelled)
        } catch {
            return (item, .failure)
        }
    }
}
