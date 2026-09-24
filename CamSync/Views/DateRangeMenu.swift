import SwiftUI

struct DateRangeMenu: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCustomDate = false

    var body: some View {
        Menu {
            Button("全部媒体") { Task { await model.setEarliestDate(nil) } }
            Button("今天（00:00 至现在）") {
                Task { await model.setEarliestDate(Calendar.current.startOfDay(for: Date())) }
            }
            Button("最近 24 小时") { setDays(1) }
            Button("最近 7 天") { setDays(7) }
            Button("最近 30 天") { setDays(30) }
            Button("指定开始日期…") { showCustomDate = true }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .sheet(isPresented: $showCustomDate) {
            CustomDateView(initialDate: model.settings.earliestCreationDate ?? Date())
        }
    }

    private var label: String {
        guard let date = model.settings.earliestCreationDate else { return "全部媒体" }
        return "从 \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func setDays(_ days: Int) {
        let date = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        Task { await model.setEarliestDate(date) }
    }
}

private struct CustomDateView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var initialDate: Date

    var body: some View {
        NavigationStack {
            DatePicker("开始日期", selection: $initialDate, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("同步开始日期")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            Task { await model.setEarliestDate(Calendar.current.startOfDay(for: initialDate)) }
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium])
    }
}
