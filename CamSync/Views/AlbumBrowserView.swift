import SwiftUI

struct AlbumBrowserLevel: View {
    @EnvironmentObject private var model: AppModel
    let folderID: String?
    let path: [String]
    @Binding var selection: PhotoDestination?
    @Binding var fileSelection: FileDestination?
    let chooseFileFolder: () -> Void

    @State private var collections: [PhotoCollectionNode] = []
    @State private var isLoading = true
    @State private var showCreateDialog = false
    @State private var showNamePrompt = false
    @State private var createKind: PhotoCollectionKind = .album
    @State private var newName = ""

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView("正在读取相册…"); Spacer() }
            } else if collections.isEmpty {
                ContentUnavailableView(
                    "这一层是空的",
                    systemImage: "rectangle.stack",
                    description: Text("点击右上角加号新建相册或文件夹。")
                )
            } else {
                ForEach(collections) { node in
                    if node.kind == .folder {
                        NavigationLink {
                            AlbumBrowserLevel(
                                folderID: node.id,
                                path: path + [node.title],
                                selection: $selection,
                                fileSelection: $fileSelection,
                                chooseFileFolder: chooseFileFolder
                            )
                        } label: {
                            collectionRow(node)
                        }
                    } else {
                        Button { selectAlbum(node) } label: { collectionRow(node) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(path.last ?? "选择保存相册")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        fileSelection = nil
                    } label: {
                        Label("保存到照片相册", systemImage: "photo.on.rectangle")
                    }

                    Button(action: chooseFileFolder) {
                        Label("选择“文件”或 iCloud Drive", systemImage: "folder")
                    }
                } label: {
                    FileDestinationToolbarIcon(isActive: fileSelection != nil)
                }
                .accessibilityLabel("切换保存位置")
                .accessibilityValue(fileSelection == nil ? "照片相册" : "文件或 iCloud Drive")

                Button { showCreateDialog = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建相册或文件夹")
            }
        }
        .task { await reload() }
        .confirmationDialog("在“\(path.last ?? "照片")”中新建", isPresented: $showCreateDialog) {
            Button("新建相册") { beginCreating(.album) }
            Button("新建文件夹") { beginCreating(.folder) }
            Button("取消", role: .cancel) {}
        }
        .alert(createKind == .album ? "新建相册" : "新建文件夹", isPresented: $showNamePrompt) {
            TextField(createKind == .album ? "相册名称" : "文件夹名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("创建") { Task { await createCollection() } }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("将创建在当前层级：\((path.isEmpty ? ["照片"] : path).joined(separator: " / "))")
        }
    }

    private func collectionRow(_ node: PhotoCollectionNode) -> some View {
        HStack(spacing: 13) {
            Image(systemName: node.kind == .folder ? "folder.fill" : "rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(node.kind == .folder ? .orange : .blue)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title).foregroundStyle(.primary)
                Text(node.kind == .folder ? "\(node.childCount) 个项目 · 文件夹" : "\(node.childCount) 个项目 · 相册")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if node.kind == .album, selection?.albumIdentifier == node.id {
                Image(systemName: "checkmark").font(.headline).foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }

    private func selectAlbum(_ album: PhotoCollectionNode) {
        selection = PhotoDestination(
            albumIdentifier: album.id,
            albumName: album.title,
            folderName: path.last,
            folderIdentifier: folderID,
            folderPath: path
        )
    }

    private func beginCreating(_ kind: PhotoCollectionKind) {
        createKind = kind
        newName = ""
        showNamePrompt = true
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do { collections = try await model.photoCollections(inFolder: folderID) }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func createCollection() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            if createKind == .album {
                let album = try await model.createPhotoAlbum(named: name, inFolder: folderID)
                selectAlbum(album)
                await reload()
            } else {
                _ = try await model.createPhotoFolder(named: name, inFolder: folderID)
                await reload()
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}
