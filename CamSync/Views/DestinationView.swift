import SwiftUI
import UniformTypeIdentifiers

struct DestinationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var photoSelection: PhotoDestination?
    @State private var fileSelection: FileDestination?
    @State private var showFolderPicker = false
    @State private var isConfirming = false
    var onConfirm: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            AlbumBrowserLevel(
                folderID: nil,
                path: [],
                selection: $photoSelection,
                fileSelection: $fileSelection,
                chooseFileFolder: { showFolderPicker = true }
            )
        }
        .safeAreaInset(edge: .bottom) {
            destinationActions
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            do {
                fileSelection = try model.fileDestination(for: url)
                photoSelection = nil
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
        .onChange(of: photoSelection) { _, newValue in
            if newValue != nil { fileSelection = nil }
        }
        .onAppear { restoreCurrentSelection() }
    }

    private var destinationActions: some View {
        VStack(spacing: 10) {
            if photoSelection == nil && fileSelection == nil {
                Text("请在当前文件夹中选择或新建相册，然后开始传输")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let fileSelection {
                Label("文件 · \(fileSelection.displayName)", systemImage: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }

            Button(action: confirmSelection) {
                HStack {
                    if isConfirming {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.down.to.line")
                    }
                    Text(confirmButtonTitle)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .disabled((photoSelection == nil && fileSelection == nil) || isConfirming)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var confirmButtonTitle: String {
        if let photoSelection {
            return "开始传输到“\(photoSelection.albumName)”"
        }
        if let fileSelection {
            return "开始传输到“\(fileSelection.displayName)”"
        }
        return "请先选择保存位置"
    }

    private func restoreCurrentSelection() {
        switch model.settings.destination {
        case .photoLibrary(let destination):
            photoSelection = destination
        case .files(let destination):
            fileSelection = destination
        case nil:
            break
        }
    }

    private func confirmSelection() {
        guard !isConfirming else { return }
        isConfirming = true
        Task {
            if let photoSelection {
                await model.setPhotoDestination(photoSelection)
            } else if let fileSelection {
                await model.setFileDestination(fileSelection)
            } else {
                isConfirming = false
                return
            }
            dismiss()
            DispatchQueue.main.async {
                onConfirm?()
            }
        }
    }
}

struct FileDestinationToolbarIcon: View {
    let isActive: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: isActive ? "folder.fill" : "folder")
                .font(.system(size: 18, weight: .semibold))

            Image(systemName: "icloud.fill")
                .font(.system(size: 8, weight: .bold))
                .padding(2)
                .background(Color(uiColor: .systemBackground), in: Circle())
                .offset(x: 3, y: 2)
        }
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
    }
}
