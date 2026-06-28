# AgentMeter

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md)

AgentMeterは、**Codex**と**Claude Code**の利用状況をすばやく確認できるネイティブmacOSメニューバーアプリです。残りクォータ、バッテリーバー、利用ヒートマップ、推定コストを表示します。ローカル優先で動作し、すでにログイン済みのCLIを再利用するため、API keyの設定は不要です。

[bob-zebedy/CodexBar](https://github.com/bob-zebedy/CodexBar)と[steipete/codexbar](https://github.com/steipete/codexbar)に着想を得ていますが、このワークスペースで実際に使う2つのagentに絞っています。

## 機能

- **クォータのバッテリーバー**：各ウィンドウの残量パーセントとリセットまでの時間を表示します。
- **利用ヒートマップ**：providerごとに30週間分のGitHub風ヒートマップを表示します。
- **コスト**：ローカルログと最新の価格情報から、直近 7 日間と全期間の推定コストを計算します。
- **自動更新**：Sparkleに対応しています。appcastをホストすると有効になります。詳しくは下記を参照してください。
- メニューバー専用で、Dockアイコンはありません。1分ごとの自動更新と手動更新に対応しています。

## データの取得元（ローカル優先）

| | ライブクォータ | 利用量とコスト |
|---|---|---|
| **Codex** | `codex app-server` JSON-RPC、その後に最新の `~/.codex/sessions/**/rollout-*.jsonl`（`rate_limits`）へフォールバック | rolloutログの `last_token_usage` を日別に集計 |
| **Claude** | OAuth：`~/.claude/.credentials.json`、macOS Keychainの `Claude Code-credentials`、`GET api.anthropic.com/api/oauth/usage` の順に使い、その後 `claude /usage` のスクレイピング、最後に利用量のみへフォールバック | `~/.claude/projects/**/*.jsonl` を読み、`message.id` で重複排除して `message.usage.*` を集計 |

価格情報は[LiteLLM](https://github.com/BerriAI/litellm)から取得し、models.devをフォールバックとして使います。キャッシュは `~/Library/Application Support/AgentMeter/pricing.json` に保存され、アプリには `Resources/embedded-pricing.json` のオフラインスナップショットも含まれています。

> **Claudeのクォータ取得にはネットワークが必要です。** Codexと違い、Claudeは5時間または週間のリセットウィンドウをローカルに保存しません。取得元はOAuth usage endpoint、またはCLI出力のスクレイピングです。初回のOAuth読み取りでは、macOS Keychainの確認（"AgentMeter wants to use the keychain"）が表示されることがあります。その場合は**Always Allow**を選んでください。拒否した場合やオフラインの場合、Claudeは利用量とコストのみの表示に切り替わり、Codexには影響しません。

## ビルドと実行

Xcode toolchain（Xcode 16+ / Swift 6）が必要です。

```bash
make run          # release ビルド、dist/AgentMeter.app の組み立て、起動
make debug        # データ層を素早くターミナルでビルドして実行
make app          # dist/AgentMeter.app だけを組み立て
make dmg          # dist/AgentMeter-<version>.dmg を作成
make clean
```

アプリは現在ad-hoc署名で、ローカルで実行できます。別のMacに移す場合はquarantineを解除してください。

```bash
xattr -dr com.apple.quarantine /Applications/AgentMeter.app
```

## インストール

[GitHub Releases](https://github.com/mmwuzhi/AgentMeter/releases/latest)から最新の `AgentMeter-<version>.dmg` をダウンロードし、DMGを開いて `AgentMeter.app` を `/Applications` にドラッグします。

現在のリリースはad-hoc署名でnotarizeされていないため、初回起動時にmacOSがブロックすることがあります。その場合は `AgentMeter.app` を右クリックし、**Open**を選んで確認してください。それでもquarantineが残る場合は、次を実行します。

```bash
xattr -dr com.apple.quarantine /Applications/AgentMeter.app
```

## GitHub Releases

GitHub ActionsでDMGを自動ビルドして公開できます。バージョンtagをpushします。

```bash
git tag v1.2.3
git push origin v1.2.3
```

または、GitHub Actionsから**Release** workflowを手動実行し、`1.2.3` を入力します。workflowは `MARKETING_VERSION` をtagまたは入力されたバージョンに設定し、app bundleとDMGを検証し、workflow artifactをアップロードし、DMGと `SHA256SUMS` を含むGitHub Releaseを作成または更新します。

リリース成果物は現在ad-hoc署名です。Sparkle appcastの生成はSparkleの秘密鍵が必要なため、別手順のままです。

## 自動更新を有効にする（Sparkle）

自動更新のコードは組み込まれていますが、feedを設定するまでは有効になりません。

1. [Sparkle releases page](https://github.com/sparkle-project/Sparkle/releases)からSparkleのツールをダウンロードします。
2. `./bin/generate_keys` を1回実行します。出力された**public** keyを `Scripts/Info.plist` の `SUPublicEDKey` に設定します。
3. `Scripts/Info.plist` の `SUFeedURL` に、`appcast.xml` をホストするURLを設定します。GitHub Releases raw URLや自分のドメインなどが使えます。
4. `make dmg && make appcast` を実行します（`generate_appcast` がPATHに必要です）。`dist/appcast.xml` が生成されます。DMGと `appcast.xml` をfeed hostにアップロードしてください。

設定が終わるまでは、**Check for Updates**は短い説明を表示し、クラッシュしません。

## レイアウト

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
