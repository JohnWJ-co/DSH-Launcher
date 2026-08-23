import SwiftUI

struct PluginsView: View {
    @Environment(AppModel.self) private var model
    @State private var commandText = ""
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var removeTarget: PluginService.PluginItem?
    @State private var showRestartConfirm = false

    enum Filter: Hashable {
        case all, live, disabled
    }

    private var preview: PluginPreview? {
        commandText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : PluginParsing.preview(commandText)
    }

    private var counts: (all: Int, live: Int, disabled: Int) {
        let list = model.plugins.list
        return (list.count,
                list.filter { $0.state == "live" }.count,
                list.filter { $0.state == "disabled" }.count)
    }

    private var filtered: [PluginService.PluginItem] {
        let list = model.plugins.list
        let base: [PluginService.PluginItem]
        switch filter {
        case .all: base = list
        case .live: base = list.filter { $0.state == "live" }
        case .disabled: base = list.filter { $0.state == "disabled" }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.name.lowercased().contains(q)
                || $0.descriptionText.lowercased().contains(q)
                || $0.author.lowercased().contains(q)
                || $0.keywords.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.plugins.needsRestart { restartBanner }
                installPanel
                filterBar
                pluginList
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("确认卸载插件？", isPresented: Binding(
            get: { removeTarget != nil },
            set: { if !$0 { removeTarget = nil } }), titleVisibility: .visible) {
            Button("确认卸载", role: .destructive) {
                if let target = removeTarget {
                    model.plugins.removeOne(target.name)
                }
                removeTarget = nil
            }
            Button("取消", role: .cancel) { removeTarget = nil }
        } message: {
            Text("确定要卸载插件「\(removeTarget?.name ?? "")」吗？卸载后将自动清理相关的运行时依赖与配置补丁。")
        }
        .confirmationDialog("确认立即重启服务？", isPresented: $showRestartConfirm, titleVisibility: .visible) {
            Button("确认重启") {
                model.plugins.clearNeedsRestart()
                model.harness.restart()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("检测到插件配置已更新，为了使改动完全生效需要重启服务。重启将短暂中断当前所有 AI 对话连接，是否确认继续？")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Text("共 \(model.plugins.list.count) 个插件")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !model.plugins.message.isEmpty {
                Label(model.plugins.message,
                      systemImage: model.plugins.ok == false ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(model.plugins.ok == false ? Color.orange : Color.green)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                Task { await model.plugins.refreshList() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新插件列表")
            .disabled(model.plugins.loading)
        }
    }

    // MARK: - 重启提醒

    private var restartBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("插件配置已变更").font(.callout.weight(.semibold))
                Text("检测到插件安装或配置更新，为了使改动完全生效，建议重启服务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重启服务") { showRestartConfirm = true }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 安装面板

    private var installPanel: some View {
        Card(title: "安装新插件") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("例如: dsh plugin --profile web add dshmarket", text: $commandText)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit { install() }
                HStack(spacing: 8) {
                    Text("支持: npm 包、@scoped 包、github:user/repo")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Link("插件精选列表", destination: URL(string: "https://awesome-dsh-plugin.com/zh")!)
                        .font(.caption)
                    Spacer()
                    if model.plugins.running {
                        Button(role: .destructive) {
                            model.plugins.cancel()
                        } label: {
                            Label("取消", systemImage: "xmark.circle")
                        }
                    } else {
                        Button {
                            install()
                        } label: {
                            Label("安装", systemImage: "arrow.down.circle")
                        }
                        .disabled(!(preview?.valid ?? false))
                    }
                }
                if let preview {
                    if preview.valid {
                        Text("将执行: \(preview.command ?? "")")
                            .font(.caption.monospaced())
                            .foregroundStyle(.green)
                            .textSelection(.enabled)
                    } else {
                        Text(preview.reason ?? "命令解析失败")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func install() {
        guard let preview, preview.valid else { return }
        model.plugins.run(commandText)
    }

    // MARK: - 筛选

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("筛选", selection: $filter) {
                Text("全部 (\(counts.all))").tag(Filter.all)
                Text("运行中 (\(counts.live))").tag(Filter.live)
                Text("已停用 (\(counts.disabled))").tag(Filter.disabled)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            TextField("搜索插件名 / 描述 / 作者...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var pluginList: some View {
        if model.plugins.loading && !model.plugins.loaded {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在获取插件列表…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if model.plugins.list.isEmpty {
            VStack(spacing: 8) {
                Text("暂无已安装插件").font(.headline)
                Text("使用上方安装面板，或先运行一次服务以初始化 web profile").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if filtered.isEmpty {
            VStack(spacing: 8) {
                Text("未找到匹配的插件").font(.headline)
                Button("重置筛选条件") {
                    filter = .all
                    searchText = ""
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(spacing: 8) {
                ForEach(filtered) { item in
                    PluginRow(item: item) { target in
                        removeTarget = target
                    }
                }
            }
        }
    }
}

// MARK: - 单个插件行

private struct PluginRow: View {
    @Environment(AppModel.self) private var model
    let item: PluginService.PluginItem
    let onRemove: (PluginService.PluginItem) -> Void

    private var stateTag: some View {
        switch item.state {
        case "live": return StatusTag(text: "运行中", color: .green)
        case "disabled": return StatusTag(text: "已停用", color: .gray)
        default: return StatusTag(text: "普通依赖", color: .orange)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { item.state != "disabled" },
            set: { model.plugins.toggle(item.name, enabled: $0) })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.body.weight(.semibold))
                        .textSelection(.enabled)
                    if !item.version.isEmpty {
                        StatusTag(text: "v\(item.version)", color: .secondary)
                    }
                    stateTag
                    if item.isProtected {
                        StatusTag(text: "系统核心", color: .blue)
                    }
                }
                if !item.descriptionText.isEmpty {
                    Text(item.descriptionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 14) {
                    if !item.author.isEmpty {
                        Text("作者: \(item.author)")
                    }
                    if !item.spec.isEmpty {
                        Text("来源: \(item.spec)").textSelection(.enabled)
                    }
                    if !item.homepage.isEmpty, let url = URL(string: item.homepage) {
                        Link("主页", destination: url)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                Toggle("", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(item.isProtected)
                    .help(item.isProtected
                          ? "核心基础设施插件受到保护，不可停用"
                          : (item.state == "disabled" ? "已停用" : "已启用"))
                HStack(spacing: 4) {
                    Button("更新") { model.plugins.updateOne(item.name) }
                        .disabled(model.plugins.running)
                        .help("检查并拉取该插件最新版本")
                    Button("卸载", role: .destructive) { onRemove(item) }
                        .disabled(item.isProtected)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
