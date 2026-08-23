import XCTest
@testable import DSHLauncher

final class SemVerTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(SemVer("v22.19.0")?.major, 22)
        XCTAssertEqual(SemVer("1.2.3")?.patch, 3)
        XCTAssertEqual(SemVer("1.2.3-rc.1")?.preRelease, ["rc", "1"])
        XCTAssertNil(SemVer("abc"))
    }

    func testCompare() {
        XCTAssertLessThan(SemVer("1.2.3")!, SemVer("1.10.0")!)
        XCTAssertLessThan(SemVer("1.2.3")!, SemVer("1.2.4")!)
        XCTAssertLessThan(SemVer("1.2.3")!, SemVer("2.0.0")!)
        XCTAssertLessThan(SemVer("1.0.0-alpha")!, SemVer("1.0.0")!)
        XCTAssertLessThan(SemVer("1.0.0-alpha.1")!, SemVer("1.0.0-alpha.2")!)
        XCTAssertEqual(SemVer("1.0.0")!, SemVer("1.0.0")!)
    }

    func testNodeRequirement() {
        XCTAssertTrue(SemVer.satisfiesNode(SemVer("v22.19.0")!))
        XCTAssertTrue(SemVer.satisfiesNode(SemVer("22.20.0")!))
        XCTAssertTrue(SemVer.satisfiesNode(SemVer("24.0.0")!))
        XCTAssertTrue(SemVer.satisfiesNode(SemVer("26.7.0")!))
        XCTAssertFalse(SemVer.satisfiesNode(SemVer("22.18.9")!))
        XCTAssertFalse(SemVer.satisfiesNode(SemVer("23.5.0")!))
    }

    func testCompareVersionsHelper() {
        XCTAssertEqual(PluginService.compareVersions("1.2.0", "1.1.9"), 1)
        XCTAssertEqual(PluginService.compareVersions("1.2.0", "1.2.0"), 0)
        XCTAssertEqual(PluginService.compareVersions("whatever-a", "whatever-b"), -1)
    }
}

