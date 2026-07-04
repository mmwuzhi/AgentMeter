# AgentMeter

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md)

AgentMeter 是一个原生 macOS 菜单栏应用，可以快速查看 **Codex**、**Claude Code** 和 **GitHub Copilot** 的使用情况：剩余额度、电池条、重置时间、使用热力图、预估花费和菜单栏状态。它优先使用本机数据，复用你已经登录的 CLI，不需要配置 API key。

灵感来自 [bob-zebedy/CodexBar](https://github.com/bob-zebedy/CodexBar) 和 [steipete/codexbar](https://github.com/steipete/codexbar)，聚焦本机优先的 agent 使用量追踪。

## 功能

- **额度电池条**：按窗口显示剩余额度百分比和重置倒计时；只有当前速度会在重置前撞限额时才显示风险文案。
- **使用热力图**：每个 provider 一张 30 周 GitHub 风格热力图。
- **花费**：从本地日志和实时价格计算 7 天、全部时间的预估成本。
- **自定义菜单栏**：拖拽排序可见项目；低额度红/黄点会贴在触发它的具体窗口旁边。
- **通知**：关键额度提醒，以及可选的“关键窗口重置后恢复”提醒。
- **自动更新**：通过 Sparkle 支持，前提是你已经托管 appcast。见下文。
- 仅菜单栏运行，无 Dock 图标，每分钟自动刷新，也可以手动刷新。

## 数据来源（优先本地）

| | 实时额度 | 使用量和花费 |
|---|---|---|
| **Codex** | `codex app-server` JSON-RPC，然后回退到最新的 `~/.codex/sessions/**/rollout-*.jsonl`（`rate_limits`） | 汇总 rollout 日志里每天的 `last_token_usage` |
| **Claude** | OAuth：先读 `~/.claude/.credentials.json`，再读 macOS 钥匙串 `Claude Code-credentials`，然后请求 `GET api.anthropic.com/api/oauth/usage`，再回退到抓取 `claude /usage`，最后回退到仅使用量 | 扫描 `~/.claude/projects/**/*.jsonl`，按 `message.id` 去重后汇总 `message.usage.*` |
| **Copilot** | `gh api /copilot_internal/user`，复用已有 GitHub CLI 登录；如果缺少 `gh` 或未登录则不可用 | 固定费率，不显示 token 花费 |

价格来自 [LiteLLM](https://github.com/BerriAI/litellm)，并以 models.dev 作为回退；缓存位置是 `~/Library/Application Support/AgentMeter/pricing.json`，应用内还带有 `Resources/embedded-pricing.json` 离线快照。

> **Claude 额度需要网络。** 与 Codex 不同，Claude 不会把 5 小时或每周重置窗口写在本机。额度来源只能是 OAuth usage endpoint，或者抓取 CLI 输出。第一次 OAuth 读取可能弹出一次 macOS 钥匙串提示（“AgentMeter wants to use the keychain”），请选择 **Always Allow**。如果拒绝或离线，Claude 会降级到只显示使用量和花费，Codex 不受影响。

> **按花费计费的 Claude plan（比如 Enterprise）根本没有 5 小时/每周这种时间窗口**——
> 它们走的是组织级花费上限，不是按会话限流。AgentMeter 会显示账号上那笔一次性的
> 赠送额度（比如 Claude Code + Cowork 共用的 "Included credit"），如果没有其他能显示
> 的东西，就降级成"没有基于时间窗口的额度"提示 + 用量/花费。

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

### 签名与 Keychain 弹窗

`Scripts/bundle.sh` 有 `Apple Development` 证书时用它签名，没有则回退 ad-hoc（`-`，可用 `CODESIGN_IDENTITY` 覆盖）。AgentMeter 会读取 `Claude Code-credentials` 这个 Keychain 项，所以首次读取时 macOS 会弹出 Keychain 授权。用稳定证书签名时，「始终允许」跨重新构建有效；ad-hoc 每次重新构建都换新签名，弹窗会再次出现。（Claude Code 轮换 OAuth token 时也会重新触发弹窗，与签名无关。）这是 Keychain ACL，不是 TCC 权限，所以 `tccutil` 在这里不适用。发布仍然是 ad-hoc——没有付费的 Apple Developer Program 账户。

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

发布产物当前是 ad-hoc 签名。Sparkle appcast 生成仍然是单独步骤，需要在已有 Sparkle 私钥的机器上运行，或在 CI 中配置 `SPARKLE_PRIVATE_KEY` secret。

## 启用自动更新（Sparkle）

自动更新 feed 已配置为 GitHub Releases：
`https://github.com/mmwuzhi/AgentMeter/releases/latest/download/appcast.xml`。

发布对应 DMG 后生成 appcast：

```bash
version=0.4.2
make dmg
SPARKLE_VERSION="$version" \
SPARKLE_DOWNLOAD_URL_PREFIX="https://github.com/mmwuzhi/AgentMeter/releases/download/v$version/" \
make appcast
gh release upload "v$version" "dist/AgentMeter-$version.dmg" dist/appcast.xml --clobber
```

`Scripts/appcast.sh` 会优先使用 PATH 里的 Sparkle `generate_appcast`，否则使用 SwiftPM 已下载到 `.build/artifacts/sparkle/Sparkle/bin/` 的工具。设置 `SPARKLE_VERSION` 时，只会读取 `dist/AgentMeter-$SPARKLE_VERSION.dmg`，避免把本地旧 DMG 误写进 feed。

## 目录结构

```text
Sources/AgentMeter/
  App/            AgentMeterApp (@main), AppDelegate
  Controllers/    StatusItemController (NSStatusItem + popover)
  Models/         QuotaSnapshot, UsageBucket, ProviderState
  Services/       Codex/, Claude/, Copilot/, Pricing/, QuotaTrendTracker, RefreshCoordinator
  ViewModels/     AppViewModel (@Observable)
  Views/          Menu/ (battery bar, quota row, heatmap, spend), MenuBarContentView, SettingsView
Scripts/          Info.plist, bundle.sh, dmg.sh, appcast.sh
```
