import SwiftUI
import AppKit

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var showUpdateDialog = false
    @State private var showRebuildDialog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                if !model.sourceReady { sourceMissingCard }
                runControlCard
                updateCard
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("发现新版本", isPresented: $showUpdateDialog, titleVisibility: .visible) {
            Button("立即更新") {
                Task { _ = await model.updater.upgrade(forceRebuild: false) }
            }
            Button("稍后再说", role: .cancel) {}
        } message: {
            Text("检测到远程仓库有新版本，是否立即开始更新？\n")
                + Text("当前版本：\(versionTag(model.updater.currentCommit))\n")
                + Text("最新版本：\(versionTag(model.updater.remoteCommit))\n\n")
                + Text("提示：更新将短暂停止服务并重新编译依赖，完成后自动重启。")
        }
        .confirmationDialog("确认强制重建？", isPresented: $showRebuildDialog, titleVisibility: .visible) {
            Button("强制重建", role: .destructive) {
                Task { _ = await model.updater.upgrade(forceRebuild: true) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("强制重建将重新拉取依赖并编译，耗时较长，确定继续？")
        }
    }

    // MARK: - 状态卡

    private var statusCard: some View {
        Card(title: nil) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("DeepSeek Harness")
                            .font(.title2.weight(.semibold))
                        StatusTag(text: model.harness.status.displayName, color: model.harness.status.tagColor)
                        if model.harness.status == .building && model.updater.building {
                            StatusTag(text: "升级 / 重建中", color: .blue)
                        }
                    }
                    infoLine("版本", model.harness.version.isEmpty ? "-" : "v\(model.harness.version)")
                    infoLine("Commit", model.harness.commit.isEmpty ? "-" : model.harness.commit)
                    infoLine("进程 PID", model.harness.pid.map(String.init) ?? "-")
                    HStack(spacing: 8) {
                        Text("运行时间").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(model.harness.startedAt.map { Format.duration(context.date.timeIntervalSince($0)) } ?? "-")
                                .font(.callout.monospacedDigit())
                        }
                    }
                }
                Spacer()
                VStack(spacing: 8) {
                    Button {
                        model.openHarness()
                    } label: {
                        Label("进入 Harness", systemImage: "arrow.up.right.square")
                            .frame(width: 140)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.harness.status != .running)
                    Text(model.harness.readyURL?.absoluteString ?? "http://127.0.0.1:\(model.config.serverPort)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if !model.harness.lastMessage.isEmpty {
                Divider()
                Text(model.harness.lastMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func infoLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).font(.callout.monospaced())
        }
    }

    // MARK: - 源码缺失引导

    private var sourceMissingCard: some View {
        Card(title: "源码未就绪") {
            Text("harness 源码不存在：\(model.config.sourcePath)\n可在“应用设置”中修改源码路径，或在此克隆官方仓库（--depth=1，随后自动安装依赖并构建）。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    Task { _ = await model.updater.cloneSource() }
                } label: {
                    Label("克隆并构建", systemImage: "arrow.down.circle")
                }
                .disabled(model.updater.building)
                if model.updater.building {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    // MARK: - 运行控制

    private var runControlCard: some View {
        Card(title: "运行控制") {
            HStack(spacing: 12) {
                if model.harness.status == .running {
                    Button {
                        model.harness.stop()
                    } label: {
                        Label("停止服务", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        model.harness.start()
                    } label: {
                        Label(model.harness.status == .starting ? "服务启动中…" : "启动服务", systemImage: "play.fill")
                    }
                    .disabled(model.harness.status != .stopped)
                }
                Button {
                    model.harness.restart()
                } label: {
                    Label("重启服务", systemImage: "arrow.clockwise")
                }
                .disabled(model.harness.status != .running)
                Spacer()
            }
            .controlSize(.large)
        }
    }

    // MARK: - 更新

    private var updateCard: some View {
        Card(title: "版本维护") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        Task {
                            let has = await model.updater.checkUpdate()
                            if has {
                                showUpdateDialog = true
                            } else if !model.updater.lastError.isEmpty {
                                model.harness.message(model.updater.lastError)
                            } else {
                                model.harness.message("当前已是最新版本")
                            }
                        }
                    } label: {
                        Label(model.updater.checking ? "检查中…" : "检查更新", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(model.updater.checking || model.updater.building)
                    Button(role: .destructive) {
                        showRebuildDialog = true
                    } label: {
                        Label("强制重建", systemImage: "hammer")
                    }
                    .disabled(model.updater.building)
                    if model.updater.building {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                Text("检查远程代码更新，检测到新版本时确认后再同步依赖并构建；强制重建会 reset --hard 后重新拉取全部依赖并完整编译，用于修复异常损坏的环境。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 工具

    private func versionTag(_ commit: String) -> String {
        let v = model.harness.version
        if !v.isEmpty && !commit.isEmpty { return "v\(v) (\(commit))" }
        if !v.isEmpty { return "v\(v)" }
        return commit.isEmpty ? "-" : commit
    }
}

func chooseFolder(_ start: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    let expanded = Paths.expand(start)
    if FileManager.default.fileExists(atPath: expanded) {
        panel.directoryURL = URL(fileURLWithPath: expanded)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url.path
}