final class PluginParsingTests: XCTestCase {
    func testSplitCommandLine() {
        let r1 = PluginParsing.splitCommandLine("dsh plugin --profile web add dshmarket")
        XCTAssertEqual(r1.tokens, ["dsh", "plugin", "--profile", "web", "add", "dshmarket"])
        XCTAssertEqual(r1.error, nil)

        let r2 = PluginParsing.splitCommandLine("a \"b c\" 'd'e")
        XCTAssertEqual(r2.tokens, ["a", "b c", "de"])

        let r3 = PluginParsing.splitCommandLine(#"a\ b"#)
        XCTAssertEqual(r3.tokens, ["a b"])

        let r4 = PluginParsing.splitCommandLine("  multiple   spaces\tand\ttabs ")
        XCTAssertEqual(r4.tokens, ["multiple", "spaces", "and", "tabs"])

        XCTAssertNotNil(PluginParsing.splitCommandLine("\"unclosed").error)
        XCTAssertEqual(PluginParsing.splitCommandLine("\"unclosed").error, "引号未闭合")
    }

    func testParseValid() {
        let (cmd, err) = PluginParsing.parse("dsh plugin --profile web add dshmarket")
        XCTAssertNil(err)
        XCTAssertEqual(cmd?.verb, .add)
        XCTAssertEqual(cmd?.profile, "web")
        XCTAssertEqual(cmd?.specs, ["dshmarket"])

        let (cmd2, _) = PluginParsing.parse("dsh plugin rm @scope/pkg")
        XCTAssertEqual(cmd2?.verb, .remove)
        XCTAssertEqual(cmd2?.profile, "web")
        XCTAssertEqual(cmd2?.specs, ["@scope/pkg"])

        let (cmd3, _) = PluginParsing.parse("dsh plugin --profile mine up github:user/repo")
        XCTAssertEqual(cmd3?.profile, "mine")
        XCTAssertEqual(cmd3?.verb, .update)
        XCTAssertEqual(cmd3?.specs, ["github:user/repo"])
    }

    func testParseErrors() {
        XCTAssertNil(PluginParsing.parse("").command)
        XCTAssertEqual(PluginParsing.parse("").reason, "请输入插件命令")
        XCTAssertEqual(PluginParsing.parse("npm install foo").reason,
                       "请输入标准 dsh 命令，例如: dsh plugin --profile web add 包名")
        XCTAssertEqual(PluginParsing.parse("dsh plugin --profile").reason, "--profile 缺少参数")
        XCTAssertNil(PluginParsing.parse("dsh plugin --profile 'bad name' add foo").command)
        XCTAssertEqual(PluginParsing.parse("dsh plugin --other add foo").reason, "不支持的参数: --other")
        XCTAssertEqual(PluginParsing.parse("dsh plugin").reason,
                       "缺少操作动词（支持 add / remove / update / list / why / install）")
        XCTAssertEqual(PluginParsing.parse("dsh plugin foo bar").reason,
                       #"未知操作 "foo"（支持 add / remove / update / list / why / install）"#)
        XCTAssertEqual(PluginParsing.parse("dsh plugin add").reason, "add 操作需要一个或多个包名")
        XCTAssertEqual(PluginParsing.parse("dsh plugin install foo").reason, "install 操作不接受包名参数")
        XCTAssertEqual(PluginParsing.parse("dsh plugin add ../x").reason,
                       #"参数 "../x": 不支持相对路径，请输入标准 npm 包名或 Git 仓库地址"#)
    }

    func testValidateSpec() {
        XCTAssertNil(PluginParsing.validateSpec("foo"))
        XCTAssertNil(PluginParsing.validateSpec("@scope/pkg"))
        XCTAssertNil(PluginParsing.validateSpec("pkg@1.2.3"))
        XCTAssertNil(PluginParsing.validateSpec("github:user/repo"))
        XCTAssertNil(PluginParsing.validateSpec("github:user/repo#main"))
        XCTAssertNil(PluginParsing.validateSpec("git+https://github.com/a/b.git"))
        XCTAssertNil(PluginParsing.validateSpec("ssh://git@github.com/a/b.git"))
        XCTAssertNil(PluginParsing.validateSpec("file:///abs/path"))
        XCTAssertNil(PluginParsing.validateSpec("/abs/path"))
        XCTAssertEqual(PluginParsing.validateSpec("a;b"), "包含不允许的字符")
        XCTAssertEqual(PluginParsing.validateSpec("a|b"), "包含不允许的字符")
        XCTAssertEqual(PluginParsing.validateSpec("a`b"), "包含不允许的字符")
        XCTAssertEqual(PluginParsing.validateSpec("$(x)"), "包含不允许的字符")
        XCTAssertEqual(PluginParsing.validateSpec("!!weird!!"), "无法识别的包名/地址格式")
        XCTAssertEqual(PluginParsing.validateSpec("  "), "包名为空")
    }

    func testNormalizePluginKey() {
        XCTAssertEqual(PluginParsing.normalizePluginKey("pkg@1.2.3"), "pkg")
        XCTAssertEqual(PluginParsing.normalizePluginKey("@scope/pkg@2.0.0"), "@scope/pkg")
        XCTAssertEqual(PluginParsing.normalizePluginKey("plain"), "plain")
        XCTAssertEqual(PluginParsing.normalizePluginKey("@scope/pkg"), "@scope/pkg")
    }

    func testPreviewOnlyAdd() {
        let p = PluginParsing.preview("dsh plugin --profile web add dshmarket")
        XCTAssertTrue(p.valid)
        XCTAssertEqual(p.command, "dsh plugin --profile web add dshmarket")
        let p2 = PluginParsing.preview("dsh plugin list")
        XCTAssertFalse(p2.valid)
        XCTAssertEqual(p2.reason, "仅支持添加插件指令 (add)")
    }
}

final class PnpmFailureTests: XCTestCase {
    func testClassifyOrder() {
        XCTAssertEqual(PnpmFailure.classify("xxx ERR_PNPM_PUBLIC_HOIST_PATTERN_DIFF yyy").code, .hoistPatternDiff)
        XCTAssertEqual(PnpmFailure.classify("ERR_PNPM_UNEXPECTED_STORE").code, .unexpectedStore)
        XCTAssertEqual(PnpmFailure.classify("ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION").code, .releaseAge)
        XCTAssertEqual(PnpmFailure.classify("ERR_PNPM_NO_MATURE_MATCHING_VERSION").code, .releaseAge)
        XCTAssertEqual(PnpmFailure.classify("TimeoutError: operation timed out").code, .fetchTimeout)
        XCTAssertEqual(PnpmFailure.classify("error (23) aborted").code, .fetchTimeout)
        XCTAssertEqual(PnpmFailure.classify("ERR_PNPM_IGNORED_BUILDS present").code, .ignoredBuilds)
        XCTAssertEqual(PnpmFailure.classify("ERR_PNPM_GIT_DEP_PREPARE_NOT_ALLOWED here").code, .gitDepPrepare)
        XCTAssertEqual(PnpmFailure.classify("FetchError: ECONNRESET socket").code, .transientNetwork)
        XCTAssertEqual(PnpmFailure.classify("random nonsense").code, .unknown)
    }

    func testFetch404DetailPkg() {
        let info = PnpmFailure.classify("ERR_PNPM_FETCH_404 GET https://registry.npmmirror.com/@scope%2Ffoo - Not found")
        XCTAssertEqual(info.code, .fetch404)
        XCTAssertEqual(info.detailPkg, "@scope/foo")
        XCTAssertTrue(info.message.contains("「@scope/foo」"))
        XCTAssertFalse(info.recoverable)
    }

    func testFormatMessageMeaningfulLine() {
        let out = """
        some noise line
        npm ERR! 404 Not Found
        more noise
        """
        let msg = PnpmFailure.formatMessage(out)
        // unknown 分类 + meaningful 行（中文圆括号）
        XCTAssertEqual(msg, "插件指令执行失败（npm ERR! 404 Not Found）")
    }

    func testFormatMessageFallbackTruncate() {
        let long = String(repeating: "a", count: 200)
        let msg = PnpmFailure.formatMessage("head\nat somewhere\n\(long)")
        XCTAssertEqual(msg, "插件指令执行失败: " + String(repeating: "a", count: 120) + "…")
    }

    func testRecoverableFlags() {
        XCTAssertTrue(PnpmFailure.classify("ERR_PNPM_UNEXPECTED_STORE").recoverable)
        XCTAssertFalse(PnpmFailure.classify("whatever").recoverable)
    }
}

final class AllowBuildsTests: XCTestCase {
    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "/dsh-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: tmpDir)
    }

    func testParseBlockedPackages() {
        let out = "Ignored build scripts: esbuild@0.19.0, @biomejs/biome@1.2.3"
        XCTAssertEqual(AllowBuilds.parseBlockedPackages(out), ["esbuild", "@biomejs/biome"])
        let out2 = "Ignored build scripts: sharp, some-tool@2.0.0"
        XCTAssertEqual(AllowBuilds.parseBlockedPackages(out2), ["sharp", "some-tool"])
        XCTAssertTrue(AllowBuilds.parseBlockedPackages("nothing here").isEmpty)
    }

    func testMergeCreatesBlock() throws {
        let yaml = tmpDir + "/pnpm-workspace.yaml"
        try "packages:\n  - core\n".write(toFile: yaml, atomically: true, encoding: .utf8)
        try AllowBuilds.mergeEntries(yamlPath: yaml, pkgs: ["esbuild"])
        let content = try String(contentsOfFile: yaml, encoding: .utf8)
        XCTAssertTrue(content.contains("allowBuilds:\n  esbuild: true"))
        XCTAssertTrue(content.contains("packages:"))
    }

    func testMergeIntoExistingBlockKeepsComments() throws {
        let yaml = tmpDir + "/pnpm-workspace.yaml"
        let original = "packages:\n  - core\nallowBuilds:\n  # 注释保留\n  foo: true\n"
        try original.write(toFile: yaml, atomically: true, encoding: .utf8)
        try AllowBuilds.mergeEntries(yamlPath: yaml, pkgs: ["foo", "bar"])
        let content = try String(contentsOfFile: yaml, encoding: .utf8)
        XCTAssertTrue(content.contains("# 注释保留"))
        XCTAssertTrue(content.contains("foo: true"))
        // 新条目插在块头之后第一条
        let blockRange = content.range(of: "allowBuilds:\n")!
        let after = content[blockRange.upperBound...]
        XCTAssertTrue(after.hasPrefix("  bar: true"))
    }

    func testRemoveKeepsExplicitFalse() throws {
        let yaml = tmpDir + "/pnpm-workspace.yaml"
        try "allowBuilds:\n  foo: true\n  bar: false\n".write(toFile: yaml, atomically: true, encoding: .utf8)
        try AllowBuilds.removeEntries(yamlPath: yaml, drop: ["foo", "bar"])
        let content = try String(contentsOfFile: yaml, encoding: .utf8)
        XCTAssertFalse(content.contains("foo:"))
        XCTAssertTrue(content.contains("bar: false"))
    }

    func testSidecarEnsureAndCleanup() throws {
        let yaml = tmpDir + "/pnpm-workspace.yaml"
        let sidecar = tmpDir + "/allowbuilds.json"
        try AllowBuilds.ensureAllowed(profileWorkspaceYaml: yaml, sidecarPath: sidecar,
                                      pluginKey: "my-plugin", pkgs: ["esbuild", "sharp"])
        var map = AllowBuilds.loadSidecar(sidecar)
        XCTAssertEqual(map["esbuild"], ["my-plugin"])
        XCTAssertEqual(map["sharp"], ["my-plugin"])

        // 另一个插件也放行 sharp → 两条归属
        try AllowBuilds.ensureAllowed(profileWorkspaceYaml: yaml, sidecarPath: sidecar,
                                      pluginKey: "other", pkgs: ["sharp"])
        map = AllowBuilds.loadSidecar(sidecar)
        XCTAssertEqual(Set(map["sharp"]!), ["my-plugin", "other"])

        // 卸载 my-plugin：esbuild 成孤儿被移除，sharp 保留
        try AllowBuilds.cleanup(profileWorkspaceYaml: yaml, sidecarPath: sidecar, pluginKey: "my-plugin")
        map = AllowBuilds.loadSidecar(sidecar)
        XCTAssertNil(map["esbuild"])
        XCTAssertEqual(map["sharp"], ["other"])
        let yamlContent = try String(contentsOfFile: yaml, encoding: .utf8)
        XCTAssertFalse(yamlContent.contains("esbuild:"))
        XCTAssertTrue(yamlContent.contains("sharp: true"))
    }
}

final class CordisPatchTests: XCTestCase {
    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "/dsh-cordis-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: tmpDir)
    }

    func testProtectedPrefixes() {
        XCTAssertTrue(CordisPatch.isProtectedPlugin("cordis:core"))
        XCTAssertTrue(CordisPatch.isProtectedPlugin("@deepseek-ai/dsh-web-app"))
        XCTAssertTrue(CordisPatch.isProtectedPlugin("@deepseek-ai/dsh-web-anything"))
        XCTAssertFalse(CordisPatch.isProtectedPlugin("dshmarket"))
        XCTAssertFalse(CordisPatch.isProtectedPlugin("@deepseek-ai/other"))
        XCTAssertFalse(CordisPatch.isProtectedPlugin(""))
    }

    func testEmptyFileReadWrite() throws {
        let path = tmpDir + "/cordis.patch.yml"
        XCTAssertTrue(try CordisPatch.read(path: path).isEmpty)
        try CordisPatch.write(path: path, rows: [])
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "[]\n")
    }

