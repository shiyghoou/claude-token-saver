# token-report

Claude Code のトランスクリプトから、トークン消費の傾向を安全に確認するためのスキル。
**まず `./scripts/token-report.sh` を使う。** 設定ファイルやフックを手で書き換えて
計測を有効化するものではなく、自動変更しない。

## 何をするか

- `scripts/measure-token-usage.py` を **read-only（読み取り専用）** で実行し、集計だけを Markdown にまとめる
- prompt、content、本文、環境変数、認証情報、repo 外の実パスをレポートへ写さない
- main session と subagent の usage を分けて示す
- 同じ `message.id` の usage は一度だけ数え、`message.id` が無い行は `requestId` と usage 内容で重複排除する

## まず使うコマンド

```bash
./scripts/token-report.sh
./scripts/token-report.sh --days 30
./scripts/token-report.sh --days 0 --all-projects
```

既定では、検証済みのレポートを `.token-saver/token-reports/` へ日時付きで保存する。
共有前提で別名保存したいときだけ `--out <path>` を明示する。

## 主なオプション

- `--days N` : 直近 N 日を対象にする。`0` は全期間
- `--all-projects` : 現在のリポジトリに対応する project key だけでなく、全プロジェクトを集計する
- `--paths` : Read したパスの要約も出す。repo 外や相対指定は `(repo外)` に伏せる
- `--top N` : 一覧の最大行数を絞る

launcher は `scripts/measure-token-usage.py` を呼び出し、既定では一時ファイルへ出したあと
`.token-saver/token-reports/` へ移動する。失敗時や空レポート時は成功扱いにしない。

## 読み方

- 「実測合計」は main session と subagent usage を別枠で見る
- 「モデルとサブエージェント」は `subagent_type` と `resolvedModel` の偏りを見る
- 「MCP」は設定済みサーバ名と実際の利用回数を並べて、未使用の候補を探す
- project key が見つからないときは、警告付きで全プロジェクトへフォールバックする

## 共有時の注意

- 含まれるのは集計値、モデル名、subagent_type、MCP サーバ名、repo 内の相対パスだけ
- prompt、content、本文、環境変数、認証情報は含めない
- それでも利用傾向や作業量は分かるので、公開先は自分で選ぶ

## 限界

- `cache_read_input_tokens` は課金上の重みが不明なので、内訳のまま表示し、加重しない
- 画像の消費は寸法からの概算であり、請求値そのものではない
- MCP サーバごとのトークン消費は実測できない。分かるのは設定済みか、呼ばれたか、何回かまで
- サブエージェント起動の固定コストは直接測定していない
- 既定値は条件付きの目安であり、モデル・MCP 構成・常駐指示・並列数を変えたら再計測が要る

## まだやらないこと

- Stop フックによる自動の切り時提案
- 実測にもとづく calibrate
- 計測結果を根拠にした設定ファイルの自動変更

必要なら README の token-report 節も合わせて読む。
