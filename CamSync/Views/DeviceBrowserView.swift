import SwiftUI

struct DeviceBrowserView: View {
    private enum DownloadRequest {
        case selected
        case new
        case all
        case since(Date)
    }

    @EnvironmentObject private var model: AppModel
    @State private var showPhotoSelection = false
    @State private var showDownloadOptions = false
    @State private var showCustomDate = false
    @State private var showDestination = false
    @State private var pendingDownload: DownloadRequest?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                SourceBrowserView { showPhotoSelection = true }
                    .padding()
                    .padding(.bottom, 90)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            downloadBar
        }
        .navigationTitle(model.device?.displayName ?? "设备文件")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPhotoSelection) {
            PhotoSelectionView {
                presentDestination(for: .selected, delay: 0.15)
            }
        }
        .sheet(isPresented: $showDestination) {
            DestinationView(onConfirm: runPendingDownload)
        }
        .sheet(isPresented: $showCustomDate) {
            DownloadDateView(countForDate: model.downloadCount) { date in
                presentDestination(for: .since(date), delay: 0.35)
            }
        }
    }

    private var downloadBar: some View {
        VStack(spacing: 8) {
            if let progress = model.progress {
                ProgressView(value: progress.fraction)
                Text("下载中 \(progress.completed)/\(progress.total) · 成功 \(progress.succeeded) · 失败 \(progress.failed)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                if model.progress != nil {
                    model.cancelSync()
                } else {
                    showDownloadOptions = true
                    Task { await model.prepareDownloadIndex() }
                }
            } label: {
                Label(
                    model.progress == nil ? "下载" : (model.isCancellingSync ? "正在取消…" : "取消传输"),
                    systemImage: model.progress == nil ? "arrow.down.circle.fill" : "xmark.circle.fill"
                )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.progress == nil ? Color.accentColor : .red)
            .disabled(model.device == nil || model.isCancellingSync)
            .popover(
                isPresented: $showDownloadOptions,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .bottom
            ) {
                DownloadScopePopover(
                    selectSelected: { presentDestination(for: .selected) },
                    selectNew: { presentDestination(for: .new) },
                    selectAll: { presentDestination(for: .all) },
                    selectSince: { presentDestination(for: .since($0)) },
                    selectCustomDate: {
                        showDownloadOptions = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            showCustomDate = true
                        }
                    },
                    modifySelection: {
                        showDownloadOptions = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            showPhotoSelection = true
                        }
                    }
                )
                .presentationCompactAdaptation(.popover)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func presentDestination(for request: DownloadRequest, delay: Double = 0.2) {
        pendingDownload = request
        showDownloadOptions = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            showDestination = true
        }
    }

    private func runPendingDownload() {
        guard let request = pendingDownload else { return }
        pendingDownload = nil
        Task {
            switch request {
            case .selected:
                await model.syncSelection()
            case .new:
                await model.syncCurrentNew()
            case .all:
                await model.syncCurrentAll()
            case .since(let date):
                await model.syncCurrent(since: date)
            }
        }
    }
}

private struct DownloadScopePopover: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsTimeRanges = false
    @State private var showsFormatFilters = false
    let selectSelected: () -> Void
    let selectNew: () -> Void
    let selectAll: () -> Void
    let selectSince: (Date) -> Void
    let selectCustomDate: () -> Void
    let modifySelection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("下载哪些照片和视频？")
                .font(.headline)
            Text("范围：\(model.currentFolderName)及其子目录")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.isPreparingDownloadIndex {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在统计当前目录…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            VStack(spacing: 10) {
                scopeButton("已选媒体", count: model.selection.count, systemImage: "checkmark.circle", disabled: model.selection.isEmpty, action: selectSelected)
                scopeButton("新增媒体", count: model.downloadScopeNewCount, systemImage: "sparkles.rectangle.stack", disabled: model.isPreparingDownloadIndex || model.downloadScopeNewCount == 0, action: selectNew)
                scopeButton("全部媒体", count: model.downloadScopeCount, systemImage: "photo.stack", disabled: model.isPreparingDownloadIndex || model.downloadScopeCount == 0, action: selectAll)
            }

            Divider()
            DisclosureGroup(isExpanded: formatExpansion) {
                VStack(spacing: 6) {
                    ForEach(MediaFormatFilter.allCases) { filter in
                        formatButton(filter)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack {
                    Label("按格式", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(model.downloadFormatFilter.title)
                        .font(.subheadline)
                        .foregroundStyle(model.downloadFormatFilter == .all ? Color.secondary : Color.accentColor)
                }
                .frame(minHeight: 44)
            }

            Divider()
            DisclosureGroup(isExpanded: timeRangeExpansion) {
                VStack(spacing: 6) {
                    timeButton("今天（00:00 至现在）", since: Calendar.current.startOfDay(for: Date()))
                    timeButton("最近 24 小时", since: date(daysAgo: 1))
                    timeButton("最近 7 天", since: date(daysAgo: 7))
                    timeButton("最近 30 天", since: date(daysAgo: 30))

                    Button(action: selectCustomDate) {
                        Label("指定开始日期…", systemImage: "calendar")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isPreparingDownloadIndex)
                }
                .padding(.top, 8)
            } label: {
                Label("按时间段", systemImage: "calendar.badge.clock")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }

            Divider()
            Button(action: modifySelection) {
                Label("修改已选媒体", systemImage: "checklist")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(minWidth: 300, idealWidth: 330, maxWidth: 360)
    }

    private func scopeButton(
        _ title: String,
        count: Int,
        systemImage: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text("\(count) 个").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // 两个展开区互斥，避免弹窗同时展开后超出屏幕高度。
    private var formatExpansion: Binding<Bool> {
        Binding(
            get: { showsFormatFilters },
            set: {
                showsFormatFilters = $0
                if $0 { showsTimeRanges = false }
            }
        )
    }

    private var timeRangeExpansion: Binding<Bool> {
        Binding(
            get: { showsTimeRanges },
            set: {
                showsTimeRanges = $0
                if $0 { showsFormatFilters = false }
            }
        )
    }

    private func formatButton(_ filter: MediaFormatFilter) -> some View {
        let count = model.downloadScopeItems.filter { filter.matches($0) }.count
        let isSelected = model.downloadFormatFilter == filter
        return Button {
            model.downloadFormatFilter = filter
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(filter.title)
                Spacer()
                Text("\(count) 个").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func timeButton(_ title: String, since date: Date) -> some View {
        let count = model.downloadCount(since: date)
        return Button { selectSince(date) } label: {
            HStack {
                Text(title)
                Spacer()
                Text("\(count) 个").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isPreparingDownloadIndex || count == 0)
    }

    private func date(daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? .distantPast
    }
}

private struct DownloadDateView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    let countForDate: (Date) -> Int
    let onSelect: (Date) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                DatePicker("开始日期", selection: $date, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                LabeledContent("符合条件", value: "\(countForDate(Calendar.current.startOfDay(for: date))) 个媒体文件")
                    .font(.headline)
                    .padding(.horizontal)
            }
            .padding()
                .navigationTitle("按时间段下载")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("下一步") {
                            let start = Calendar.current.startOfDay(for: date)
                            dismiss()
                            onSelect(start)
                        }
                    }
                }
        }
        .presentationDetents([.medium])
    }
}
