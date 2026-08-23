import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = LauncherConfig()
    @State private var draftReady = false
    @State private var validationError: String?
    @State private var showRestartConfirm = false
    @State private var showRepairConfirm = false

    private let proxyRegex = try! NSRegularExpression(pattern: #"^(?i)(http|https|socks5|socks5h)://"#)

    private var dirty: Bool { draft != model.config }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                coreCard
                environmentCard
                networkCard
                repairCard
                footer
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !draftReady {
                draft = model.config
                draftReady = true
            }
        }
        .confirmationDialog("确认保存并重启核心服务？", isPresented: $showRestartConfirm, titleVisibility: .visible) {
            Button("保存并重启") {
                performSave()
                model.harness.restart()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("检测到服务端口已由 \(model.config.serverPort) 变更为 \(Int(draft.serverPort))。保存设置后，系统将自动重启 DeepSeek Harness 后端进程以应用新端口。当前所有正在执行的任务可能会短暂中断，是否确认继续？")
        }
        .confirmationDialog("确认重置运行环境？", isPresented: $showRepairConfirm, titleVisibility: .visible) {
            Button("确认重置", role: .destructive) { model.repair() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作将终止当前服务，清空 web profile 与所有第三方插件、依赖修改与补丁配置。您的模型 API 密钥、历史会话记录与系统设置将完整保留。是否确认继续？")
        }
    }

    // MARK: - 核心服务

    private var coreCard: some View {
        Card(title: "核心服务") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("服务端口").frame(width: 110, alignment: .leading)
                    TextField("3080", value: $draft.serverPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Spacer()
                }
                Text("DeepSeek Harness 本地后端监听端口（默认 3080，监听 127.0.0.1），“进入 Harness”将打开 http://127.0.0.1:\(draft.serverPort)。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 运行环境

    private var environmentCard: some View {
        Card(title: "运行环境") {
            VStack(alignment: .leading, spacing: 12) {
                pathRow(title: "node 路径",
                        value: $draft.nodePath,
                        placeholder: "留空自动探测",
                        hint: nodeHint)
                pathRow(title: "harness 源码路径",
                        value: $draft.sourcePath,
                        placeholder: "harness 仓库路径",
                        hint: model.sourceReady ? "已找到 package.json" : "⚠️ 未找到 package.json，请检查路径或先克隆构建")
                pathRow(title: "DSH_HOME",
                        value: $draft.dshHome,
                        placeholder: "默认 ~/.dsh",
                        hint: "profile、凭据、工作区数据所在目录，与手动运行 dsh 共享")
                Toggle(isOn: $draft.autoRunOnLaunch) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启动 App 时自动运行服务")
                        Text("退出 App（⌘Q）会停止服务；仅关闭窗口时服务继续运行。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var nodeHint: String {
        if let tc = model.toolchainCache {
            return "检测到：\(tc.nodeURL.path)（\(tc.nodeVersion)\(tc.nodeVersionOK ? "" : " ⚠️ 不满足要求")）"
        }
        return "⚠️ 未检测到 node，请手动指定（Homebrew 通常在 /opt/homebrew/bin/node）"
    }

    private func pathRow(title: String, value: Binding<String>, placeholder: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).frame(width: 110, alignment: .leading)
                TextField(placeholder, text: value)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button("选择…") {
                    if let dir = chooseFolder(value.wrappedValue) {
                        value.wrappedValue = dir
                    }
                }
            }
            HStack {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 118)
        }
    }

    // MARK: - 网络代理

    private var networkCard: some View {
        Card(title: "网络代理") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("代理地址").frame(width: 110, alignment: .leading)
                    TextField("例如 http://192.168.1.100:7890 或 socks5://192.168.1.100:7890", text: $draft.networkProxy)
                        .textFieldStyle(.roundedBorder)
                }
                Text("HTTP / SOCKS5 代理，用于 git 拉取仓库与 pnpm 安装依赖，留空使用系统直连。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 重置修复

    private var repairCard: some View {
        Card(title: "重置修复") {
            VStack(alignment: .leading, spacing: 10) {
                Text("适用于插件冲突、环境损坏或服务启动异常等场景。将移除 web profile 与所有第三方插件并恢复纯净环境，您的模型 API 密钥、历史会话记录与系统设置将完整保留。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    showRepairConfirm = true
                } label: {
                    Label("重置", systemImage: "arrow.counterclockwise")
                }
                .disabled(model.harness.status == .building || model.harness.status == .starting)
            }
        }
    }

    // MARK: - 底部操作

    private var footer: some View {
        HStack(spacing: 12) {
            if let validationError {
                Text(validationError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if let err = model.configSaveError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("取消") {
                draft = model.config
                validationError = nil
            }
            .disabled(!dirty)
            Button {
                save()
            } label: {
                Text("保存设置")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!dirty)
        }
    }

    // MARK: - 保存

    private func save() {
        guard draft.serverPort >= 1, draft.serverPort <= 65535 else {
            validationError = "端口范围必须在 1 ~ 65535 之间"
            return
        }
        let proxy = draft.networkProxy.trimmingCharacters(in: .whitespaces)
        if !proxy.isEmpty, proxyRegex.firstMatch(in: proxy, range: NSRange(proxy.startIndex..., in: proxy)) == nil {
            validationError = "代理地址需以 http://、https:// 或 socks5:// 开头"
            return
        }
        if draft.serverPort != model.config.serverPort, !ConfigStore.isPortAvailable(Int(draft.serverPort)) {
            validationError = "端口 \(draft.serverPort) 已被占用，请更换端口"
            return
        }
        validationError = nil
        if draft.serverPort != model.config.serverPort && model.harness.status == .running {
            showRestartConfirm = true
            return
        }
        performSave()
    }

    private func performSave() {
        model.saveConfig(draft)
    }
}