    func testSetPluginDisabledFlow() throws {
        let path = tmpDir + "/cordis.patch.yml"
        let profileDir = tmpDir + "/profile"   // 无 node_modules → entry 兜底为包名

        // 禁用
        let (err1, ids1) = CordisPatch.setPluginDisabled(patchPath: path, profileDir: profileDir,
                                                         packageName: "dshmarket", disabled: true)
        XCTAssertNil(err1)
        XCTAssertEqual(ids1, ["dshmarket"])
        var rows = try CordisPatch.read(path: path)
        XCTAssertEqual(rows.first?["id"] as? String, "dshmarket")
        XCTAssertEqual(rows.first?["disabled"] as? Bool, true)

        // 启用：行内无其它字段 → 整行丢弃
        let (err2, _) = CordisPatch.setPluginDisabled(patchPath: path, profileDir: profileDir,
                                                      packageName: "dshmarket", disabled: false)
        XCTAssertNil(err2)
        rows = try CordisPatch.read(path: path)
        XCTAssertTrue(rows.isEmpty)

        // 带额外字段的行启用时保留并移除 disabled
        try CordisPatch.write(path: path, rows: [["id": "dshmarket", "name": "市场", "disabled": true, "config": ["a": 1]]])
        let (err3, _) = CordisPatch.setPluginDisabled(patchPath: path, profileDir: profileDir,
                                                      packageName: "dshmarket", disabled: false)
        XCTAssertNil(err3)
        rows = try CordisPatch.read(path: path)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["name"] as? String, "市场")
        XCTAssertNil(rows.first?["disabled"])
    }

    func testProtectedToggleRejected() {
        let path = tmpDir + "/cordis.patch.yml"
        let (err, _) = CordisPatch.setPluginDisabled(patchPath: path, profileDir: tmpDir,
                                                     packageName: "@deepseek-ai/dsh-base", disabled: true)
        XCTAssertNotNil(err)
        XCTAssertTrue(err!.contains("受到保护"))
    }

    func testRemovePluginEntries() throws {
        let path = tmpDir + "/cordis.patch.yml"
        try CordisPatch.write(path: path, rows: [
            ["id": "dshmarket", "disabled": true],
            ["id": "other", "name": "别的插件"],
        ])
        try CordisPatch.removePluginEntries(patchPath: path, packageName: "dshmarket", entryIDs: [])
        let rows = try CordisPatch.read(path: path)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["id"] as? String, "other")
    }
}

