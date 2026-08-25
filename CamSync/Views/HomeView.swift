import SwiftUI
import UniformTypeIdentifiers
import Combine

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSourcePicker = false
    @State private var showDeviceBrowser = false
    @State private var isOpeningDevice = false
    @State private var devicePendingDeletion: DeviceRecord?
    @State private var showDeleteDeviceConfirmation = false
    private let availabilityTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    connectionCard
                    deviceHistoryCard
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("CamSync")
            .fileImporter(
                isPresented: $showSourcePicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task {
                    do {
                        try await model.connect(url: url)
                        showDeviceBrowser = true
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                }
            }
            .sheet(isPresented: $showDeviceBrowser) {
                NavigationStack {
                    DeviceBrowserView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { showDeviceBrowser = false }
                            }
                        }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled(model.progress != nil)
            }
            .alert("出现问题", isPresented: errorPresented) {
                Button("好", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "未知错误") }
            .alert("CamSync", isPresented: completionPresented) {
                Button("好", role: .cancel) { model.completionMessage = nil }
            } message: { Text(model.completionMessage ?? "") }
            .confirmationDialog(
                "删除历史设备？",
                isPresented: $showDeleteDeviceConfirmation,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    guard let record = devicePendingDeletion else { return }
                    devicePendingDeletion = nil
                    Task { await model.deleteDevice(record) }
                }
                Button("取消", role: .cancel) {
                    devicePendingDeletion = nil
                }
            } message: {
                Text("将从历史设备列表中移除“\(devicePendingDeletion?.historyDisplayName ?? "该设备")”。不会删除已经复制到手机的照片。")
            }
            .onReceive(availabilityTimer) { _ in
                guard !isOpeningDevice, model.progress == nil else { return }
                Task { await model.refreshDeviceAvailability() }
            }
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(currentDeviceAvailable ? Color.green.opacity(0.14) : Color.blue.opacity(0.12))
                    Image(systemName: currentDeviceAvailable ? "externaldrive.fill.badge.checkmark" : "camera.on.rectangle")
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(currentDeviceAvailable ? .green : .blue)
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentAvailableRecord?.historyDisplayName ?? "连接你的相机").font(.headline)
                    Text(currentDeviceAvailable ? "当前设备已连接，可直接浏览文件" : "选择相机、SD 卡或外部存储")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            Button {
                if let record = currentAvailableRecord {
                    openHistoryDevice(record)
                } else {
                    showSourcePicker = true
                }
            } label: {
                HStack {
                    if isOpeningDevice { ProgressView().tint(.white) }
                    Image(systemName: currentDeviceAvailable ? "folder" : "externaldrive.badge.plus")
                    Text(currentDeviceAvailable ? "浏览设备文件" : "选择已连接的设备")
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isOpeningDevice || model.progress != nil)

            if currentDeviceAvailable {
                Button("重新选择设备") { showSourcePicker = true }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
            }
        }
        .cardStyle()
    }

    private var deviceHistoryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("历史设备", systemImage: "clock.arrow.circlepath")
                .font(.headline)

            if model.knownDevices.isEmpty {
                Text("选择过的设备会显示在这里")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.knownDevices) { record in
                        Button {
                            openHistoryDevice(record)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: model.availableDeviceIDs.contains(record.id) ? "externaldrive.fill.badge.checkmark" : "externaldrive")
                                    .font(.title3)
                                    .foregroundStyle(model.availableDeviceIDs.contains(record.id) ? .green : .secondary)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.historyDisplayName)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(record.lastConnectedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.availableDeviceIDs.contains(record.id) {
                                    Text(model.device?.id == record.id ? "当前设备 · 可用" : "可用")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                } else {
                                    Text("未连接")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                devicePendingDeletion = record
                                showDeleteDeviceConfirmation = true
                            } label: {
                                Label("删除历史设备", systemImage: "trash")
                            }
                        }

                        if record.id != model.knownDevices.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    private var currentDeviceAvailable: Bool {
        currentAvailableRecord != nil
    }

    private var currentAvailableRecord: DeviceRecord? {
        if let device = model.device, model.availableDeviceIDs.contains(device.id) {
            return model.knownDevices.first(where: { $0.id == device.id }) ?? device
        }
        return model.knownDevices.first(where: { model.availableDeviceIDs.contains($0.id) })
    }

    private func openHistoryDevice(_ record: DeviceRecord) {
        guard !isOpeningDevice else { return }
        if model.device?.id == record.id, model.availableDeviceIDs.contains(record.id) {
            showDeviceBrowser = true
            return
        }
        isOpeningDevice = true
        Task {
            defer { isOpeningDevice = false }
            do {
                try await model.connect(record: record)
                showDeviceBrowser = true
            } catch {
                model.errorMessage = "该设备当前不可用，请连接设备后再试。"
                await model.refreshDeviceAvailability()
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var completionPresented: Binding<Bool> {
        Binding(get: { model.completionMessage != nil }, set: { if !$0 { model.completionMessage = nil } })
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
