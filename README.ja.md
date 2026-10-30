# AgentMeter

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md)

AgentMeterは、**Codex**、**Claude Code**、**GitHub Copilot**の利用状況をすばやく確認できるネイティブmacOSメニューバーアプリです。残りクォータ、バッテリーバー、リセット時刻、利用ヒートマップ、推定コスト、メニューバー状態を表示します。ローカル優先で動作し、すでにログイン済みのCLIを再利用するため、API keyの設定は不要です。

[bob-zebedy/CodexBar](https://github.com/bob-zebedy/CodexBar)と[steipete/codexbar](https://github.com/steipete/codexbar)に着想を得て、ローカル優先のagent利用状況トラッキングに集中しています。

## 機能

- **クォータバー**：各ウィンドウのパーセントとリセットまでの時間を表示します。既定は残量（バッテリー式）ですが、設定で使用量に切り替えられ、ポップオーバーとメニューバーが一緒に反転します。常時表示のペース（`now · avg · budget`）は、今この瞬間の消費速度（`now`）と直近の平均（`avg`）を並べて示すので、バーストへの反応と「このペースであとどれくらい持つか」を同じ行で読み取れます。ウィンドウがまだ1ポイントも動いていない間、`now` は `<x%/h` と表示されます。使用量は整数パーセントで届くため、これはゼロではなく上限値です。平均ペースのままリセット前に上限へ到達する見込みのときは、枯渇までの推定時間を別の行に表示します。ただしその時刻が補充サイクル2回分より先の場合は表示しません。同じペースでそれだけのリセットを通過する前提の推定は、今すぐ手を打てる情報にならないためです。
- **利用ヒートマップ**：providerごとに24週間分のGitHub風ヒートマップを表示します。
- **コスト**：ローカルログと最新の価格情報から、ローカル日、直近7日間、直近30日間の推定コストを計算します。
- **カスタムメニューバー**：表示する項目をドラッグで並べ替えられます。各クォータウィンドウはテキスト%のほか、ミニクォータバーとしても表示できます。低クォータの赤/黄ドットは、原因になった具体的なウィンドウの横に表示されます。
- **通知**：クリティカルなクォータ通知と、クリティカルだったウィンドウがリセット後に回復したときの任意通知に対応します。
- **自動更新**：Sparkleに対応しています。appcastをホストすると有効になります。詳しくは下記を参照してください。
- メニューバー専用で、Dockアイコンはありません。1分ごとの自動更新と手動更新に対応しています。

## データの取得元（ローカル優先）

| | ライブクォータ | 利用量とコスト |
|---|---|---|
| **Codex** | `codex app-server` JSON-RPC、その後に最新の `~/.codex/sessions/**/rollout-*.jsonl`（`rate_limits`）へフォールバック | rolloutログの `last_token_usage` を日別に集計 |
| **Claude** | OAuth：`~/.claude/.credentials.json`、macOS Keychainの `Claude Code-credentials`、`GET api.anthropic.com/api/oauth/usage` の順に使い、その後 `claude /usage` のスクレイピング、最後に利用量のみへフォールバック | `~/.claude/projects/**/*.jsonl` を読み、`message.id|requestId` ごとに1レコード（最終レコードがあればそれ）を選んで `message.usage.*` を集計 |
| **Copilot** | `gh api /copilot_internal/user`。既存のGitHub CLIログインを再利用します。`gh` がない、または未認証の場合は利用できません | 定額制のため、tokenコストは表示しません |

価格情報は[LiteLLM](https://github.com/BerriAI/litellm)から取得し、models.devをフォールバックとして使います。キャッシュは `~/Library/Application Support/AgentMeter/pricing.json` に保存され、アプリには `Resources/embedded-pricing.json` のオフラインスナップショットも含まれています。

> **Claudeのクォータ取得にはネットワークが必要です。** Codexと違い、Claudeは5時間または週間のリセットウィンドウをローカルに保存しません。取得元はOAuth usage endpoint、またはCLI出力のスクレイピングです。AgentMeterはClaude Code自身と同じくmacOSの `security` ツールでKeychainを読むため、AgentMeter自身の署名によって確認が出るかどうかは変わりません。読み取りに失敗した場合やオフラインの場合、Claudeは利用量とコストのみの表示に切り替わり、Codexには影響しません。

> **Enterprise など消費額ベースのClaudeプランには5時間/週間ウィンドウ自体がありません。**
> セッション単位のレート制限ではなく、組織単位の支出上限で課金されるためです。
> AgentMeterはそのアカウントが持つ一回限りの付与クレジット（Claude Code + Cowork 用の
> "Included credit" など）を表示し、他に表示できるものがない場合は「セッション単位の
> クォータウィンドウなし」という注記と利用量・コストのみにフォールバックします。

## ビルドと実行

Xcode toolchain（Xcode 16+ / Swift 6）が必要です。

```bash
make run          # release ビルド、dist/AgentMeter.app の組み立て、起動
make debug        # データ層を素早くターミナルでビルドして実行
make app          # dist/AgentMeter.app だけを組み立て
make dmg          # dist/AgentMeter-<version>.dmg を作成
make clean
```

ローカルビルドは自分の証明書で署名され（なければad-hoc）、notarizeされていません。別のMacでは初回起動がブロックされるため、下の「インストール」の手順で開いてください。

### 署名とKeychainプロンプト

`Scripts/bundle.sh` は `Developer ID Application` 証明書、なければ `Apple Development` 証明書で署名し、どちらもなければad-hoc（`-`、`CODESIGN_IDENTITY` で上書き可）にフォールバックします。実際の証明書ではhardened runtimeも有効になります。AgentMeterは `Claude Code-credentials` のKeychain項目を `/usr/bin/security` で読みます。Claude Codeがこの項目を書き込むのも同じツールで、項目はすでにこのツールを信頼しているため、再ビルドやad-hoc署名は関係ありません。以前のビルドのようにアプリ自身が項目を読むと、署名に関係なく、Claude CodeがOAuthトークンをローテーションするたびにプロンプトが再び出ていました。読み取り中にmacOSが確認を求め（キーチェーンがロックされているときなど）、それがキャンセルまたは拒否された場合、AgentMeterは5分待ってから再試行します。このツールがないシステムでは、以前と同じくアプリ自身が項目を読みます。これはKeychainのACLであり、TCC権限ではないため、`tccutil` は適用されません。リリースはad-hocのままです——有料のApple Developer Programアカウントがないためです。

## インストール

[GitHub Releases](https://github.com/mmwuzhi/AgentMeter/releases/latest)から最新の `AgentMeter-<version>.dmg` をダウンロードし、DMGを開いて `AgentMeter.app` を `/Applications` にドラッグします。

現在のリリースはad-hoc署名でnotarizeされていないため、初回起動時にmacOSがブロックします。一度アプリを開いてから、**システム設定 › プライバシーとセキュリティ**で**このまま開く**（Open Anyway）をクリックしてください（macOS 15以降では右クリックの**開く**は使えません）。notarizeされていないビルドはAppleの確認を受けていないので、入手元を信頼できる場合にだけ開いてください。

## GitHub Releases

GitHub ActionsでDMGを自動ビルドして公開できます。バージョンtagをpushします。

```bash
git tag v1.2.3
git push origin v1.2.3
```

または、GitHub Actionsから**Release** workflowを手動実行し、`1.2.3` を入力します。バージョンは `VERSION` ファイルから取り、tagまたは入力値はそれと一致する必要があります。ビルド番号はAsia/Tokyoの時刻です（`Scripts/build-number.sh`）。workflowはapp bundleとDMGを検証し、workflow artifactをアップロードし、DMGと `SHA256SUMS` を含むGitHub Releaseを作成または更新します。

リリース成果物は現在ad-hoc署名です。Sparkle appcastの生成はSparkleの秘密鍵があるマシンで実行するか、CIで `SPARKLE_PRIVATE_KEY` secretを設定して実行します。

## 自動更新を有効にする（Sparkle）

自動更新feedはGitHub Releasesに設定されています：
`https://github.com/mmwuzhi/AgentMeter/releases/latest/download/appcast.xml`。

対応するDMGをビルドしたあと、appcastを生成します：

```bash
version=0.4.2
make dmg
SPARKLE_VERSION="$version" \
SPARKLE_DOWNLOAD_URL_PREFIX="https://github.com/mmwuzhi/AgentMeter/releases/download/v$version/" \
make appcast
gh release upload "v$version" "dist/AgentMeter-$version.dmg" dist/appcast.xml --clobber
```

`Scripts/appcast.sh` はPATH上のSparkle `generate_appcast` を使い、なければSwiftPMが `.build/artifacts/sparkle/Sparkle/bin/` にダウンロードしたツールを使います。`SPARKLE_VERSION` を設定すると `dist/AgentMeter-$SPARKLE_VERSION.dmg` だけを読み込むため、古いローカルDMGをfeedに混ぜる事故を避けられます。

## レイアウト

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
