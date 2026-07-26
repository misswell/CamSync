import SwiftUI

struct PhotoSelectionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("photoGridColumnCount") private var columnCount = 5
    @State private var initialSelection = Set<String>()
    var onConfirm: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.items.count) 张 · 已选 \(model.selection.count) 张 · 新增 \(model.newItemCount) 张")
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

                if model.visibleItems.isEmpty {
                    ContentUnavailableView(
                        "没有可选照片",
                        systemImage: "photo.on.rectangle",
                        description: Text("打开“显示已同步”可手动重复下载。")
                    )
                } else {
                    ScrollView {
                        PhotoGrid(items: model.visibleItems)
                    }
                }
            }
            .navigationTitle("选择照片")
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
                        Picker("每行显示", selection: $columnCount) {
                            ForEach(3...6, id: \.self) { count in
                                Text("每行 \(count) 张").tag(count)
                            }
                        }
                    } label: {
                        Label("\(columnCount) 列", systemImage: "square.grid.3x3")
                    }
                    .accessibilityLabel("调整照片列数，当前每行 \(columnCount) 张")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    Button(model.selection.count == model.visibleItems.count && !model.visibleItems.isEmpty ? "取消全选" : "全选") {
                        model.selectAllVisible()
                    }
                }
            }
            .onAppear { initialSelection = model.selection }
        }
    }
}
