import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
            HistoryView()
                .tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }
        }
        .tint(.blue)
    }
}
