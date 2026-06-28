# AgentMeter

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md)

AgentMeter 是一个原生 macOS 菜单栏应用，可以快速查看 **Codex** 和 **Claude Code** 的使用情况：剩余额度、电池条、使用热力图和预估花费。它优先使用本机数据，复用你已经登录的 CLI，不需要配置 API key。

灵感来自 [bob-zebedy/CodexBar](https://github.com/bob-zebedy/CodexBar) 和 [steipete/codexbar](https://github.com/steipete/codexbar)，但只保留这个工作区实际使用的两个 agent。

## 功能

- **额度电池条**：按窗口显示剩余额度百分比和重置倒计时。
- **使用热力图**：每个 provider 一张 30 周 GitHub 风格热力图。
- **花费**：从本地日志和实时价格计算 7 天、全部时间的预估成本。
- **自动更新**：通过 Sparkle 支持，前提是你已经托管 appcast。见下文。
- 仅菜单栏运行，无 Dock 图标，每分钟自动刷新，也可以手动刷新。

## 数据来源（优先本地）

| | 实时额度 | 使用量和花费 |
|---|---|---|
| **Codex** | `codex app-server` JSON-RPC，然后回退到最新的 `~/.codex/sessions/**/rollout-*.jsonl`（`rate_limits`） | 汇总 rollout 日志里每天的 `last_token_usage` |
| **Claude** | OAuth：先读 `~/.claude/.credentials.json`，再读 macOS 钥匙串 `Claude Code-credentials`，然后请求 `GET api.anthropic.com/api/oauth/usage`，再回退到抓取 `claude /usage`，最后回退到仅使用量 | 扫描 `~/.claude/projects/**/*.jsonl`，按 `message.id` 去重后汇总 `message.usage.*` |

价格来自 [LiteLLM](https://github.com/BerriAI/litellm)，并以 models.dev 作为回退；缓存位置是 `~/Library/Application Support/AgentMeter/pricing.json`，应用内还带有 `Resources/embedded-pricing.json` 离线快照。

> **Claude 额度需要网络。** 与 Codex 不同，Claude 不会把 5 小时或每周重置窗口写在本机。额度来源只能是 OAuth usage endpoint，或者抓取 CLI 输出。第一次 OAuth 读取可能弹出一次 macOS 钥匙串提示（“AgentMeter wants to use the keychain”），请选择 **Always Allow**。如果拒绝或离线，Claude 会降级到只显示使用量和花费，Codex 不受影响。

## 构建和运行

需要 Xcode toolchain（Xcode 16+ / Swift 6）。

```bash
make run          # release 构建，组装 dist/AgentMeter.app，然后启动
make debug        # 快速终端构建并运行数据层
make app          # 只组装 dist/AgentMeter.app
make dmg          # 打包 dist/AgentMeter-<version>.dmg
make clean
```

应用当前是 ad-hoc 签名，可以在本机运行。如果移动到另一台 Mac，清除 quarantine：

```bash
xattr -dr com.apple.quarantine /Applications/AgentMeter.app
```

## 安装

从 [GitHub Releases](https://github.com/mmwuzhi/AgentMeter/releases/latest) 下载最新的 `AgentMeter-<version>.dmg`，打开 DMG，把 `AgentMeter.app` 拖到 `/Applications`。

因为当前版本是 ad-hoc 签名且没有 notarize，macOS 第一次启动时可能会拦截。如果遇到这种情况，右键点击 `AgentMeter.app`，选择 **Open**，然后确认。如果 macOS 仍保留 quarantine，运行：

```bash
xattr -dr com.apple.quarantine /Applications/AgentMeter.app
```

## GitHub Releases

GitHub Actions 可以自动构建并发布 DMG。推送版本 tag：

```bash
git tag v1.2.3
git push origin v1.2.3
```

也可以在 GitHub Actions 手动运行 **Release** workflow，并输入 `1.2.3`。workflow 会把 `MARKETING_VERSION` 设为 tag 或输入的版本号，校验 app bundle 和 DMG，上传 workflow artifact，并创建或更新带有 DMG 和 `SHA256SUMS` 的 GitHub Release。

发布产物当前是 ad-hoc 签名。Sparkle appcast 生成仍然是单独步骤，因为它需要你的 Sparkle 私钥。

## 启用自动更新（Sparkle）

自动更新代码已经接好，但在配置 feed 之前不会生效：

1. 从 [Sparkle releases page](https://github.com/sparkle-project/Sparkle/releases) 下载 Sparkle 工具。
2. 运行一次 `./bin/generate_keys`。把输出的 **public** key 填到 `Scripts/Info.plist` 的 `SUPublicEDKey`。
3. 把 `Scripts/Info.plist` 的 `SUFeedURL` 设为你托管 `appcast.xml` 的地址，例如 GitHub Releases raw URL 或自己的域名。
4. `make dmg && make appcast`（需要 `generate_appcast` 在 PATH 中）会生成 `dist/appcast.xml`。上传 DMG 和 `appcast.xml` 到你的 feed host。

配置完成前，**Check for Updates** 会显示一段说明，而不是崩溃。

## 目录结构

```text
Sources/AgentMeter/
  App/            AgentMeterApp (@main), AppDelegate
  Controllers/    StatusItemController (NSStatusItem + popover)
  Models/         QuotaSnapshot, UsageBucket, ProviderState
  Services/       Codex/, Claude/, Pricing/, RefreshCoordinator, LoginItem, UpdaterController
  ViewModels/     AppViewModel (@Observable)
  Views/          Menu/ (battery bar, quota row, heatmap, spend), SettingsView
Scripts/          Info.plist, bundle.sh, dmg.sh, appcast.sh
```
