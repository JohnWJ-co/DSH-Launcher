import Foundation
import AppKit

/// 聚合模型：配置、harness 服务、升级、插件、工作区；供 SwiftUI 直接绑定。
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    static let launcherVersion = "1.0"

    let harness: HarnessService
    let updater: UpdateService
    let plugins: PluginService
    let workspaceMonitor = WorkspaceMonitor()

    private(set) var config: LauncherConfig
    private(set) var toolchainCache: Toolchain?
    private(set) var workspaceList: [WorkspaceInfo] = []
    private(set) var configSaveError: String?
    private let configStore: ConfigStore

    private init() {
        let store = ConfigStore(url: Paths.configFile)
        configStore = store
        config = store.load()
        harness = HarnessService(configProvider: { AppModel.shared.config },
                                 toolchainProvider: { AppModel.shared.toolchainCache })
        updater = UpdateService(harness: harness,
                                configProvider: { AppModel.shared.config },
                                toolchainProvider: { AppModel.shared.toolchainCache })
        plugins = PluginService(logs: harness.logs,
                                configProvider: { AppModel.shared.config },
                                toolchainProvider: { AppModel.shared.toolchainCache },
                                harnessStatus: { AppModel.shared.harness.status })
    }

    var sourceReady: Bool {
        FileManager.default.fileExists(atPath: config.sourceURL.appendingPathComponent("package.json").path)
    }

    // MARK: - 启动 / 退出

    func boot() {
        refreshToolchain()
        harness.logs.launcherMessage("DSH Launcher 启动 (v\(Self.launcherVersion))")
        if let tc = toolchainCache {
            harness.logs.launcherMessage("node: \(tc.nodeURL.path) (\(tc.nodeVersion))" +
                (tc.nodeVersionOK ? "" : " ⚠️ 不满足 dsh 要求 ^22.19.0 || >=24"))
            if tc.corepackURL != nil {
                harness.logs.launcherMessage("pnpm 经由 corepack 调用（尊重源码钉死版本）")
            }
        } else {
            harness.message("未找到 node，请在“应用设置”中指定 node 路径")
            harness.logs.launcherMessage("未找到可用的 node，请在设置中手动指定", level: "WARN")
        }
        harness.startWatchdog()
        harness.refreshMeta()
        if !sourceReady {
            harness.logs.launcherMessage("harness 源码不存在：\(config.sourcePath)", level: "WARN")
        }

        // 上次残留清理（pid 文件 + 端口）
        let cfg = config
        let logs = harness.logs
        Task.detached(priority: .userInitiated) {
            HarnessService.cleanupOrphans(config: cfg, logs: logs)
        }

        // 工作区监听
        workspaceMonitor.onWorkspaces = { [weak self] list in
            self?.workspaceList = list
        }
        restartWorkspaceMonitor()

        Task { await plugins.refreshList() }

        // 网络代理写入 git 配置
        let src = config.sourceURL
        let proxy = config.networkProxy
        Task { await GitService.applyGitHttpProxy(sourceURL: src, proxy: proxy) }

        if config.autoRunOnLaunch {
            harness.start()
        }
    }

    func shutdownForTermination() {
        harness.shutdownSync()
    }

    func refreshToolchain() {
        toolchainCache = Toolchain.resolve(config: config)
    }

    func restartWorkspaceMonitor() {
        workspaceMonitor.start(dshHomeProvider: { [weak self] in self?.config.dshHome ?? "" })
    }

    // MARK: - 配置

    func saveConfig(_ newConfig: LauncherConfig) {
        let old = config
        do {
            try configStore.save(newConfig)
            config = newConfig
            refreshToolchain()
            configSaveError = nil
            harness.logs.launcherMessage("应用设置保存成功")

            if old.networkProxy != newConfig.networkProxy {
                let src = newConfig.sourceURL
                let proxy = newConfig.networkProxy
                Task { await GitService.applyGitHttpProxy(sourceURL: src, proxy: proxy) }
            }
            if old.sourcePath != newConfig.sourcePath {
                harness.refreshMeta()
            }
            if old.dshHome != newConfig.dshHome {
                restartWorkspaceMonitor()
                Task { await plugins.refreshList() }
            }
        } catch {
            configSaveError = "保存设置失败: \(error.localizedDescription)"
        }
    }

    // MARK: - 打开 harness

    func openHarness() {
        let url = harness.readyURL ?? URL(string: "http://127.0.0.1:\(config.serverPort)")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - 重置修复（保留凭据与设置，清 web profile + 插件数据）

    func repair() {
        guard harness.status != .building, harness.status != .starting else {
            harness.message("当前状态不允许重置，请稍后再试")
            return
        }
        let wasRunning = harness.status == .running
        Task {
            if wasRunning { await harness.stopAndWait() }
            guard harness.beginBuilding() else { return }
            harness.logs.launcherMessage("重置运行环境：清空 web profile 与插件数据（保留 API 凭据与系统设置）")
            let profileWeb = Paths.dshHome(config.dshHome).appendingPathComponent("profiles/web")
            try? FileManager.default.removeItem(at: profileWeb)
            try? FileManager.default.removeItem(at: Paths.allowBuildsSidecar)
            harness.refreshMeta()
            await plugins.refreshList()
            restartWorkspaceMonitor()
            harness.endBuilding()
            harness.message("重置完成，下次启动服务时将自动重建默认 web profile")
            harness.logs.launcherMessage("重置完成")
            if wasRunning {
                harness.start()
            }
        }
    }
}
