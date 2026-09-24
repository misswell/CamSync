import SwiftUI

struct PhotoSelectionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("photoGridColumnCount") private var columnCount = 5
    @State private var initialSelection = Set<String>()
    @State private var formatFilter: MediaFormatFilter = .all
    var onConfirm: (() -> Void)? = nil

    private var filteredItems: [MediaItem] {
        model.visibleItems.filter { formatFilter.matches($0) }
    }

    private var allFilteredItemsSelected: Bool {
        !filteredItems.isEmpty && Set(filteredItems.map(\.id)).isSubset(of: model.selection)
    }

    private var emptyDescription: String {
        if model.visibleItems.isEmpty {
            return "打开“显示已同步”可手动重复下载。"
        }
        return "当前没有符合“\(formatFilter.title)”的照片或视频。"
    }

    private var emptyTitle: String {
        model.visibleItems.isEmpty ? "没有可选媒体文件" : "没有符合条件的媒体文件"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("共 \(model.items.count) 个 · 当前 \(filteredItems.count) 个 · 已选 \(model.selection.count) 个 · 新增 \(model.newItemCount) 个")
                            .font(.subheadline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text("拖动右上角勾选圆圈，可按行连续选择")
                            .font(.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("显示已同步", isOn: $model.showPreviouslySynced)
                        .labelsHidden()
                    Text("已同步").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .frame(height: 58)
                .background(Color(uiColor: .secondarySystemBackground))

                if filteredItems.isEmpty {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: "photo.on.rectangle.angled",
                        description: Text(emptyDescription)
                    )
                } else {
                    ScrollView {
                        PhotoGrid(items: filteredItems)
                    }
                }
            }
            .navigationTitle("选择照片和视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        model.selection = initialSelection
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下一步") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onConfirm?()
                        }
                    }
                    .disabled(model.selection.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("媒体格式", selection: $formatFilter) {
                            ForEach(MediaFormatFilter.allCases) { filter in
                                Text("\(filter.title)（\(model.visibleItems.filter { filter.matches($0) }.count) 个）")
                                    .tag(filter)
                            }
                        }
                    } label: {
                        Label(formatFilter.title, systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("按媒体格式筛选，当前：\(formatFilter.title)")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("每行显示", selection: $columnCount) {
                            ForEach(3...6, id: \.self) { count in
                                Text("每行 \(count) 张").tag(count)
                            }
                        }
                    } label: {
                        Label("\(columnCount) 列", systemImage: "square.grid.3x3")
                    }
                    .accessibilityLabel("调整媒体列数，当前每行 \(columnCount) 个")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    Button(allFilteredItemsSelected ? "取消全选" : "全选") {
                        model.selectAll(filteredItems)
                    }
                    .disabled(filteredItems.isEmpty)
                }
            }
            .onAppear { initialSelection = model.selection }
        }
    }
}