final class WorkspaceParseTests: XCTestCase {
    func testParseV2() {
        let json = """
        {
          "unit": { "name": "workspace", "version": 2 },
          "global": {
            "initialized": true,
            "workspaceIds": ["b", "a"],
            "archivedSessionIds": ["s3"]
          },
          "tables": {
            "workspaces": {
              "a": { "path": "/tmp/proj-a", "title": "项目A", "sessionIds": ["s1"],
                     "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-06-01T00:00:00.000Z" },
              "b": { "path": "/tmp/proj-b", "title": "", "sessionIds": ["s2", "s3"],
                     "createdAt": "2026-02-01T00:00:00.000Z", "updatedAt": "2026-07-01T00:00:00.000Z" },
              "c": { "path": "/tmp/proj-c", "title": "游离", "sessionIds": [],
                     "createdAt": "2026-03-01T00:00:00.000Z", "updatedAt": "2026-05-01T00:00:00.000Z" }
            }
          }
        }
        """
        let list = WorkspaceMonitor.parse(data: Data(json.utf8))
        XCTAssertEqual(list.count, 3)
        // 注册表顺序优先：b, a；游离记录 c 按 updatedAt 字符串倒序兜底
        XCTAssertEqual(list.map(\.id), ["b", "a", "c"])
        // 会话数过滤归档
        XCTAssertEqual(list[0].sessionCount, 1)
        XCTAssertEqual(list[1].sessionCount, 1)
        // 标题保留原始值（空串兜底 id 的逻辑在展示层，与飞牛一致）
        XCTAssertEqual(list[0].title, "")
        XCTAssertEqual(list[1].title, "项目A")
        XCTAssertEqual(list[1].path, "/tmp/proj-a")
    }

