import SwiftUI
import AppKit

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @State private var lines: [String] = []
    @State private var autoScroll = true
    @State private var showClearConfirm = false
    @State private var streamTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { start() }
        .onDisappear {
            streamTask?.cancel()
            streamTask = nil
        }
        .confirmationDialog("确认清空运行日志？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("确认清空", role: .destructive) {
                model.harness.logs.clear()
                lines.removeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要清空所有历史运行日志吗？清空后将无法恢复。")
        }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 14) {
            Toggle(isOn: $autoScroll) {
                Text("自动滚动")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            Spacer()
            Button {
                scrollToBottom()
            } label: {
                Label("回到底部", systemImage: "arrow.down.to.line")
            }
            .disabled(lines.isEmpty)
            .help("回到底部")
            Button {
                download()
            } label: {
                Label("下载", systemImage: "square.and.arrow.down")
            }
            .help("下载日志")
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("清空", systemImage: "trash")
            }
            .help("清空日志")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 日志体

    private var logBody: some View {
        Group {
            if lines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("暂无日志")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 12).monospaced())
                                    .foregroundStyle(color(for: line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .id("log-\(index)")
                            }
                        }
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                    }
                    .onChange(of: lines.count) {
                        if autoScroll {
                            proxy.scrollTo("log-\(lines.count - 1)", anchor: .bottom)
                        }
                    }
                }
                .background(.background)
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.contains("[ERROR]") || line.contains("[FATAL]") { return .red }
        if line.contains("[WARN]") || line.contains("[WARNING]") { return .orange }
        return .primary
    }

    // MARK: - 数据

    private func start() {
        lines = model.harness.logs.lastLinesFromDisk(limit: 150)
        streamTask = Task {
            for await line in model.harness.logs.subscribe() {
                guard !Task.isCancelled else { return }
                lines.append(line)
                if lines.count > 2000 {
                    lines.removeFirst(lines.count - 2000)
                }
            }
        }
    }

    private func scrollToBottom() {
        autoScroll = true
    }

    private func download() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "harness.log"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.copyItem(at: model.harness.logs.fileURL, to: url)
        } catch {
            model.harness.logs.launcherMessage("下载日志失败: \(error.localizedDescription)", level: "WARN")
        }
    }
}
