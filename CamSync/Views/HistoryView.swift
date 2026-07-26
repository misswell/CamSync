import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                Section("当前设备") {
                    if let device = model.device {
                        LabeledContent("名称", value: device.displayName)
                        LabeledContent("上次连接", value: device.lastConnectedAt.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        ContentUnavailableView("尚未连接设备", systemImage: "externaldrive")
                    }
                }
                Section("同步账本") {
                    Label {
                        LabeledContent("已成功同步", value: "\(model.syncedHistoryCount)")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Label {
                        LabeledContent("失败或中断尝试", value: "\(model.failedHistoryCount)")
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                }
                Section {
                    Button("清除当前设备的同步历史", role: .destructive) { confirmClear = true }
                        .disabled(model.device == nil || model.progress != nil)
                        .popover(
                            isPresented: $confirmClear,
                            attachmentAnchor: .rect(.bounds),
                            arrowEdge: .bottom
                        ) {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("清除同步历史？", systemImage: "trash")
                                    .font(.headline)
                                    .foregroundStyle(.red)
                                Text("清除后，这些照片会重新被视为未同步，但不会删除已经复制到手机的照片。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("取消", role: .cancel) { confirmClear = false }
                                    Spacer()
                                    Button("确认清除", role: .destructive) {
                                        confirmClear = false
                                        Task { await model.clearHistory() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.red)
                                }
                            }
                            .padding(18)
                            .frame(minWidth: 300, idealWidth: 330, maxWidth: 360)
                            .presentationCompactAdaptation(.popover)
                        }
                } footer: {
                    Text("清除后，这些照片会重新被视为未同步；不会删除手机相册或文件中的照片。")
                }
                Section("可靠性") {
                    Label("最多三张照片并发传输", systemImage: "arrow.triangle.branch")
                    Label("失败与中断不会标记成功", systemImage: "checkmark.shield")
                    Label("每个设备独立保存设置与记录", systemImage: "externaldrive.connected.to.line.below")
                }
            }
            .navigationTitle("同步记录")
            .task { await model.refreshHistory() }
            .refreshable { await model.refreshHistory() }
        }
    }
}
