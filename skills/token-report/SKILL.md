---
name: token-report
description: Use when measuring Claude Code token usage safely in a repository after installing claude-token-saver.
---

# token-report

Claude Code のトランスクリプトから、トークン消費の傾向を安全に確認するためのスキル。
**まず導入先で `./.token-saver/token-report.sh` を使う。** 設定ファイルやフックを手で書き換えて
計測を有効化するものではない。通常の report は設定ファイルとフックを自動変更しない。

## 何をするか

- `scripts/measure-token-usage.py` を **read-only（読み取り専用）** で実行し、集計だけを Markdown にまとめる
- prompt、content、本文、環境変数、認証情報、repo 外の実パスをレポートへ写さない
- main session と subagent の usage を分けて示す
- 同じ `message.id` の usage は一度だけ数え、`message.id` が無い行は `requestId` と usage 内容で重複排除する

## まず使うコマンド

```bash
./.token-saver/token-report.sh
./.token-saver/token-report.sh --days 30
./.token-saver/token-report.sh --days 0 --all-projects
./.token-saver/token-report.sh --calibrate
./.token-saver/token-calibrate.sh --apply
```

既定では、検証済みのレポートを `.token-saver/token-reports/` へ日時付きで保存する。
共有前提で別名保存したいときだけ `--out <path>` を明示する。
`--calibrate` は計測値と診断を snapshot に保存するが、`.claude/token-saver.json` の閾値は変更しない。
snapshot を確認したあと、利用者が `token-calibrate.sh --apply` を明示的に実行した場合だけ設定を更新する。

## 主なオプション

- `--days N` : 直近 N 日を対象にする。`0` は全期間
- `--all-projects` : 現在のリポジトリに対応する project key だけでなく、全プロジェクトを集計する
- `--paths` : Read したパスの要約も出す。repo 外や相対指定は `(repo外)` に伏せる
- `--top N` : 一覧の最大行数を絞る
- `--calibrate` : セッション中央値、診断、適用用 snapshot を作る。設定は変更しない

導入先の entrypoint は、install 元クローンの `scripts/token-report.sh` を呼び出す。
source clone 側の launcher は同じクローンの `scripts/measure-token-usage.py` を engine として使い、
計測対象 root と既定の保存先は entrypoint がある導入先に固定する。したがって、別の cwd から
entrypoint を呼んでも source clone へレポートを書かない。source clone を移動した場合は、導入先で
`install.sh` を再実行して entrypoint の記録を更新する。

既定では一時ファイルへ出したあと `.token-saver/token-reports/` へ原子的に配置する。
同じ秒の同時実行でも既存レポートを上書きせず、失敗時や空レポート時は成功扱いにしない。

## 読み方

- 「実測合計」は main session と subagent `message.usage` を別枠で見る
- サブエージェント節のカバレッジ（起動数 / ログ本数 / 欠測注意）と起動固定コスト（中央値・最小・最大・標本数）を読む
- 「モデルとサブエージェント」は join 済み `subagent_type`（および `(不明)` / `(既定)`）ごとの起動・ログ・usage を見る
- 「MCP」は設定済みサーバ名と実際の利用回数を並べて、未使用の候補を探す
- project key が見つからないときは、警告付きで全プロジェクトへフォールバックする

### オートモード補助エージェント

オートモード補助エージェントは main / subagent と別枠で表示する。Claude Code は
`classifierMetaLines` を持つ permission classifier の呼出件数だけを数える。usage はログに無いため
**N/A** とし、推計しない。Codex 全体の使用量は対象外であり、`CODEX_HOME/sessions` の `source` が
`guardian`、現在の model が `codex-auto-review` であるイベントの
`token_count.info.last_token_usage` だけを実測する。`cached input` と `reasoning output` は内数で、
合計へ二重加算しない。欠測・型不正・整合性不一致は件数化し、推計しない。本文・session id・実パスは出力しない。
この別枠は `calibration` の snapshot、fingerprint、recommendation、apply 入力に含めない。

## 共有時の注意

- 含まれるのは集計値、モデル名、subagent_type、MCP サーバ名、repo 内の相対パスだけ
- prompt、content、本文、環境変数、認証情報は含めない
- それでも利用傾向や作業量は分かるので、公開先は自分で選ぶ

## 限界

- サブエージェント消費の主合計は `subagents/*.jsonl` の `message.usage` のみである（親 JSONL の結果回収トークン合計は使わない）
- 起動固定コストは各サブログの初回 assistant 入力から実測するが、usage 合計へ二重加算しない
- 期間内のサブエージェント集合は完全母集団ではない。欠測分は平均値で補完しない
- `cache_read_input_tokens` は課金上の重みが不明なので、内訳のまま表示し、加重しない
- 画像の消費は現在の計測エンジンでは未計測である
- MCP サーバごとのトークン消費は実測できない。分かるのは設定済みか、呼ばれたか、何回かまで
- 既定値は条件付きの目安であり、モデル・MCP 構成・常駐指示・並列数を変えたら再計測が要る

## キャリブレーションと診断

サンプル条件は既定でセッション5本以上かつ assistant ターン100以上である。
導入先の `.claude/token-saver.json` の `calibration.min_sessions` / `calibration.min_assistant_turns` で変更できる。
条件を満たすと、次のコマンドがセッション単位の `cache_read` 中央値を根拠に snapshot と診断を作る。

```bash
./.token-saver/token-report.sh --calibrate
```

snapshot は `.token-saver/calibration/latest.json` に原子的に保存され、算出元、生成日時、サンプル数、
fingerprint、現在の閾値を含む。通常 report と Stop フックの案内 state も共有し、同じサンプル周期を二重に促さない。

レポートは `## 実測診断` と `## 概算診断` を分ける。実測には超過セッション、重い main tool_result、MCP の未使用 / 利用済み / 判定不能、
Agent 利用、`/compact`、画像未計測を含め、概算には MCP 定義 bytes ÷ 4 だけを置く。概算値は実測合計・中央値・未使用判定へ加算しない。
画像の消費は現在の計測エンジンでは未計測である。prompt、tool-result 本文、環境変数、認証情報、repo 外の実パスも出力しない。

適用は自動ではない。snapshot の内容を確認してから、次の明示コマンドを実行する。

```bash
./.token-saver/token-calibrate.sh --apply
```

このコマンドだけが `.claude/token-saver.json` の `suggest_session_cut.initial_cache_read`、
`suggest_session_cut.increment_cache_read`、`calibration.last_applied` を更新する。
他のキーは保持され、snapshot と現在設定の条件が一致しない場合は適用しない。

## まだやらないこと

- 計測結果だけを根拠にした設定ファイルの自動変更（明示的な `--apply` は必要）
- 画像のトークン消費の数値推定

必要なら README の token-report 節も合わせて読む。
