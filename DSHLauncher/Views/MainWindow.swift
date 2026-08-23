import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Page = .overview

    enum Page: String, Hashable, Identifiable, CaseIterable {
        case overview = "概览"
        case workspace = "工作区"
        case plugins = "插件管理"
        case logs = "运行日志"
        case settings = "应用设置"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("概览", systemImage: "gauge")
                    .tag(Page.overview)
                Label("工作区", systemImage: "square.stack.3d.up")
                    .tag(Page.workspace)
                Label("插件管理", systemImage: "puzzlepiece.extension")
                    .tag(Page.plugins)
                Label("运行日志", systemImage: "doc.text")
                    .tag(Page.logs)
                Label("应用设置", systemImage: "gearshape")
                    .tag(Page.settings)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) {
                StatusFooter()
                    .padding(8)
            }
        } detail: {
            Group {
                switch selection {
                case .overview: OverviewView()
                case .workspace: WorkspaceView()
                case .plugins: PluginsView()
                case .logs: LogsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(selection.rawValue)
    }
}

/// 侧边栏底部的迷你状态条
private struct StatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(model.harness.status.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if model.harness.status == .running {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onTapGesture { model.openHarness() }
            }
        }
    }

    private var color: Color {
        switch model.harness.status {
        case .running: .green
        case .starting: .orange
        case .building: .blue
        case .stopped: .gray
        }
    }
}
