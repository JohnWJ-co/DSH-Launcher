# fnOS 启动器 Swift 复刻参考文档

> 来源：`/Users/qiangwenjun/Documents/project/deepseek.harness.fnos`（Go 源码 + Vue 前端）
> 本文档只收录「逐字精确的可移植细节」：正则原文、格式字符串、魔法数字、中文文案。
> 所有代码块均标注来源文件。移植时请以本文抄录的原文为准，不要凭记忆改写。

---

## 目录

1. [插件命令解析（plugins.go）](#1-插件命令解析pluginsgo)
2. [pnpm 故障分类（profile.go）](#2-pnpm-故障分类profilego)
3. [六类自愈流程（runPluginOpWithRecovery）](#3-六类自愈流程runpluginopwithrecovery)
4. [受保护插件（IsProtectedPlugin）](#4-受保护插件isprotectedplugin)
5. [插件列表（handleListPlugins）](#5-插件列表handlelistplugins)
6. [cordis.patch.yml（profile.go）](#6-cordispatchymlprofilego)
7. [allowBuilds（profile.go）](#7-allowbuildsprofilego)
8. [workspace.json（workspace.go）](#8-workspacejsonworkspacego)
9. [logger.go](#9-loggergo)
10. [config.go InitAppEnv / ApplyProxyEnv](#10-configgo-initappenv--applyproxyenv)
11. [harness.go 健康检查与就绪激活](#11-harnessgo-健康检查与就绪激活)
12. [api.go statusPayload / readLastNLines](#12-apigo-statuspayload--readlastnlines)
13. [前端文案全集（Vue）](#13-前端文案全集vue)

---

## 1. 插件命令解析（plugins.go）

### 1.1 关键路径与超时常量

```go
// plugins.go
const (
	pluginRemoveTimeout  = 60 * time.Second
	pluginInstallTimeout = 180 * time.Second
	pluginSyncTimeout    = 30 * time.Second
)
```

| verb | 超时 |
|---|---|
| remove | 60s |
| add / update / install | 180s |
| list / why（默认） | 30s |

```go
// plugins.go
func pluginProfileDir() string {
	return filepath.Join(pkgVarDir, "dsh-data", "profiles", "web")
}
```

**注意**：`pluginProfileDir()` 硬编码末段为 `"web"`，与命令行 `--profile` 参数无关（实际只有一个 web profile）。

插件子进程工作目录为 `srcDir`（= `$pkgVar/src/deepseek-harness`），进程组方式启动，stdout/stderr 同时接入日志 writer 与 800 字节 tail 缓冲（`newTailWriter(800)`，超出截断保留末尾 800 字节）。

### 1.2 pluginEnv() 注入的环境变量

```go
// plugins.go — 在 os.Environ() 基础上追加：
"NPM_CONFIG_FETCH_TIMEOUT=30000",
"NPM_CONFIG_NETWORK_TIMEOUT=30000",
"NPM_CONFIG_FETCH_RETRIES=2",
"NPM_CONFIG_FETCH_RETRY_MINTIMEOUT=2000",
"NPM_CONFIG_FETCH_RETRY_MAXTIMEOUT=10000",
"PNPM_CONFIG_FETCH_TIMEOUT=30000",
"PNPM_CONFIG_NETWORK_TIMEOUT=30000",
"PNPM_CONFIG_FETCH_RETRIES=2",
"PNPM_CONFIG_REGISTRY=https://registry.npmmirror.com",
"NPM_CONFIG_REGISTRY=https://registry.npmmirror.com",
```

### 1.3 verb 常量与别名完整表

```go
// plugins.go
type pluginVerb string

const (
	pluginAdd     pluginVerb = "add"
	pluginRemove  pluginVerb = "remove"
	pluginUpdate  pluginVerb = "update"
	pluginList    pluginVerb = "list"
	pluginWhy     pluginVerb = "why"
	pluginInstall pluginVerb = "install"
)

var pluginVerbAliases = map[string]pluginVerb{
	"add":     pluginAdd,
	"install": pluginInstall, "i": pluginInstall,
	"remove": pluginRemove, "rm": pluginRemove, "uninstall": pluginRemove, "un": pluginRemove,
	"update": pluginUpdate, "up": pluginUpdate, "upgrade": pluginUpdate,
	"list": pluginList, "ls": pluginList,
	"why": pluginWhy,
}

var pluginNeedSpecs = map[pluginVerb]bool{
	pluginAdd: true, pluginRemove: true, pluginUpdate: true, pluginWhy: true,
}
```

- 需要 ≥1 个 spec 的 verb：add / remove / update / why。
- `install` 不接受任何 spec（给了报错 `install 操作不接受包名参数`）。
- list / install 无 spec 时 `Specs` 置为 nil。

### 1.4 全部校验正则（逐字抄录）

```go
// plugins.go
var (
	npmSpecRe       = regexp.MustCompile(`^(@[a-z0-9-~][\w.-]*\/)?[a-z0-9-~][\w.-]*(@[0-9A-Za-z.*+~^<>=,\- ]+)?$`)
	gitURLRe        = regexp.MustCompile(`^(git\+)?(https?:\/\/|ssh:\/\/)[^\s;|` + "`" + `$()]+$`)
	gitShorthandRe  = regexp.MustCompile(`^github:[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+(?:#[^\s;|` + "`" + `$()]+)?$`)
	localSpecRe     = regexp.MustCompile(`^(file:|\/).+$`)
	profileNameRe   = regexp.MustCompile(`^[a-zA-Z0-9_-]+$`)
	specForbiddenRe = regexp.MustCompile(`[;|` + "`" + `$()\r\n]`)
)
```

其中 gitURLRe / gitShorthandRe / specForbiddenRe 里的 `` ` `` 是**反引号字面量**（Go 源码用字符串拼接表示）。展开后的实际正则：

- `gitURLRe`：`^(git\+)?(https?:\/\/|ssh:\/\/)[^\s;|` + 反引号 + `$()]+$`
- `gitShorthandRe`：`^github:[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+(?:#[^\s;|` + 反引号 + `$()]+)?$`
- `specForbiddenRe`：`[;|` + 反引号 + `$()\r\n]`

**禁止的注入字符集合**：`;` `|` `` ` `` `$` `(` `)` `\r` `\n`（共 8 个）。

Swift NSRegularExpression/ICU 里 `\/` 可当 `/` 处理；`\w` 等价 `[0-9A-Za-z_]`。

### 1.5 splitCommandLine 分词器精确规则

```go
// plugins.go — 完整算法
func splitCommandLine(input string) ([]string, error) {
	var tokens []string
	var cur strings.Builder
	inQuote := false
	quoteChar := byte(0)
	escaped := false

	for i := 0; i < len(input); i++ {
		c := input[i]
		if escaped {
			cur.WriteByte(c)   // 转义字符原样写入（含空格/引号）
			escaped = false
			continue
		}
		if c == '\\' {
			escaped = true    // 反斜杠本身不写入
			continue
		}
		if inQuote {
			if c == quoteChar {
				inQuote = false
				quoteChar = 0    // 闭合引号被丢弃
			} else {
				cur.WriteByte(c)
			}
			continue
		}
		if c == '"' || c == '\'' {
			inQuote = true
			quoteChar = c     // 开引号被丢弃
			continue
		}
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			if cur.Len() > 0 {
				tokens = append(tokens, cur.String())
				cur.Reset()
			}
			continue
		}
		cur.WriteByte(c)
	}
	if inQuote {
		return nil, fmt.Errorf("引号未闭合")
	}
	if cur.Len() > 0 {
		tokens = append(tokens, cur.String())
	}
	return tokens, nil
}
```

规则要点（逐字精确）：

- 逐**字节**处理（Go 遍历 byte，非 rune）。
- `\` 转义下一个任意字符：转义符本身丢弃，被转义字符原样保留。
- 引号只认 `"` 和 `'`，成对匹配同一字符；开/闭引号本身都不进入 token。
- 分隔符：空格 `' '`、`\t`、`\n`、`\r`。
- 连续分隔符不产生空 token；token 只在非空时产出。
- 输入结束时引号未闭合 → 错误文案：`引号未闭合`。

### 1.6 命令格式校验逻辑（parsePluginCommand）

```go
// plugins.go — 流程与全部错误文案
```

1. 先 `strings.TrimSpace(input)` 再 `splitCommandLine`。
2. 空 → `请输入插件命令`
3. 必须满足 `len(fields) >= 2 && fields[0] == "dsh" && fields[1] == "plugin"`，否则 → `请输入标准 dsh 命令，例如: dsh plugin --profile web add 包名`
4. profile 默认值 `"web"`。从 `fields[2:]` 起扫描：
   - `--profile`：下一个字段是名称；越界 → `--profile 缺少参数`；不匹配 `^[a-zA-Z0-9_-]+$` → `非法的 profile 名称: %s`。
   - 任何其它 `--` 开头的 token → `不支持的参数: %s`。
   - 其余进入 rest。
5. rest 为空 → `缺少操作动词（支持 add / remove / update / list / why / install）`
6. `rest[0]` 查别名表；未知 → `未知操作 %q（支持 add / remove / update / list / why / install）`（`%q` 为 Go 引号格式，输出如 `未知操作 "foo"（…）`）
7. 需 spec 的 verb 无 spec → `%s 操作需要一个或多个包名`
8. `install` 带 spec → `install 操作不接受包名参数`
9. 每个 spec 逐个 `validatePluginSpec`，失败包装为：`参数 %q: %s`

validatePluginSpec 的错误文案：

```go
// plugins.go
spec 为空        → "包名为空"
命中禁止字符     → "包含不允许的字符"
四个正则都不匹配 且以 "." 开头 → "不支持相对路径，请输入标准 npm 包名或 Git 仓库地址"
四个正则都不匹配             → "无法识别的包名/地址格式"
```

校验顺序：TrimSpace → 空判 → specForbiddenRe → (npmSpecRe || gitURLRe || gitShorthandRe || localSpecRe 任一命中即合法) → `.` 前缀特判 → 兜底。

### 1.7 normalizePluginKey（profile.go）

```go
// profile.go
var npmNameStripRe = regexp.MustCompile(`^((?:@[a-z0-9-~][\w.-]*/)?[a-z0-9-~][\w.-]*)@.+$`)

func normalizePluginKey(spec string) string {
	if m := npmNameStripRe.FindStringSubmatch(spec); len(m) >= 2 {
		return m[1]
	}
	return spec
}
```

作用：`pkg@1.2.3` → `pkg`；`@scope/pkg@2.0.0` → `@scope/pkg`；无版本后缀原样返回。

### 1.8 dshArgs() 精确构造逻辑

```go
// plugins.go
func (c *pluginCommand) dshArgs() []string {
	if c.Verb == pluginUpdate {
		// 更新操作重构：注入 minimumReleaseAge=0 穿透 pnpm 11 新鲜期限制，并解析真实最新目标
		args := []string{"plugin", "--profile", c.Profile, "add"}
		if profileHasWorkspace() {
			args = append(args, "-w")
		}
		args = append(args, "--config.minimumReleaseAge=0")
		for _, spec := range c.Specs {
			args = append(args, resolveUpdateTarget(spec))
		}
		return args
	}

	args := []string{"plugin", "--profile", c.Profile, string(c.Verb)}
	if (c.Verb == pluginAdd || c.Verb == pluginRemove) && profileHasWorkspace() {
		args = append(args, "-w")
	}
	if c.Verb == pluginAdd || c.Verb == pluginInstall {
		args = append(args, "--config.minimumReleaseAge=0")
	}
	args = append(args, c.Specs...)
	return args
}
```

**规则总结**：

| verb | 生成的 argv（dsh 子命令之后的部分） |
|---|---|
| update | `plugin --profile <P> add [-w] --config.minimumReleaseAge=0 <resolveUpdateTarget(spec)…>` |
| add | `plugin --profile <P> add [-w] --config.minimumReleaseAge=0 <specs…>` |
| remove | `plugin --profile <P> remove [-w] <specs…>` |
| install | `plugin --profile <P> install --config.minimumReleaseAge=0` |
| list / why | `plugin --profile <P> list\|why` |

- `-w` 的添加条件：`profileHasWorkspace()`（存在 `$profileDir/pnpm-workspace.yaml`），且 verb ∈ {update, add, remove}（update 走的是重构后的 add 分支）。
- `--config.minimumReleaseAge=0`：update / add / install 都加（update 在固定位置，add/install 在 verb 后）。
- **update 实际执行的是 `add`**，每个 spec 经 `resolveUpdateTarget` 重写。

### 1.9 resolveUpdateTarget（update 目标解析）

```go
// plugins.go
func resolveUpdateTarget(spec string) string {
	norm := normalizePluginKey(spec)
	deps, _, _, err := readProfileManifest()
	if err == nil && deps != nil {
		if origSpec, exists := deps[norm]; exists && origSpec != "" {
			if strings.HasPrefix(origSpec, "github:") ||
				strings.HasPrefix(origSpec, "git+") ||
				strings.HasPrefix(origSpec, "http:") ||
				strings.HasPrefix(origSpec, "https:") {
				return origSpec   // Git/URL 依赖：用 package.json 里记录的原始 spec
			}
		}
	}

	target := norm
	if strings.HasPrefix(target, "@") {
		// scoped 包：去掉开头 @ 后不再含 @（即未显式指定版本）才补 @latest
		if !strings.Contains(target[1:], "@") {
			target = target + "@latest"
		}
	} else if !strings.Contains(target, "@") && !strings.HasPrefix(target, "github:") {
		target = target + "@latest"
	}
	return target
}
```

### 1.10 dsh CLI 的实际执行方式（harness.go dshCliCmd）

```go
// harness.go — 三级回退
cliBinJs = $srcDir/apps/cli/lib/bin.js 存在
    → 执行: node $cliBinJs <args...>
否则解析 $srcDir/package.json 的 scripts["dsh"]，按空白分字段，
    首字段为 "tsx" 或 "node" → 执行: node <parts[1:]...> <args...>
否则兜底 → 执行: pnpm dsh <args...>
```

启动服务命令：`dshCliCmd("web", "--port", "<ServerPort>")`，工作目录 `srcDir`。

### 1.11 执行入口文案（handlePluginRun）

```go
// plugins.go
doneMsg 默认 = "操作完成"
add:     doneMsg = "安装完成，重启服务后生效"   startMsg = "已开始执行插件安装"
remove:  doneMsg = "卸载完成，重启服务后生效"   startMsg = "已开始卸载插件「%s」"(specs 空格连接)
update:  doneMsg = "更新完成，重启服务后生效"   startMsg = "已开始更新插件「%s」"(specs 空格连接)
install: doneMsg = "安装完成，重启服务后生效"   startMsg = "已开始执行插件安装"
default:                                      startMsg = "已开始执行插件指令"
```

前置校验错误文案（setPluginRunning / validatePluginExecution）：

```
插件操作正在进行中，请稍候
正在构建中，请稍候再试
服务正在启动中，请稍候再试
运行环境未就绪或依赖文件缺失
初始化 pnpm 运行环境失败: %w
插件「%s」已安装 (当前版本: %s)          // add 查重，norm 名 + 当前 spec
核心基础设施插件「%s」受到保护，禁止卸载   // remove 保护
仅支持添加插件指令 (add)                  // preview 限制
```

取消操作：`已发送取消指令` / 失败 `当前没有正在执行的插件操作`。
进程错误包装（runPluginSubprocess）：

```
插件操作超时（超过 %v），网络请求或依赖解析未能按时完成，已自动终止
插件操作超时（超过 %v），已自动终止
操作已被用户手动取消
```

超时/取消时日志：`[插件管理] 操作执行超时 (%v)，正在强制终止进程组 (PID: %d)...`、`[插件管理] 收到取消请求，正在终止插件操作进程组 (PID: %d)...`

pluginFailMessage 附加尾注（tail 中含 `ERR_PNPM_IGNORED_BUILDS` / `approve-builds` / `allowBuilds` 任一）：

```
构建脚本被 pnpm 拦截，已自动配置放行并重试。
```

---

## 2. pnpm 故障分类（profile.go）

### 2.1 故障码常量

```go
// profile.go
const (
	PnpmFailureHoistPatternDiff PnpmFailureCode = "hoist-pattern-diff"
	PnpmFailureReleaseAge       PnpmFailureCode = "release-age-violation"
	PnpmFailureFetchTimeout     PnpmFailureCode = "fetch-timeout"
	PnpmFailureTransientNetwork PnpmFailureCode = "transient-network"
	PnpmFailureIgnoredBuilds    PnpmFailureCode = "ignored-builds"
	PnpmFailureGitDepPrepare    PnpmFailureCode = "git-prepare-not-allowed"
	PnpmFailureFetch404         PnpmFailureCode = "fetch-404"
	PnpmFailureAddingToRoot     PnpmFailureCode = "adding-to-root"   // 仅定义，分类中未使用
	PnpmFailureUnexpectedStore  PnpmFailureCode = "unexpected-store"
	PnpmFailureUnknown          PnpmFailureCode = "unknown"
)

type PnpmFailureInfo struct {
	Code        PnpmFailureCode
	Recoverable bool
	Message     string
	DetailPkg   string
}
```

### 2.2 分类正则原文

```go
// profile.go
var (
	re404Pkg       = regexp.MustCompile(`(?:GET|fetch)\s+\S*\/([^/\s:]+)(?::|\s)`)
	reTransientNet = regexp.MustCompile(`(?i)(?:ERR_PNPM_FETCH_5\d\d|ERR_PNPM_META_FETCH_FAIL|FetchError|ECONNRESET|ETIMEDOUT|EAI_AGAIN|ENETUNREACH|socket hang up|network timeout)`)
	reFetchTimeout = regexp.MustCompile(`(?i)(?:operation was aborted due to timeout|TimeoutError|error \(23\))`)
	semverPattern  = regexp.MustCompile(`^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$`)
)
```

### 2.3 ClassifyPnpmFailure 匹配顺序与全部文案

**匹配顺序严格如下**（先命中先返回；前 6 项为 `strings.Contains` 子串匹配，后 2 项为正则）：

| 序 | 触发条件（子串/正则） | Code | Recoverable | 中文 Message |
|---|---|---|---|---|
| 1 | 含 `ERR_PNPM_PUBLIC_HOIST_PATTERN_DIFF` | hoist-pattern-diff | true | `node_modules 是旧版 pnpm 创建的，存在依赖结构差异，已自动重建后重试` |
| 2 | 含 `ERR_PNPM_UNEXPECTED_STORE` | unexpected-store | true | `依赖存储位置变更，已自动清理缓存并重试` |
| 3 | 含 `ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION` **或** `ERR_PNPM_NO_MATURE_MATCHING_VERSION` | release-age-violation | true | `检测到刚发布的新版本受 pnpm 安全期限制，已自动放行并重试` |
| 4 | 正则 `reFetchTimeout` 命中 | fetch-timeout | true | `下载耗时超出默认限制，已自动延长超时时间并重试` |
| 5 | 含 `ERR_PNPM_IGNORED_BUILDS` | ignored-builds | true | `依赖包含构建脚本，已被 pnpm 默认拦截，已自动配置放行并重试` |
| 6 | 含 `ERR_PNPM_GIT_DEP_PREPARE_NOT_ALLOWED` | git-prepare-not-allowed | true | `Git 插件包含构建脚本，已自动配置放行并重试` |
| 7 | 含 `ERR_PNPM_FETCH_404` | fetch-404 | **false** | 见下方动态构造 |
| 8 | 正则 `reTransientNet` 命中 | transient-network | true | `网络连接瞬态抖动，已自动重试` |
| 9 | 兜底 | unknown | false | `插件指令执行失败` |

**fetch-404 的动态文案**（原文）：

```go
// profile.go
detailPkg := ""
if m := re404Pkg.FindStringSubmatch(output); len(m) > 1 {
	detailPkg = strings.ReplaceAll(m[1], "%2F", "/")
	detailPkg = strings.ReplaceAll(detailPkg, "%2f", "/")
}
msg := "指定的插件包在 npm 镜像源上不存在 (404)"
if detailPkg != "" {
	msg = fmt.Sprintf("依赖包「%s」在镜像源上不存在 (404)，可能未发布或存在历史残留", detailPkg)
}
```

（404 提取时把 URL 编码的 `%2F`/`%2f` 还原为 `/`，用于还原 scoped 包名。）

### 2.4 FormatPnpmFailureMessage 精确逻辑

```go
// profile.go
func FormatPnpmFailureMessage(output string) string {
	info := ClassifyPnpmFailure(output)
	if info.Code == PnpmFailureFetch404 {
		return info.Message          // 404 直接返回，不带括号细节
	}

	lines := strings.Split(output, "\n")
	var meaningfulLines []string
	for _, l := range lines {
		trimmed := strings.TrimSpace(l)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "ERR_PNPM_") ||
			strings.HasPrefix(trimmed, "npm ERR!") ||
			strings.HasPrefix(trimmed, "error:") ||
			strings.Contains(trimmed, "Error:") {
			meaningfulLines = append(meaningfulLines, trimmed)
		}
	}

	if len(meaningfulLines) > 0 {
		return fmt.Sprintf("%s（%s）", info.Message, meaningfulLines[0])  // 中文圆括号
	}

	// 兜底：从最后一行向前找第一条非空且不以 "at " 开头的行
	for i := len(lines) - 1; i >= 0; i-- {
		t := strings.TrimSpace(lines[i])
		if t != "" && !strings.HasPrefix(t, "at ") {
			if len(t) > 120 {
				t = t[:120] + "…"     // 超过 120 字节截断 + 省略号
			}
			return fmt.Sprintf("%s: %s", info.Message, t)
		}
	}
	return info.Message
}
```

### 2.5 CompareSemver（版本比对，供 update 比对用）

- 解析前先 TrimSpace、去 `v` 前缀、去 `^` 前缀、去 `~` 前缀（顺序执行）。
- 匹配 `semverPattern`（见 2.2）；失败则退化为：相等→0，否则 `strings.Compare` 字典序。
- 比较顺序：Major → Minor → Patch → 预发布段。
- 无 pre > 有 pre（`正式版本优于预览版`）。
- pre 段按 `.` 切分逐段比：短的一方更小；数字段按数值比（数字<非数字）；同类型非数字按字典序。

---

## 3. 六类自愈流程（runPluginOpWithRecovery）

```go
// plugins.go — 入口骨架
func runPluginOpWithRecovery(cmd *pluginCommand, doneMsg string) (string, error) {
	timeout := pluginOpTimeout(cmd.Verb)
	args := cmd.dshArgs()

	if cmd.Verb == pluginList || cmd.Verb == pluginWhy {   // 同步执行，输出直接返回
		out, runErr := runPluginSync(args, timeout)
		if runErr != nil {
			return "", fmt.Errorf("%s", FormatPnpmFailureMessage(runErr.Error()))
		}
		return strings.TrimSpace(out), nil
	}

	runErr := runPluginSubprocess(args, timeout)
	if runErr == nil {
		return doneMsg, nil
	}
	if cmd.Verb != pluginAdd && cmd.Verb != pluginUpdate && cmd.Verb != pluginInstall {
		return "", fmt.Errorf("%s", FormatPnpmFailureMessage(runErr.Error()))
	}
	failure := ClassifyPnpmFailure(runErr.Error())
	// ↓ 六类自愈，顺序严格如下；每步失败后重新 ClassifyPnpmFailure 供下一判
	...
	return "", fmt.Errorf("%s", FormatPnpmFailureMessage(runErr.Error()))
}
```

自愈只对 **add / update / install** 三个 verb 生效。六类自愈顺序与精确参数：

### 自愈 1：跨大版本 Hoist 差异（hoist-pattern-diff）

- 触发：`failure.Code == PnpmFailureHoistPatternDiff`
- 日志（LogWarning）：`[自动自愈] 依赖结构存在跨版本差异，正在执行重建 (pnpm install --no-frozen-lockfile)...`
- 动作：先跑一次 `["plugin", "--profile", cmd.Profile, "install", "--no-frozen-lockfile"]`（同 timeout，结果忽略），再用原始 args 重试。
- 成功返回：`doneMsg + "（已自动重建依赖环境）"`

### 自愈 2：存储位置变更（unexpected-store）

- 触发：`failure.Code == PnpmFailureUnexpectedStore`
- 动作：`os.RemoveAll(filepath.Join(pluginProfileDir(), "node_modules"))`，然后原 args 重试。
- 日志：`[自动自愈] 存储位置变更，已自动清理本地缓存并重试: %s`（参数 `cmd.display()`）
- 成功返回：`doneMsg`（无后缀）

### 自愈 3：新鲜发布安全期（release-age-violation）

- 触发：`failure.Code == PnpmFailureReleaseAge`
- 动作：`retryArgs = args + ["--config.minimumReleaseAge=0"]`（追加到末尾），原 timeout 重试。
- 日志：`[自动自愈] 新发布版本受安全期检查拦截，已自动追加 --config.minimumReleaseAge=0 重试...`
- 成功返回：`doneMsg + "（已自动放行新发布版本）"`

### 自愈 4：慢网/大包下载超时（fetch-timeout）

- 触发：`failure.Code == PnpmFailureFetchTimeout`
- 动作：`retryArgs = args + ["--config.fetchTimeout=600000"]`，重试超时改为 **`timeout + 10*time.Minute`**。
- 日志：`[自动自愈] 大包下载超时，正在以 10 分钟超时延长重试...`
- 成功返回：`doneMsg + "（已自动延长超时完成下载）"`

### 自愈 5：瞬态网络抖动（transient-network）

- 触发：`failure.Code == PnpmFailureTransientNetwork`
- 动作：原 args、原 timeout 重试 **1 次**。
- 日志：`[自动自愈] 检测到网络瞬时波动，正在自动重试 1 次...`
- 成功返回：`doneMsg`（无后缀）

### 自愈 6：构建脚本拦截（allowBuilds / ignored-builds）

- 触发：**不看 failure.Code**，而是 `parseBlockedPackages(runErr.Error())` 提取到 ≥1 个包名（正则见 §7.1）。注意此判断对任何 verb（add/update/install）都执行。
- 动作：`ensureAllowBuildsFor(cmd.Profile, pluginAllowKey(cmd), pkgs)` 成功后原 args、原 timeout 重试。
- 日志：`[自动自愈] 构建脚本被拦截 [%s]，已自动配置放行并重新执行`（pkgs 逗号+空格连接）
- 成功返回：`doneMsg + "（已自动放行构建脚本: " + strings.Join(pkgs, ", ") + "）"`

全部失败后：`return "", FormatPnpmFailureMessage(runErr.Error())`。

### 3.1 pluginAllowKey

```go
// plugins.go
AllowKey 非空 → 直接用；
无 specs → ""；
否则 = 所有 specs 的 normalizePluginKey 结果用 " "（单空格）连接。
```

### 3.2 update 后版本比对（Stale Update Detection）输出格式

在 `launchPluginOp` 的 goroutine 中执行：

1. **执行前**记录旧版本：对每个 spec 取 `normalizePluginKey(spec)`，查 `installedPluginMetadata(name).Version` 存入 `beforeVersions`。
2. update 成功且 `len(cmd.Specs) > 0` 时，对每个 spec 重新读取 `installedPluginMetadata(name)`：

| 条件 | updatedDetails 追加 | hasAnyUpgrade |
|---|---|---|
| `CompareSemver(new, old) > 0`（升级） | `fmt.Sprintf("%s: v%s -> v%s", name, oldVer, newMeta.Version)` | true |
| `newMeta.Version == oldVer`（未变） | `fmt.Sprintf("%s: 当前已是最新版本 (v%s)", name, newMeta.Version)` | 不变 |
| 其它（降级） | `fmt.Sprintf("%s: v%s", name, newMeta.Version)` | true |

（仅当 `found && oldVer != ""` 时才产生 detail。）

3. 最终消息覆盖规则：

```go
if !hasAnyUpgrade && len(updatedDetails) > 0 {
	msg = strings.Join(updatedDetails, "；") + "，远端无新发布版本"
} else if len(updatedDetails) > 0 {
	msg = "更新完成（" + strings.Join(updatedDetails, "；") + "），重启服务后生效"
}
```

分隔符是**中文分号 `；`**。

### 3.3 remove 后的残留清理（精确逻辑）

```go
// plugins.go — launchPluginOp 内，操作成功且 verb == remove 时：
if cmd.Verb == pluginRemove {
	for _, spec := range cmd.Specs {
		_ = RemovePluginFromProfileUserPatch(cmd.Profile, spec)   // 注意：不传 entryIDs 变参
	}
	if pluginAllowKey(cmd) != "" {
		_ = cleanupAllowBuildsFor(cmd.Profile, pluginAllowKey(cmd))
	}
}
```

- `RemovePluginFromProfileUserPatch(profile, spec)` 不带 entryIDs → idSet = {spec 原串} ∪ {packageName}（packageName 也加入集合），删除 `r.ID` 或 `r.Name` 命中集合的行。
- `cleanupAllowBuildsFor` 见 §7.4。

---

## 4. 受保护插件（IsProtectedPlugin）

```go
// profile.go — 全部 18 条前缀正则（逐字抄录）
var protectedModulePatterns = []*regexp.Regexp{
	regexp.MustCompile(`^cordis:`),
	regexp.MustCompile(`^@deepseek-ai/cordis-plugin-`),
	regexp.MustCompile(`^@deepseek-ai/dsh-host-`),
	regexp.MustCompile(`^@deepseek-ai/dsh-client-`),
	regexp.MustCompile(`^@deepseek-ai/dsh-web`),
	regexp.MustCompile(`^@deepseek-ai/dsh-settings`),
	regexp.MustCompile(`^@deepseek-ai/dsh-credentials`),
	regexp.MustCompile(`^@deepseek-ai/dsh-session`),
	regexp.MustCompile(`^@deepseek-ai/dsh-storage`),
	regexp.MustCompile(`^@deepseek-ai/dsh-tools`),
	regexp.MustCompile(`^@deepseek-ai/dsh-system-prompt`),
	regexp.MustCompile(`^@deepseek-ai/dsh-agent`),
	regexp.MustCompile(`^@deepseek-ai/dsh-llm`),
	regexp.MustCompile(`^@deepseek-ai/dsh-shell`),
	regexp.MustCompile(`^@deepseek-ai/dsh-fs`),
	regexp.MustCompile(`^@deepseek-ai/dsh-sandbox`),
	regexp.MustCompile(`^@deepseek-ai/dsh-jobs`),
	regexp.MustCompile(`^@deepseek-ai/dsh-base`),
	regexp.MustCompile(`^@deepseek-ai/dsh-web-app`),
}
```

- 全部为 `^前缀` 前缀匹配（MatchString，非全匹配）。
- 空串返回 false。
- 保护行为：禁止卸载（`核心基础设施插件「%s」受到保护，禁止卸载`）、禁止启停（`核心基础设施插件「%s」受到保护，禁止更改启停状态`）；`SetPluginDisabled` 内部同样拒绝：`核心基础设施插件 %q 受到保护，禁止更改启停状态`。

---

## 5. 插件列表（handleListPlugins）

### 5.1 数据来源

| 数据 | 来源文件 |
|---|---|
| 已安装依赖清单 deps（map 名→spec）、bundles、legacyDisabled | `$pluginProfileDir/package.json`（`readProfileManifest`） |
| 插件元数据（版本/描述/作者等） | 见 5.2 三个候选路径依次尝试 |
| 禁用状态 | `cordis.patch.yml`（`ReadDisabledEntryMap("web")`） |
| entry IDs | 插件包内 `dsh.bundle.patch` 声明（`ExtractPluginEntryIDs("web", name)`） |

package.json 不存在时返回空 payload（`{Profile:"web", Plugins:[], Bundles:[]}`）；其它读错误 → `读取插件列表失败: %s`。

profile manifest 解析结构（`profileManifest`）：

```go
// plugins.go
type profileManifest struct {
	Name         string            `json:"name"`
	Private      bool              `json:"private"`
	Version      string            `json:"version,omitempty"`
	Dependencies map[string]string `json:"dependencies,omitempty"`
	Dsh          *struct {
		Profile *struct {
			Bundles  []string `json:"bundles"`
			Disabled []string `json:"disabled"` // 兼容旧版 disabled 字段
		} `json:"profile"`
	} `json:"dsh,omitempty"`
}
```

### 5.2 metadata 候选路径（installedPluginMetadata）

按顺序读第一个「存在且 JSON 可解析且 `name` 非空」的：

```go
// plugins.go
candidates := []string{
	filepath.Join(pluginProfileDir(), "node_modules", name, "package.json"),          // $pkgVar/dsh-data/profiles/web/node_modules/<name>/package.json
	filepath.Join(pkgVarDir, "dsh-data", "profiles", "node_modules", name, "package.json"), // 注意：profiles 平级（非 web 子目录）
	filepath.Join(srcDir, "node_modules", name, "package.json"),                       // $pkgVar/src/deepseek-harness/node_modules/<name>/package.json
}
```

读取的 package.json 字段（`rawPackageMeta`）：

```go
Name        string   `json:"name"`
Version     string   `json:"version"`
Description string   `json:"description"`
Homepage    string   `json:"homepage"`
License     string   `json:"license"`
Keywords    []string `json:"keywords"`
Author      any      `json:"author"`        // 字符串或 {name: string} 对象
Dsh.Bundle.Patch     string  `json:"patch"` // 路径 dsh.bundle.patch
```

`parseAuthorString`：字符串直接返回；对象取 `m["name"]`；其它返回 ""。

**dsh.bundle.patch 的用法**：`meta.Dsh != nil && meta.Dsh.Bundle != nil && meta.Dsh.Bundle.Patch != ""` → `hasBundle = true`。patch 路径相对插件包根目录（见 §6.3 ExtractPluginEntryIDs）。

### 5.3 pluginItem 字段（API 响应）

```go
// plugins.go
type pluginItem struct {
	Name        string   `json:"name"`
	Version     string   `json:"version,omitempty"`
	Spec        string   `json:"spec,omitempty"`       // package.json dependencies 里的原始 spec
	State       string   `json:"state"`                // "live" | "disabled" | "inert"
	Layer       bool     `json:"layer"`                // 兼容字段: State == "live"
	EntryIDs    []string `json:"entryIds,omitempty"`
	Description string   `json:"description,omitempty"`
	Author      string   `json:"author,omitempty"`
	Homepage    string   `json:"homepage,omitempty"`
	License     string   `json:"license,omitempty"`
	Keywords    []string `json:"keywords,omitempty"`
	IsProtected bool     `json:"isProtected"`
	HasBundle   bool     `json:"hasBundle"`
}

type pluginListPayload struct {
	Profile string       `json:"profile"`
	Plugins []pluginItem `json:"plugins"`
	Bundles []string     `json:"bundles"`
}
```

插件按 `sort.Strings(names)` **字典序**输出。

### 5.4 live / disabled / inert 判定逻辑

对每个依赖 name：

1. `entryIDs = ExtractPluginEntryIDs("web", name)`
2. 遍历 entryIDs：任一 eid 在 disabledMap（cordis.patch.yml 中 `id == eid && disabled == true`）→ **state = "disabled"**
3. 否则若 `!hasBundle && !bundleSet[name]`（包内无 dsh.bundle.patch 声明，且 manifest `dsh.profile.bundles` 也没列出该名）→ **state = "inert"**（普通依赖）
4. 否则 **state = "live"**；`Layer = (state == "live")`

### 5.5 旧版 disabled 迁移逻辑

manifest 中 `dsh.profile.disabled`（legacyDisabled）非空时，对每个名字（TrimSpace，跳过空）：

- 取 `entryIDs = ExtractPluginEntryIDs("web", disName)`；若所有 eid 都不在 disabledMap → 执行 `SetPluginDisabled("web", disName, true)` 写入 cordis.patch.yml，并把各 eid 置入 disabledMap。
- 迁移日志（LogInfo）：
  `[历史配置迁移] 检测到旧版 package.json 中的 disabled 状态，已自动无缝迁移至官方 cordis.patch.yml: %s`

---

## 6. cordis.patch.yml（profile.go）

### 6.1 文件位置与数据结构

```go
// profile.go
func ProfileUserPatchPath(profile string) string {
	if profile == "" {
		profile = "web"
	}
	return filepath.Join(profileDirFor(profile), "cordis.patch.yml")
}
// profileDirFor(name) = $pkgVar/dsh-data/profiles/<name>

type CordisPatchRow struct {
	ID       string                 `yaml:"id,omitempty"`
	Name     string                 `yaml:"name,omitempty"`
	Disabled *bool                  `yaml:"disabled,omitempty"`
	Config   map[string]interface{} `yaml:"config,omitempty"`
	Insert   []CordisPatchRow       `yaml:"insert,omitempty"`
}
```

文件为 **YAML 顶层数组**（`[]CordisPatchRow`）。`Disabled` 是 `*bool`（三态：nil / true / false）。

### 6.2 读写函数精确行为

**ReadProfileUserPatch**：文件不存在或内容全空白 → 返回 `[]CordisPatchRow{}`；YAML 解析失败 → `解析 %s 失败: %w`。

**WriteProfileUserPatch**：

```go
// profile.go
MkdirAll(dir, 0755)
rows 为空 → 写入字面量 "[]\n"（0644）
否则 → yaml.Marshal(rows) 全量写回（0644）
```

**不保留注释**：写入走 `yaml.Marshal` 全量序列化，任何手工注释/顺序都会丢失。读时也只读结构化字段。

**互斥**：所有 patch 文件操作经全局 `patchFileMu sync.Mutex` 串行化。

### 6.3 ExtractPluginEntryIDs 逻辑

```go
// plugins.go（定义在 plugins.go，路径基于 profileDirFor）
1. 读 $profileDir/node_modules/<packageName>/package.json
2. 取 dsh.bundle.patch（非空才继续）
3. patchFile = <package.json 所在目录>/<patch 路径>（patch 中的 "/" 转本地路径分隔符）
4. 读该 YAML 文件 → []CordisPatchRow
5. 遍历 rows：
   - row.Insert 非空 → 收集每个 Insert[i].ID（非空者）
   - 否则            → 收集 row.ID（非空者）
6. candidates 为空 → 返回 [packageName]（兜底：包名即 entry id）
```

### 6.4 ReadDisabledEntryMap

```go
// profile.go
遍历 rows：r.ID != "" && r.Disabled != nil && *r.Disabled == true → map[r.ID] = true
```

### 6.5 SetPluginDisabled（热启停核心）

```go
// profile.go — 流程
0. IsProtectedPlugin(packageName) → 拒绝（文案见 §4）
1. entryIDs = ExtractPluginEntryIDs(profile, packageName)；为空则 entryIDs = [packageName]
2. rows = ReadProfileUserPatch(profile)
3. 对每个 targetID（依次处理，rows 在循环中被替换）：
   - r.ID == targetID 的行：
     * disabled=true  → r.Disabled = &true，保留该行
     * disabled=false → 若该行 Config 空 && Name 空 && Insert 空 → 整行丢弃；
                        否则 r.Disabled = nil 保留
   - 未命中且 disabled=true → 追加新行 {ID: targetID, Disabled: &true}
4. WriteProfileUserPatch
5. 日志：[Cordis Patch] 已通过 user patch %s 插件 %s (Entry IDs: %v)
   （%s 为 "启用" 或 "禁用"）
```

### 6.6 RemovePluginFromProfileUserPatch

```go
// profile.go
签名: (profile, packageName string, entryIDs ...string)
文件不存在 → 直接 nil
idSet = {packageName} ∪ {非空 entryIDs}
丢弃 r.ID ∈ idSet 或 r.Name ∈ idSet 的行，其余原序保留
写回
```

### 6.7 ResetAllProfilePatches（恢复出厂用）

```go
// profile.go
safeRemoveAll($pkgVar/dsh-data/profiles)
safeRemoveAll($pkgVar/plugins)     // 连同 allowbuilds.json 一起清掉
```

`safeRemoveAll`：先常规 RemoveAll；失败则 Walk 全目录 chmod 0777 后再 RemoveAll（处理只读文件）。

---

## 7. allowBuilds（profile.go）

### 7.1 从 pnpm 输出提取被拦截包名

```go
// profile.go
var (
	blockedBuildsRe = regexp.MustCompile(`(?i)Ignored build scripts:\s*(.+)`)
	pkgNameRe       = regexp.MustCompile(`^(@?[a-zA-Z0-9][\w.-]*(?:/[@a-zA-Z0-9][\w.-]*)?)@[0-9]`)
)

func parseBlockedPackages(tail string) []string {
	m := blockedBuildsRe.FindStringSubmatch(tail)   // 取第一个匹配
	if len(m) < 2 { return nil }
	for _, part := range strings.Split(m[1], ",") { // 逗号分割
		part = strings.TrimSpace(part)
		if part == "" { continue }
		if name := pkgNameRe.FindStringSubmatch(part); len(name) >= 2 {
			pkgs = append(pkgs, name[1])       // "pkg@1.2.3" → "pkg"
		} else {
			pkgs = append(pkgs, part)          // 无版本号原样保留
		}
	}
}
```

### 7.2 相关路径

```go
// profile.go
profileWorkspaceYamlPathFor(name) = $profileDir/pnpm-workspace.yaml
allowBuildsSidecarPath()           = $pkgVar/plugins/allowbuilds.json
```

### 7.3 mergeAllowBuildsEntries（pnpm-workspace.yaml 逐行合并算法）

```go
// profile.go — 精确算法
输入: yamlPath, pkgs（要确保存在的包名列表）

1. 读文件内容 content（不存在 → content = ""；其它 IO 错误 → 返回错误）
2. lines = strings.Split(content, "\n")
3. 定位 allowBuilds 块头 idx：
   从头扫描，在 idx 未找到时：trimmed == "allowBuilds:" 或
   strings.HasPrefix(trimmed, "allowBuilds: ") → idx = i
   （注意匹配的是 TrimSpace 后的行；找到后本轮 continue）
4. idx 找到后继续向下扫描块内条目：
   循环条件：trimmed == "" || 原始行以 " " 开头 || 以 "\t" 开头
     → yamlEntryName(trimmed) 非空则 entryLine[name] = i
   首个不满足的行（新顶级键）→ break
5. 对每个 p ∈ pkgs：
   - p 不在 entryLine → missing
   - 在：取该行 ":" 后的值（TrimSpace）；
     val 不是 "true" 也不是 "false" → 该行号加入 fix 列表
6. missing 和 fix 都为空 → 直接 return nil（不写文件）
7. missing 排序（sort.Strings）
8. 写回：
   - idx < 0（无 allowBuilds 块）：
     content = strings.TrimRight(content, "\n") + "\n\nallowBuilds:\n"
     再对每个 missing 追加 "  " + p + ": true\n"
   - idx >= 0：
     a. 对 fix 中每行：lines[i] = "  " + name + ": true"（强制置 true）
     b. out = lines[:idx+1] + ["  "+p+": true" for each missing] + lines[idx+1:]
        （missing 条目插在 "allowBuilds:" 头行的紧后、既有条目之前）
     c. content = strings.Join(out, "\n")
9. MkdirAll(dir, 0755)；WriteFile(yamlPath, content, 0644)
```

**yamlEntryName 辅助**（块内条目名提取）：

```go
// profile.go
trimmed == "" 或以 "#" 开头或以 "-" 开头 → 返回 ""（注释/列表项不识别）
否则 name = SplitN(trimmed, ":", 2)[0] 的 TrimSpace；空则 ""
```

**注释与顺序保持**：算法只做「插入缺失行」和「改写非法布尔值行」，块内其它行（含注释行）原样保留；缺失条目插入位置在块头之后第一条。

### 7.4 removeAllowBuildsEntries（删除条目）

```go
// profile.go — 精确规则
drop = 要删的包名集合
逐行判断，仅当同时满足以下条件才删除该行：
  (原始行以 " " 或 "\t" 开头)
  && trimmed != ""
  && trimmed 不以 "#" 开头
  && trimmed 不以 "-" 开头
  && 冒号前的 name ∈ drop
  && (没有值 或 值(TrimSpace) != "false")    // 显式 false 的行保留
其余行原样保留（含注释），Join("\n") 写回（0644）
文件不存在 → 直接 nil
```

### 7.5 sidecar allowbuilds.json 结构与算法

结构：`map[string][]string` —— 键为**被放行的包名**，值为**归属的插件 key 列表**（pluginAllowKey 产物，即 normalizePluginKey 后的包名，多个以空格连接）。

序列化：`json.MarshalIndent(m, "", "  ")`（2 空格缩进），0644，目录 MkdirAll 0755。读取失败/JSON 非法 → 空 map。

**ensureAllowBuildsFor(profile, pluginKey, pkgs)**：

```go
1. mergeAllowBuildsEntries(workspaceYaml, pkgs) 失败即返回错误
2. sidecar[pkg] 中不存在 pluginKey 则 append（对每个 pkg）
3. 写回 sidecar
```

**cleanupAllowBuildsFor(profile, pluginKey)**（卸载后清理孤儿）：

```go
1. 遍历 sidecar 每个 pkg：
   keep = keys 中 != pluginKey 的项
   - keep 为空 → 从 sidecar 删除该 pkg，pkg 记入 orphan 列表
   - 否则      → sidecar[pkg] = keep
2. orphan 非空 → removeAllowBuildsEntries(workspaceYaml, orphan)
   失败 → 错误文案："清理 allowBuilds 失败: %s"
3. 写回 sidecar
```

---

## 8. workspace.json（workspace.go）

### 8.1 文件路径与 JSON 结构（精确字段路径）

```go
// workspace.go
路径: $pkgVar/dsh-data/storages/workspace.json

type workspaceFile struct {
	Unit struct {
		Name    string `json:"name"`     // 必须为 "workspace"
		Version int    `json:"version"`  // 当前为 2
	} `json:"unit"`
	Global struct {
		Initialized        bool     `json:"initialized"`
		WorkspaceIDs       []string `json:"workspaceIds"`        // 注册表顺序
		ArchivedSessionIDs []string `json:"archivedSessionIds"`
	} `json:"global"`
	Tables struct {
		Workspaces map[string]workspaceFileRecord `json:"workspaces"` // key = workspaceID
	} `json:"tables"`
}

type workspaceFileRecord struct {
	Path       string   `json:"path"`
	Title      string   `json:"title"`
	SessionIDs []string `json:"sessionIds"`
	CreatedAt  string   `json:"createdAt"`   // ISO 字符串（前端 new Date() 解析）
	UpdatedAt  string   `json:"updatedAt"`   // ISO 字符串，排序用（字符串比较，非时间戳）
}
```

展示层结构（API/WS 返回）：

```go
type WorkspaceItem struct {
	WorkspaceID string   `json:"workspaceId"`
	Path        string   `json:"path"`
	Title       string   `json:"title"`
	SessionIDs  []string `json:"sessionIds"`
	CreatedAt   string   `json:"createdAt"`
	UpdatedAt   string   `json:"updatedAt"`
}
type WorkspaceValue struct {
	Items              []WorkspaceItem `json:"items"`
	ArchivedSessionIDs []string        `json:"archivedSessionIds"`
}
```

### 8.2 解析/校验规则

- JSON 解析失败 → `解析 workspace.json 失败: %s`
- `unit.name != "workspace"` → `不支持的存储单元: %s`
- `unit.version > 2` → `workspace.json 版本 %d 暂不支持`（v1/v2 都按当前结构解析，即 v1 与 v2 字段一致；>2 拒绝）
- `tables.workspaces` 为 null → 置空 map

### 8.3 排序规则

1. 先按 `global.workspaceIds` 的**注册表顺序**输出（表里不存在的 id 跳过）。
2. 注册表未列出但表里存在的记录（异常兜底）：按 `updatedAt` **字符串倒序**（`sort.Slice`，`leftovers[i].UpdatedAt > leftovers[j].UpdatedAt`）追加在末尾。
3. `archivedSessionIds` 直通，null → 空数组。

### 8.4 监听机制

- `StartWorkspaceWatch`：每 **1 秒** ticker 检查文件 mtime。
- `fetchWorkspaces`：文件不存在 → 保持现状返回 nil；`mtime <= lastWorkspaceMod && items 非空` → 跳过解析；解析成功后更新缓存、`lastWorkspaceMod`，并广播通知。
- 持续错误去重：同一错误消息只记一次日志（`工作区数据同步失败: %s`），成功后重置。
- API `GET /api/workspace/list` 每次先强制 fetch 再返回缓存；失败 → `读取工作区失败: %s`。

---

## 9. logger.go

### 9.1 轮转参数与文件命名

```go
// logger.go
const (
	maxLogSize = 3 * 1024 * 1024 // 3MB（单文件上限）
	maxBackups = 3               // 保留 3 份历史轮转文件
)

日志文件: $pkgVar/harness.log
历史归档命名（Go 时间格式串，逐字）:
	主格式: harness-2006-01-02_15-04-05.log   → 如 harness-2026-08-22_18-30-05.log
	冲突时: harness-%s_%d.log，%d = time.Now().Nanosecond()/1000（微秒）
```

- 轮转触发时机：**写入前**检查 `currentLogSize + entryLen >= maxLogSize` 即先轮转再写。
- 轮转动作：关闭当前句柄 → rename harness.log → 归档名 → `cleanOldBackups` → 重新以 `O_TRUNC` 新建 harness.log，`currentLogSize = 0`。
- `cleanOldBackups`：目录内匹配（前缀 `harness-` 且后缀 `.log`）或（前缀 `harness.log.`）的文件名，**按文件名字典升序**，最旧的删起，直到 ≤ 3 份。
- `ClearLogs`（清空）：关闭句柄，以 `O_TRUNC` 重建，size 归零（不动历史归档）。

### 9.2 日志行格式

```go
// logger.go
timestamp = time.Now().Format("2006-01-02 15:04:05")
entry = fmt.Sprintf("%s [%-5s] %s\n", timestamp, level, msg)
// level: "INFO" / "WARN" / "ERROR" / "FATAL"，%-5s 左对齐补空格到 5 字符
```

输出目标：`io.MultiWriter(os.Stdout, logFile, broadcastWriter{})`（文件打开失败时退化为 stdout + broadcast）。broadcastWriter 将每段写入内容推给所有 WebSocket 日志订阅者（chan，非阻塞投递）。

`LogFatal` 写入后 `os.Exit(1)`。

### 9.3 ANSI 剥离正则（逐字）

```go
// logger.go
var ansiRegex = regexp.MustCompile(`\x1b\[[0-9;?]*[a-zA-Z]|\x1b\([a-zA-Z]`)

func cleanLogLine(b []byte) string {
	s := string(b)
	s = ansiRegex.ReplaceAllString(s, "")
	s = strings.TrimRight(s, "\r\n ")    // 去右侧 \r \n 空格
	s = strings.TrimLeft(s, "\r\n")      // 去左侧 \r \n
	return s
}
```

### 9.4 LineLogWriter 行缓冲刷新规则

```go
// logger.go
Write(p):
	追加到内部 buf；
	循环找 '\n'：每找到一行 → cleanLogLine(该行) 非空才调用 logFunc("%s", clean)；
	已消费字节从 buf 移除（含 '\n'）。
Flush():
	buf 残留非空 → cleanLogLine 后非空才输出，然后 Reset。
Close() = Flush()。
级别选择 NewLogWriter(level)："WARN"/"WARNING"（大小写不敏感，TrimSpace）→ Warn writer；其余 → Info writer。
```

---

## 10. config.go InitAppEnv / ApplyProxyEnv

### 10.1 InitAppEnv 全部环境变量（键 = 值来源）

前置常量：`nodeBinDir = /var/apps/nodejs_v24/target/bin`（build.go）。

```go
// config.go — 按设置顺序逐个列出
PATH                  = <pkgVar>/pnpm-env/node_modules/.bin : /var/apps/nodejs_v24/target/bin : /bin : /usr/bin : <原PATH>
                        （Go 用 "+" 拼接，分隔符为 "：" 即 ASCII 冒号）
HOME                  = <pkgVar>/home      （先 MkdirAll 0755）
CI                    = true
PNPM_HOME             = <pkgVar>/pnpm-home
pnpm_config_store_dir = <pkgVar>/pnpm-home/store
npm_config_store_dir  = <pkgVar>/pnpm-home/store
npm_config_cache      = <pkgVar>/npm-cache
npm_config_registry   = https://registry.npmmirror.com
NPM_CONFIG_REGISTRY   = https://registry.npmmirror.com
pnpm_config_registry  = https://registry.npmmirror.com
PNPM_CONFIG_REGISTRY  = https://registry.npmmirror.com
DSH_HOME              = <pkgVar>/dsh-data
DSH_AGENTS_HOME       = <pkgVar>/dsh-data/agents
```

附带动作：`$HOME/.npmrc` 不存在时写入内容 `"registry=https://registry.npmmirror.com\n"`（0644）。最后调用 `ApplyProxyEnv()`。

### 10.2 ApplyProxyEnv 的 NO_PROXY 精确内容

```go
// config.go
noProxy := "localhost,127.0.0.1,::1,registry.npmmirror.com,npmmirror.com"
```

NetworkProxy 非空时设置（值均为 cfg.NetworkProxy，除 noproxy）：

```
npm_config_proxy, npm_config_https_proxy → NetworkProxy
npm_config_noproxy                       → noProxy
HTTP_PROXY, HTTPS_PROXY, ALL_PROXY       → NetworkProxy
NO_PROXY, no_proxy                       → noProxy
```

NetworkProxy 为空时 **全部 Unsetenv**（上列 9 个键）。

### 10.3 Config 结构（config.json）

```go
// config.go — $pkgVar/config.json，默认 ServerPort=2298, ProxyPort=2299,
// AccessMode 缺省推导: ReverseProxyURL 非空 → "custom"，否则 "fngateway"
type Config struct {
	ServerPort      int    `json:"server_port"`
	ProxyPort       int    `json:"proxy_port"`
	NetworkProxy    string `json:"network_proxy"`
	AccessMode      string `json:"access_mode,omitempty"`
	ReverseProxyURL string `json:"reverse_proxy_url,omitempty"`
	AccessPassword  string `json:"access_password,omitempty"`
	DataLibraryPath string `json:"data_library_path,omitempty"`
	Version         string `json:"version,omitempty"`
	Commit          string `json:"commit,omitempty"`
	BuildTime       string `json:"build_time,omitempty"`
	LastRunState    string `json:"last_run_state,omitempty"`
}
```

写入：MarshalIndent 2 空格 → `config.json.tmp` → rename（原子替换）。`BuildTime` 格式 `2006-01-02 15:04`。

保存校验文案（api.go handleSaveConfig）：

```
端口号必须在 1 ~ 65535 之间
内部监听端口与反向代理端口不能相同 (%d)
内部监听端口 %d 已被占用，请更换端口
反向代理端口 %d 已被占用，请更换端口
应用设置保存成功
服务端口已变更 (%d → %d)，正在自动重启服务
```

---

## 11. harness.go 健康检查与就绪激活

### 11.1 状态常量

```go
// harness.go
StatusStopped  = "stopped"
StatusStarting = "starting"
StatusRunning  = "running"
StatusBuilding = "building"
```

`SetStatus` 副作用：非 building 状态清空 targetCommit；变为 running 时记录 startTime；状态或消息变化时打日志 `[状态变更] %s → %s: %s`（无消息时省略 `: %s`）并广播。

### 11.2 waitAndActivateReverseProxy 精确参数

```go
// harness.go
targetURL = fmt.Sprintf("http://127.0.0.1:%d", port)   // port = cfg.ServerPort（<=0 时取 2298）
HTTP client Timeout: 500 * time.Millisecond
探测 ticker:        200 * time.Millisecond
总超时:             time.After(60 * time.Second)
TCP 兜底拨号:        net.DialTimeout("tcp", "127.0.0.1:<port>", 200*time.Millisecond)
```

**就绪判定**：HTTP `client.Get(targetURL)` **任何响应（无论状态码）都算就绪**（err == nil 即 ready，随即 Close body）；HTTP 失败则尝试 TCP 拨号，拨号成功也算就绪。

**没有"就绪行"字符串匹配**——就绪探测完全是 HTTP/TCP 层，不扫描 stdout 日志行。

### 11.3 状态转换精确顺序

```go
// harness.go — 启动链路
startLocked():
  1. killHarnessLocked()        // 连根清理旧进程/端口
  2. fixPermissions(srcDir)
  3. 组命令: dshCliCmd("web", "--port", "<port>")
  4. cmd.Start() 失败 → state.SetStatus(StatusStopped, "启动失败: "+err)
  5. 写 PID 文件 $pkgVar/harness.pid（内容 = 十进制 PID 字符串）
  6. state.SetStatus(StatusStarting, "服务主进程已拉起，正在等待 Web 服务就绪...")
     日志: "服务主进程已拉起 (PID=%d)，正在等待 Web 服务就绪..."
  7. go waitAndActivateReverseProxy(mp, port)
  8. go mp.cmd.Wait() 退出回收（见下）

waitAndActivateReverseProxy 就绪分支（严格顺序）:
  procMu.Lock()
  条件: process == mp && !mp.stopRequested && mp.cmd != nil && mp.cmd.Process != nil && isProcessAlive(pid)
  满足则依次:
    a. startReverseProxy()                    // 先拉起反代
    b. state.SetStatus(StatusRunning, "")     // 再置 running（空消息）
    c. SetLastRunState(StatusRunning)         // 持久化 last_run_state
  procMu.Unlock(); return

超时分支（60s）:
  日志: "Web 服务就绪探测超时 (60s)，目标端口: %d"
  process == mp 时: killHarnessLocked() + SetStatus(StatusStopped,
      fmt.Sprintf("Web 服务就绪探测超时 (端口 %d 未响应)", port))

进程退出分支（mp.done）: 直接 return（由 Wait 回收协程处理）

Wait 回收协程（process == mp 时）:
  process = nil; removePidFileIfMatches(pid); stopReverseProxy()
  stopRequested   → "服务主进程已按要求停止 (PID=%d)"，状态 (stopped, "")
  err != nil      → "服务主进程异常退出 (PID=%d): %s"，状态 (stopped, "进程意外退出: "+err)
  正常退出        → "服务主进程正常退出 (PID=%d)"，状态 (stopped, "")
```

### 11.4 Start 前置拒绝文案

```
正在构建中，请稍候再试
服务正在启动中，请稍候
服务已在运行中
运行环境未就绪或关键文件缺失
依赖未安装或文件缺失      // srcDir/node_modules 不存在
```

`isSourceValid`：srcDir 是目录 且 `srcDir/package.json` 存在且非目录。

### 11.5 看门狗（process.go）

- 每 **3 秒** tick 一次 `inspectAndHeal`：
  - running：内存句柄缺失或 `kill(pid,0)` 失败 → 清理（removePidFile、stopReverseProxy、`fuser` 查端口杀孤儿进程），状态 (stopped, `巡检发现进程已异常终止`)；日志 `巡检发现服务主进程已终止 (PID=%d)，执行状态自愈与残留清理`、`清理霸占端口 %d 的孤儿残留进程 (PID=%d)`。
  - starting：pid 死 → 纠偏 (stopped, `服务进程启动期间意外退出`)；日志 `巡检发现 starting 状态进程已死 (PID=%d)，纠偏为 stopped`。
  - stopped：删除指向死进程的 PID 文件。
- `isProcessAlive`：`syscall.Kill(pid, 0) == nil`。
- `killProcessGroup`：先 `SIGTERM` 到 `-pgid` → 最多等 **3 秒**（每 **50ms** 轮询）→ 仍活则 `SIGKILL` → 再等 **100ms** → 返回是否 ESRCH。
- `killProcessTree`：`ps -o pgid= -p <pid>` 查 PGID，能查到则按组杀，否则仅 `SIGKILL` 单进程。
- `findPidsOnPort`：`fuser <port>/tcp`。
- `waitForPortFree`：最多 **500ms**（每 50ms 轮询）。

### 11.6 运行时长格式（formatDuration）

```go
// harness.go — 供 statusPayload.uptime 使用
四舍五入到秒；h>0 → "%d小时%d分%d秒"；m>0 → "%d分%d秒"；否则 "%d秒"
```

---

## 12. api.go statusPayload / readLastNLines

### 12.1 statusPayload 全部字段名（对齐命名用）

```go
// api.go — gin.H 键名逐字列出
{
	"name":          "DeepSeek Harness",     // 固定字符串
	"version":       verVal,        // version=="" 时为 nil（JSON null），否则字符串
	"commit":        commitVal,     // 同上 nil 规则
	"target_commit": targetCommit,  // string（无 nil 规则，空为 ""）
	"status":        status,        // stopped/starting/running/building
	"uptime":        uptimeVal,     // 非运行时为 ""（nil 规则：非空才输出值，空→nil）
	"started_at":    startedAt,     // Unix 秒；仅 running 时非 0
	"server_port":   serverPort,    // cfg.ServerPort，<=0 → 2298
	"server_time":   time.Now().Unix(),
	"build_time":    buildTimeVal,  // nil 规则同上
	"app_url":       ":" + port + "/",   // port=cfg.ProxyPort(<=0→2299)，如 ":2299/"
	"pid":           pidVal,        // 仅 status∈{running,starting} 且 PID 文件可读、
	                                 // pid>0 且进程存活时为 int，否则 nil
	"last_message":  lastMsg,       // string
}
```

### 12.2 统一响应信封

```go
// api.go
type ApiResponse struct {
	Code      int    `json:"code"`             // 成功 0；失败 = HTTP 状态码
	Message   string `json:"message"`          // 成功固定 "success"（OK()）或自定义
	Data      any    `json:"data,omitempty"`
	Timestamp int64  `json:"timestamp,omitempty"` // UnixMilli
}
```

路由 base：`/app/deepseek-harness`，API 前缀 `/app/deepseek-harness/api`。未知 API 路径 404 返回 `{"message": "接口不存在"}`。监听 Unix Socket `$TRIM_APPDEST/web.sock`（chmod 0666）。

### 12.3 WebSocket 协议（handleWS）

```go
// api.go
上行: {"type":"ping"} → 下行 {"type":"pong","data":{"server_time":<Unix秒>},"timestamp":<UnixMilli>}
连接即推: status / workspace / plugin 快照
事件推送 type: "status" | "workspace" | "plugin" | "log"（log 的 data 是原始日志文本块）
服务端心跳: 每 15 秒 websocket Ping 帧
信封: {type, data, timestamp(UnixMilli)}
```

### 12.4 readLastNLines 精确算法参数

```go
// api.go
func readLastNLines(path string, maxLines int) ([]string, string, error)
- size == 0 → ([], "", nil)
- size <= 512*1024（512KB）→ 全量读取，按 "\n" 切分，丢弃空行，
  其余行追加 "\n" 重组；超 maxLines 取末尾 maxLines
- size > 512KB → ReadAt 读末尾 256*1024（256KB）：
  readSize = min(256*1024, size)
  若 readSize < size（即发生了截断）→ 丢弃第一个 "\n" 之前的不完整半行
  （若找不到 "\n" 则整块保留）
  同样按 "\n" 切分、丢空行、行尾补 "\n"、截取末尾 maxLines
返回: (lines, strings.Join(lines, ""), nil)

handleGetLogs: query 参数 limit，默认 "150"；非法或 <=0 → 150
文件不存在 → 返回空 {Lines:[], Content:"}
```

日志 API：`GET /logs`（LogPayload `{lines:[], content:""}`）、`DELETE /logs`（消息 `运行日志已清空`）、`GET /logs/download`（附件名 `harness.log`）。

### 12.5 action 响应消息（api.go handleAction）

```
start        → "服务正在启动…"
stop         → "服务已停止"
restart      → "服务正在重启…"
upgrade      → "开始拉取远程更新并构建…"
rebuild      → "开始强制重建源码…"
repair/reset → "开始恢复出厂设置…"
```

错误文案：`参数错误`、`正在构建中，请稍候再试`、`服务正在启动中，请稍候`、`未检测到内置离线安装包，无法执行恢复出厂设置`、`未知操作: %s`。
HTTP 状态映射（actionErrStatus）：错误含 `源码不存在`→404；含 `构建中`/`启动中`/`运行中`/`依赖未安装`→409；其余→500。

---

## 13. 前端文案全集（Vue）

> 来源：`frontend/src/App.vue`、`views/*.vue`、`stores/system.ts`、`stores/plugin.ts`。SwiftUI 复用请逐字取用。

### 13.1 App.vue（导航/框架）

- 品牌区：`DeepSeek` / `Harness 管理器`
- 桌面菜单：`概览` `工作区` `插件管理` `运行日志` `应用设置`
- 移动底栏：`概览` `工作区` `插件` `日志` `设置`
- 页面标题（setTitle）：`概览 · DeepSeek Harness`、`工作区 · DeepSeek Harness`、`插件管理 · DeepSeek Harness`、`运行日志 · DeepSeek Harness`、`应用设置 · DeepSeek Harness`
- 离开提示（设置页未保存）：title `设置未保存`，content `当前设置有未保存的修改，离开可能丢失这些内容。`

### 13.2 Overview.vue（概览页）

状态标签（stores/system.ts）：

```
running → 运行中   starting → 启动中   building → 构建中   其它 → 已停止
uptime 格式: X小时X分X秒 / X分X秒 / X秒；非运行显示 "-"
```

页面文案：

```
页头: 概览
主按钮: 进入 Harness
信息行: 版本: {{...}} | Commit: {{...}} | Build: {{...}}（空显示 "-"）
构建中徽章: <短commit> → <target_commit短>
统计卡: 运行状态 / 运行时间 / 进程 PID
分区标题: 运行控制
断连提示: 实时连接已断开，正在自动重连…
```

运行控制四卡（label / desc / 确认文案）：

| 动作 | label | desc | confirmText |
|---|---|---|---|
| stop | `停止服务` | `终止 DeepSeek Harness 后台运行进程` | - |
| start | `启动服务`（starting 时 `服务启动中`） | `拉起 DeepSeek Harness 后台核心服务`（starting 时 `正在拉起服务主进程并等待就绪…`） | - |
| restart | `重启服务` | `热重启后台进程，即时生效最新配置或插件变更` | - |
| check_update | `检查更新`（进行中 `检查中…`） | `检查远程代码更新，检测到新版本时确认后再同步依赖并构建` | - |
| rebuild | `强制重建` | `重新拉取全部依赖并完整编译，用于修复异常损坏的环境` | `强制重建将重新拉取依赖并编译，耗时较长，确定继续？` |

确认弹窗通用：title `确认${label}？`，按钮 `确认` / `取消`。

更新确认弹窗：

```
title: 发现新版本     按钮: 立即更新 / 稍后再说
正文: 检测到远程仓库有新版本，是否立即开始更新？
字段: 当前版本 / 最新版本
提示: 提示：更新将短暂停止服务并重新编译依赖，完成后自动重启。
```

Toast 文案：`已开始更新并构建`、`更新启动失败`、`检查更新失败，请检查网络`、`当前已是最新版本`、`操作成功`、`操作失败`。动作锁提示：`当前有任务正在进行中，请稍候`、`正在检查更新中，请稍候`。

### 13.3 Plugins.vue（插件页）

```
页头: 插件管理    计数: 共 N 个插件
主按钮: 安装插件 / 收起
```

重启提醒横幅：

```
title: 插件配置已变更
正文: 检测到插件安装或配置更新，为了使改动完全生效，建议重启服务。
按钮: 重启服务
```

市场推荐卡（未装 dshmarket 时）：

```
标题: 推荐安装「dshmarket」插件市场
描述: 第三方插件市场，安装后可在DSH设置中直接可视化浏览、搜索与管理社区插件及主题。
按钮: 安装
市场链接: https://awesome-dsh-plugin.com/zh
快捷安装命令: dsh plugin --profile web add dshmarket
```

安装面板：

```
标题: 安装新插件
按钮: 取消 / 安装（执行中显示 正在执行…）
输入框 placeholder: 例如: dsh plugin --profile web add dshmarket
帮助行: 支持: npm 包、@scoped 包、github:user/repo
链接: 插件精选列表
解析反馈: 将执行: ${preview.command}   失败: ${preview.reason}（无结果时 解析中…）
```

筛选与搜索：

```
Tab: 全部 / 运行中 / 已停用 （各带计数）
搜索 placeholder: 搜索插件名 / 描述 / 作者...
刷新按钮 tooltip: 刷新插件列表
```

空状态：

```
加载中: 正在获取插件列表…
有筛选: 未找到匹配的插件（按钮 重置筛选条件）
无插件: 暂无已安装插件（按钮 安装新插件）
```

插件条目：

```
版本 tag: v{{version}}
状态 tag: live→运行中  disabled→已停用  inert→普通依赖
保护 tag: 系统核心
元数据: 作者: {{author}}  来源: {{spec}}  主页（链接）
操作按钮: 卸载 / 更新
更新按钮 tooltip: 检查并拉取该插件最新版本
移动端开关旁文案: 已启用 / 已停用
保护开关 tooltip: 核心基础设施插件受到保护，不可停用
```

确认弹窗：

```
重启: title 确认立即重启服务？
      content 检测到插件配置已更新，为了使改动完全生效需要重启服务。重启将短暂中断当前所有 AI 对话连接，是否确认继续？
      按钮 确认重启 / 取消
卸载: title 确认卸载插件？
      content 确定要卸载插件「${name}」吗？卸载后将自动清理相关的运行时依赖与配置补丁。
      按钮 确认卸载 / 取消
```

Toast 文案：

```
重启指令已发送，正在等待服务就绪… / 重启失败
插件列表已刷新
已开始执行插件安装 / 安装失败
已发送取消指令，正在终止进程… / 取消失败
已启用插件 / 已禁用插件 / 操作失败
已开始更新 ${name} / 更新失败
已开始卸载 ${name} / 卸载失败
请先输入有效的安装指令     // canInstall=false 时
命令解析失败               // preview 请求失败兜底
```

插件操作触发的更新/卸载命令（stores/plugin.ts，逐字）：

```
更新: dsh plugin --profile web update ${name}
卸载: dsh plugin --profile web remove ${name}
```

### 13.4 Logs.vue（日志页）

```
页头: 运行日志
按钮: 自动滚动（开关）/ 下载 / 清空（title: 下载日志、清空日志）
加载遮罩: 正在获取运行日志…
悬浮按钮 tooltip: 回到底部（距底部 > 40px 时出现）
确认弹窗: title 确认清空运行日志？
          content 确定要清空所有历史运行日志吗？清空后将无法恢复。
          按钮 确认清空 / 取消
Toast: 运行日志已清空 / 清空日志失败
```

日志高亮规则（harness-log 语言，highlight.js，正则逐字）：

```
[FATAL]|[ERROR]      → type（错误）
[WARN]|[WARNING]     → keyword（警告）
[INFO]               → meta（信息）
/\d{4}[-/]\d{2}[-/]\d{2}(?:[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)?/  → comment（时间戳）
/https?:\/\/[^\s]+/  → link
/(?:\/[\w.-]+)+\/?/  → string（路径）
/\b\d+\b/            → number
```

亮色高亮配色：type `#ef4444`、keyword `#f59e0b`、meta `#2563eb`、comment `#94a3b8`、number `#0891b2`、string `#059669`、link `#4f46e5`；
暗色：`#f87171` / `#fbbf24` / `#60a5fa` / `#64748b` / `#38bdf8` / `#34d399` / `#818cf8`。字号 12，行高 1.5。

### 13.5 Settings.vue（设置页）

```
页头: 应用设置    按钮: 取消 / 保存设置
加载失败: 配置加载失败（按钮 重新加载）
```

核心服务卡（title `核心服务`）：

```
内部监听端口   tooltip: DeepSeek Harness 本地后端进程监听端口，默认 2298    placeholder: 2298
反向代理端口   tooltip: 对外暴露的代理访问端口 (默认 2299)，用于 Web 客户端直连  placeholder: 2299
打开方式选择   tooltip: 控制概览页「进入 Harness」按钮的访问链路
               选项: 飞牛网关(fngateway) / 反代端口(port) / 自定义地址(custom)
反代访问密码   tooltip: 反向代理端口的访问密码，留空则不开启访问校验    placeholder: 留空则不启用密码保护
自定义外部访问地址（仅 custom 模式显示）
               tooltip: 点击概览页「进入 Harness」时跳转的绝对 URL (例如 https://dsh.nas.com:2299)
               placeholder: 例如 https://dsh.example.com:2299
```

网络代理卡（title `网络代理`）：

```
网络代理地址 (HTTP / SOCKS5)
tooltip: 用于 Git Clone 拉取仓库，留空使用系统直连
placeholder: 例如 http://192.168.1.100:7890 或 socks5://192.168.1.100:7890
```

重置修复卡（title `重置修复`）：

```
标题: 重置为初始运行环境    按钮: 重置
说明: 适用于插件冲突、环境损坏或服务启动异常等场景。将移除所有第三方插件与补丁修改并恢复纯净环境，您的模型 API 密钥、历史会话记录与系统设置将完整保留。
```

表单校验文案（逐字）：

```
请输入内部监听端口 / 端口范围必须在 1 ~ 65535 之间 / 内部监听端口不能与反向代理端口相同
请输入反向代理端口 / 反向代理端口不能与内部监听端口相同
代理地址需以 http://、https:// 或 socks5:// 开头
请填写自定义外部访问地址 / 外部访问地址需以 http:// 或 https:// 开头
表单不完整 toast: 请检查表单填写是否正确
```

前端校验正则（逐字）：

```
代理地址: /^(http|https|socks5|socks5h):\/\//i
外部地址: /^(http|https):\/\//i
```

保存重启确认弹窗：

```
title: 确认保存并重启核心服务？    按钮: 保存并重启 / 取消
content: 检测到内部监听端口已由 ${旧端口 || 2298} 变更为 ${新端口}。保存设置后，系统将自动重启 DeepSeek Harness 后端进程以应用新端口。当前所有正在执行的任务可能会短暂中断，是否确认继续？
```

重置确认弹窗：

```
title: 确认重置运行环境？    按钮: 确认重置 / 取消
content: 此操作将终止当前服务并重新部署内置版本，清空所有第三方插件、依赖修改与补丁配置。您的模型 API 密钥、历史会话记录与系统设置将完整保留。是否确认继续？
```

Toast：`加载配置失败`、`设置保存成功`、`保存设置失败`、`已取消修改`、`已开始重置运行环境…`、`重置运行环境失败`。

### 13.6 Workspace.vue（工作区页）

```
页头: 工作区    计数: 共 N 个
按钮: 数据目录
tooltip: 在文件管理中打开: ${dataLibraryPath}（未配置时: 数据目录路径未配置）
空状态: 暂无工作区数据 / 请先运行 DeepSeek Harness 并在客户端创建工作区
条目:
  标题: title || workspaceId || '-'
  会话 tag: {{n}} 会话    tooltip: 包含 {{n}} 个活动对话会话
  描述: path || '-'
  底部: 更新于 <相对时间>（tooltip: 更新于: {{createdAt本地化字符串}}）
        创建于 <yyyy-MM-dd>（tooltip: 创建于: {{...}}）
  头像 tooltip: 在文件管理中打开 {{item.title || '此工作区'}}
错误 toast: 打开数据目录失败：${message || '未知错误'} / 打开文件管理器失败：${message || '未知错误'}
```

### 13.7 前端进入 Harness 的三种链路（stores/system.ts openHarnessApp）

```
access_mode = custom 且配置了 reverse_proxy_url → 打开 reverse_proxy_url
access_mode = port   → 打开 https://<当前hostname>:<proxy_port || 2299>/
默认 fngateway      → 打开 <origin>/app/deepseek-harness/fngateway/
```

---

## 附录 A：其它值得移植的常量速查

```go
// build.go
repoURL    = "https://github.com/deepseek-ai/deepseek-harness"
nodeBinDir = "/var/apps/nodejs_v24/target/bin"
gitBin     = "/usr/bin/git"
pnpmBin()  = $pkgVar/pnpm-env/node_modules/.bin/pnpm
pnpm 安装: npm install pnpm --registry=https://registry.npmmirror.com（cwd=$pkgVar/pnpm-env）
srcDir     = $pkgVar/src/deepseek-harness
构建: pnpm install --prefer-offline --config.confirm-modules-purge=false --registry https://registry.npmmirror.com [--force]
      pnpm run build
sparse-checkout set: packages apps vendor native patches scripts website
git fetch: git -c safe.directory=* [-c http.proxy=... -c https.proxy=...] -C <src> fetch --depth=1 origin
CheckUpdate 超时: 15s
```

```go
// api.go / fngateway.go
basePath         = "/app/deepseek-harness"
fnGatewayPrefix  = "/app/deepseek-harness/fngateway"
```

```go
// harness.go InitHarness 自启条件: GetLastRunState() == "running" 时自动拉起
// 日志: 检测到上次运行状态为 running，正在自动拉起服务
//       上次运行状态非 running (%s)，跳过自动启动
```

```go
// build.go formatGitError 网络受阻判定子串（转小写后包含）:
"could not resolve host" / "failed to connect" / "connection timed out" /
"connection refused" / "ssl" / "gnutls" / "network is unreachable" / "timed out"
命中 → "%s（网络连接受阻，请在【应用设置】配置代理）: %s"，否则 "%s: %s"
```

```go
// build.go 更新检查消息格式:
"发现新版本 [ %s → %s ]"      // formatVersionTag: "v%s (%s)" / "v%s" / 短commit / "-"
"当前已是最新版本 [ %s ]"
"检查更新超时 (15s)，请检查网络连接或代理设置"
"本地源码未就绪，需初始化拉取"
```

## 附录 B：进程/凭证文件路径速查

| 用途 | 路径 |
|---|---|
| 源码目录 | `$pkgVar/src/deepseek-harness` |
| web profile 目录 | `$pkgVar/dsh-data/profiles/web` |
| profile package.json | `$pkgVar/dsh-data/profiles/web/package.json` |
| cordis.patch.yml | `$pkgVar/dsh-data/profiles/web/cordis.patch.yml` |
| pnpm-workspace.yaml | `$pkgVar/dsh-data/profiles/web/pnpm-workspace.yaml` |
| allowbuilds sidecar | `$pkgVar/plugins/allowbuilds.json` |
| workspace.json | `$pkgVar/dsh-data/storages/workspace.json` |
| 运行日志 | `$pkgVar/harness.log` |
| PID 文件 | `$pkgVar/harness.pid` |
| 凭据文件（chmod 0600） | `$pkgVar/dsh-data/.credentials.yaml` |
| 配置 | `$pkgVar/config.json` |
| Unix Socket | `$TRIM_APPDEST/web.sock`（0666） |
| 离线包 | `$TRIM_APPDEST/deepseek-harness.tar.gz`（版本标记 `$TRIM_APPDEST/.version`） |
