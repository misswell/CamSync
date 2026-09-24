import SwiftUI

struct SourceBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("sourceGridColumnCount") private var columnCount = 5
    let onOpenPhotos: () -> Void

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 44), spacing: 8, alignment: .top),
            count: min(max(columnCount, 3), 6)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if model.canNavigateBack {
                    Button {
                        Task { await model.navigateToParentFolder() }
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 32, height: 32)
                            .background(Color.blue.opacity(0.1), in: Circle())
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.currentFolderName).font(.title3.bold())
                    Text(model.currentFolderBreadcrumb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Menu {
                    Picker("每行显示", selection: $columnCount) {
                        ForEach(3...6, id: \.self) { count in
                            Text("每行 \(count) 个").tag(count)
                        }
                    }
                } label: {
                    Label("\(columnCount) 列", systemImage: "square.grid.3x3")
                        .font(.subheadline.weight(.medium))
                }
                .accessibilityLabel("调整文件夹列数，当前每行 \(columnCount) 个")
                if model.isScanning { ProgressView() }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(model.folders) { folder in
                    Button {
                        Task { await model.openFolder(folder) }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 32, weight: .regular))
                                .foregroundStyle(.orange)
                                .frame(height: 38)
                            Text(folder.name)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .top)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开文件夹 \(folder.name)")
                }

                if !model.items.isEmpty {
                    Button(action: onOpenPhotos) {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 29, weight: .regular))
                                .foregroundStyle(.blue)
                                .frame(height: 38)
                            Text("照片和视频 \(model.items.count)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .top)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开照片和视频，共 \(model.items.count) 个，\(model.newItemCount) 个新增")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if model.folders.isEmpty && model.items.isEmpty && !model.isScanning {
                ContentUnavailableView("空文件夹", systemImage: "folder", description: Text("这里没有子文件夹、照片或视频。"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
    }
}