    func testRejectsWrongUnitAndFutureVersion() {
        let badName = """
        { "unit": { "name": "other", "version": 2 }, "global": {}, "tables": {} }
        """
        XCTAssertTrue(WorkspaceMonitor.parse(data: Data(badName.utf8)).isEmpty)
        let future = """
        { "unit": { "name": "workspace", "version": 3 }, "global": {}, "tables": {} }
        """
        XCTAssertTrue(WorkspaceMonitor.parse(data: Data(future.utf8)).isEmpty)
    }

    func testParseISO() {
        XCTAssertNotNil(WorkspaceMonitor.parseISO("2026-01-01T00:00:00.000Z"))
        XCTAssertNotNil(WorkspaceMonitor.parseISO("2026-01-01T00:00:00Z"))
        XCTAssertNil(WorkspaceMonitor.parseISO(""))
    }
}

final class ConfigStoreTests: XCTestCase {
    func testRoundtrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var config = LauncherConfig()
        config.serverPort = 3080
        config.sourcePath = "/some/path"
        config.networkProxy = "http://127.0.0.1:7890"
        config.autoRunOnLaunch = true
        let store = ConfigStore(url: url)
        try store.save(config)
        let loaded = store.load()
        XCTAssertEqual(loaded, config)
    }

    func testDefaults() {
        let store = ConfigStore(url: URL(fileURLWithPath: "/nonexistent/path/config.json"))
        let config = store.load()
        XCTAssertEqual(config.serverPort, 3080)
        XCTAssertEqual(config.dshHome, "")
        XCTAssertFalse(config.autoRunOnLaunch)
    }

    func testPortAvailable() {
        // 随机高位端口应当可用
        XCTAssertTrue(ConfigStore.isPortAvailable(39876))
    }
}
