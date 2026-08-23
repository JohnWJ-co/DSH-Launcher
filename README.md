# DSH Launcher

DeepSeek Harness 的 macOS 原生启动器（Swift / SwiftUI，macOS 14+），功能对齐飞牛 fnOS 版 [deepseek.harness.fnos](https://github.com/yuexps/deepseek.harness.fnos)。

## 构建

```sh
cd DSH-Lancher
xcodebuild -project DSHLauncher.xcodeproj -scheme DSHLauncher -configuration Debug build
# 产物: ~/Library/Developer/Xcode/DerivedData/DSHLauncher-*/Build/Products/Debug/DSHLauncher.app
```

或直接用 Xcode 打开 `DSHLauncher.xcodeproj`，⌘R 运行。

单元测试：

```sh
xcodebuild -project DSHLauncher.xcodeproj -scheme DSHLauncher -destination 'platform=macOS' test
```

## 使用

1. 首次启动自动探测 node（Homebrew/nvm/volta）与 corepack；默认 harness 源码路径为本机已有的
   `~/Documents/project/deepseek-harness`，均可在「应用设置」修改。
2. 概览页点「启动服务」，就绪后点「进入 Harness」用默认浏览器打开 `http://127.0.0.1:<端口>`（默认 3080）；
   项目文件夹在 harness Web UI 内自由选择，启动器不做限定。
3. API Key 在 harness Web UI 的 Settings → Models 里配置（保存在 `$DSH_HOME/.credentials.yaml`）。

五个页面与飞牛版一一对应：概览（启停/重启/检查更新/升级/强制重建）、工作区（只读监视 + Finder 定位）、
插件管理（`dsh plugin` 命令解析/预览/执行/取消 + 六类 pnpm 故障自愈 + cordis.patch.yml 启停 + allowBuilds）、
运行日志（3MB×3 轮转 + 实时流）、应用设置。

## 数据落点

| 内容 | 路径 |
|---|---|
| 启动器配置 / 日志 / pid / allowbuilds sidecar | `~/Library/Application Support/DSHLauncher/` |
| harness 数据（profile、凭据、工作区存储） | `~/.dsh`（共享，可在设置中改为任意目录） |
| harness 源码 | 本机既有 checkout（升级/重建在此路径内执行） |

## 行为要点

- 退出 App（⌘Q）会以 SIGTERM → 5 秒宽限 → SIGKILL 停止 harness；仅关闭窗口时服务继续运行。
- 就绪判定采用 dsh 官方 supervisor 信号：子进程 stdout 的 `dsh web: http://127.0.0.1:<port>` 行，TCP 探测兜底。
- 3 秒看门狗巡检自愈；App 启动时清理上次残留（pid 文件 + `lsof` 端口探测）。
- 升级/重建通过 `corepack pnpm` 执行（尊重源码 `packageManager` 钉死的 pnpm 版本，规避本机 pnpm 版本差异）。
- 网络代理设置会注入子进程环境变量并写入 git `http.proxy`。

## 与飞牛版的差异（设计共识）

砍掉：反向代理层（2299 端口/访问密码/自签 HTTPS/fngateway 子路径改写）、fnpack 打包、Unix Socket API、
DSH_RUN_USER 降权、landlock/gcc/musl 安装等 Linux/fnos 专属逻辑；npm registry 不强制 npmmirror（尊重本机配置）。
新增 macOS 适配：GUI App 无 Homebrew PATH 的 node/corepack 显式探测、`lsof` 替代 `fuser`、
Finder 定位替代飞牛文件管理 SDK、原生 SwiftUI 替代 Web 管理面板。

移植细节参考：`docs/fnos-reference.md`（从 fnos Go 源码逐字提取的正则/文案/算法）。
