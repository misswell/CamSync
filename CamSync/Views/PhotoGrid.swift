import SwiftUI

struct PhotoGrid: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("photoGridColumnCount") private var columnCount = 5
    let items: [MediaItem]
    private let itemIndices: [String: Int]
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var dragSelectMode: Bool?
    @State private var dragStartIndex: Int?
    @State private var lastAppliedIndex: Int?
    @State private var selectionBeforeDrag = Set<String>()

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: 4, alignment: .top),
            count: min(max(columnCount, 3), 6)
        )
    }

    init(items: [MediaItem]) {
        self.items = items
        self.itemIndices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
    }

    var body: some View {
        VStack(spacing: 0) {
            SelectionPanGestureBridge(
                canBegin: canBeginRangeSelection,
                onBegan: beginRangeSelection,
                onChanged: updateRangeSelection,
                onEnded: endRangeSelection
            )
            .frame(width: 0, height: 0)

            LazyVGrid(columns: columns, alignment: .center, spacing: 6) {
                ForEach(items) { item in
                    PhotoCell(
                        item: item,
                        selected: model.selection.contains(item.id)
                    )
                    .id(item.id)
                    .onTapGesture { model.toggleSelection(item) }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: PhotoCellFrameKey.self,
                                value: [item.id: proxy.frame(in: .global)]
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .onPreferenceChange(PhotoCellFrameKey.self) { cellFrames = $0 }
        .onDisappear { endRangeSelection() }
    }

    private func canBeginRangeSelection(at location: CGPoint) -> Bool {
        cellFrames.values.contains { frame in
            CGRect(x: frame.maxX - 38, y: frame.minY, width: 38, height: 38).contains(location)
        }
    }

    private func endRangeSelection() {
        dragSelectMode = nil
        dragStartIndex = nil
        lastAppliedIndex = nil
        selectionBeforeDrag.removeAll(keepingCapacity: true)
    }

    private func beginRangeSelection(at location: CGPoint) {
        guard let startIndex = itemIndex(at: location) else { return }
        dragStartIndex = startIndex
        lastAppliedIndex = startIndex
        selectionBeforeDrag = model.selection
        dragSelectMode = !selectionBeforeDrag.contains(items[startIndex].id)
        applyRangeSelection(from: startIndex, to: startIndex)
    }

    private func updateRangeSelection(at location: CGPoint) {
        guard let currentIndex = itemIndex(at: location) else { return }
        guard let startIndex = dragStartIndex, let shouldSelect = dragSelectMode else { return }
        guard currentIndex != lastAppliedIndex else { return }

        lastAppliedIndex = currentIndex
        applyRangeSelection(from: startIndex, to: currentIndex, shouldSelect: shouldSelect)
    }

    private func applyRangeSelection(from startIndex: Int, to currentIndex: Int, shouldSelect: Bool? = nil) {
        guard let shouldSelect = shouldSelect ?? dragSelectMode else { return }

        let lower = min(startIndex, currentIndex)
        let upper = max(startIndex, currentIndex)
        let rangeIDs = Set(items[lower...upper].map(\.id))
        var updated = selectionBeforeDrag
        if shouldSelect {
            updated.formUnion(rangeIDs)
        } else {
            updated.subtract(rangeIDs)
        }
        model.selection = updated
    }

    private func itemIndex(at location: CGPoint) -> Int? {
        if let itemID = cellFrames.first(where: { $0.value.contains(location) })?.key {
            return itemIndices[itemID]
        }

        // 手指位于照片间距时，按最近照片继续连续范围，避免选择断裂。
        guard let nearestID = cellFrames.min(by: {
            squaredDistance(from: $0.value, to: location) < squaredDistance(from: $1.value, to: location)
        })?.key else { return nil }
        return itemIndices[nearestID]
    }

    private func squaredDistance(from rect: CGRect, to point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

private struct PhotoCellFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PhotoCell: View {
    let item: MediaItem
    let selected: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            if item.state == .synced {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(4)
            }

            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, selected ? .blue : .black.opacity(0.42))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(selected ? Color.blue : .clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .task(id: item.id) {
            image = await ThumbnailLoader.shared.image(for: item.sourceURL, maxPixelSize: 240)
        }
        .accessibilityLabel("\(item.fileName)，\(item.state == .synced ? "已同步" : "未同步")")
    }
}
