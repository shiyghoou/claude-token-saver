# Wave 5: token-report 計測エンジンの移植・一般化

- Issue: #13
- 親Issue: #2
- 状態: 承認済み
- 参照実装: [PAWARS `.claude/scripts`](https://github.com/PAWARS-co/PAWARS/tree/main/.claude/scripts)

## 背景

README と基本設計書では段階2の機能として `token-report` を予定しているが、
claude-token-saver 側には計測エンジンがまだ存在しない。PAWARS には、Claude Code の
JSONL トランスクリプトを集計し、重複計上と共有時の秘密情報混入を防ぐ実装および
fixture ベースの回帰テストがある。Wave 5 ではこの成果を、PAWARS 固有の Issue・
ブランチ・運用案内から切り離して移植する。

## 目標

1. 任意の導入先リポジトリから、Claude Code のトランスクリプトを読み取り専用で
   計測できるようにする。
2. メインセッションとサブエージェントの消費を二重計上せず、期間・モデル・スキル・
   ツールなどの観点で Markdown レポートを生成する。
3. レポートを共有しても、プロンプト、本文、ツール結果本文、認証情報、環境変数、
   コマンド引数などの非公開情報が出力されないことをテストで固定する。
4. `.token-saver/` を既存の管理領域として使い、日時付きレポートを上書きせず蓄積する。

## 非目標

- `suggest-session-cut` の閾値計算や Stop フック連携
- キャリブレーションと診断結果の自動適用
- `delegation-policy` の追加
- Claude Code の設定ファイルやトランスクリプトの書き換え
- PAWARS 固有の Issue、ブランチ、PR、レポート提出先の案内

## 採用方針

PAWARS の計測器を機械的に縮小するのではなく、計測・秘匿・重複排除・fixture の
中核を保持する。プロジェクト固有のパスと運用文だけを claude-token-saver の構成へ
置き換える。新機能をゼロから再設計する案は、既に実測で見つかった重複計上や秘密情報
混入の回帰を再発させるため採用しない。

## 構成

### 計測エンジン

`scripts/measure-token-usage.py` を追加する。次の CLI を提供する。

```text
python3 scripts/measure-token-usage.py
python3 scripts/measure-token-usage.py --days 30
python3 scripts/measure-token-usage.py --days 0 --all-projects
python3 scripts/measure-token-usage.py --out report.md --paths
```

- `--days N`: 直近 N 日。既定値は 7、`0` は全期間、負値は拒否する。
- `--out PATH`: Markdown の出力先。省略時は標準出力へ出す。
- `--top N`: 各表の最大行数。既定値は 15。正の整数だけを受け付ける。
- `--all-projects`: cwd に対応するプロジェクトだけでなく全プロジェクトを走査する。
- `--paths`: Read 回数の多いパスをレポートへ含める。リポジトリ外のパスは隠す。

データ源は `CLAUDE_CONFIG_DIR`（空なら `HOME/.claude`）配下の
`projects/<project-key>/*.jsonl` とする。cwd に対応するディレクトリは、Claude Code
のプロジェクトキー候補を複数生成して照合する。対応先が見つからず全件へフォール
バックする場合は、標準エラーとレポート本文の双方で path-safe な汎用警告を出し、
走査対象はディレクトリ名ではなく件数だけを示す。
`--all-projects` は全件走査を明示する経路とする。

### ランチャ

install は導入先の `.token-saver/token-report.sh` に managed entrypoint を設置する。
entrypoint は導入先 root を明示し、source clone の `scripts/token-report.sh` を呼ぶ。
source launcher は自身のディレクトリから `measure-token-usage.py` を解決し、計測・保存対象には
entrypoint が明示した target root を使う。source clone を移動した場合は install の再実行を要する。

出力先を省略した場合は
`.token-saver/token-reports/YYYYMMDD-HHMMSS.md` を選び、同名があれば連番を付ける。
原子的な配置で既存ファイルを上書きせず、同じ秒の並行実行も別名で保存する。
明示された `--out` の親ディレクトリは勝手に作らない。

ランチャは計測器へ期間・表の上限・全プロジェクト・パス表示の指定を渡すが、集計
ロジックを重複実装しない。レポートが非空で今回の実行により更新されたことを確認し、
計測器が成功扱いでも成果物が無ければ非0で終了する。

### スキル

`skills/token-report/SKILL.md` を追加し、保存先、実行例、レポートの読み方、次の
段階で扱う機能、既知の限界を説明する。計測結果に対する設定変更や Stop フックの
閾値変更をモデルが自動実行する指示は含めない。

`.token-saver/` は既存の `.gitignore` ブロックで除外済みなので、レポート用の追加
除外行は作らない。新しいスキルのリンクは既存の installer のスキル列挙・台帳記録に
従う。

## 集計契約

### メインセッション

- 走査対象は各プロジェクトディレクトリ直下の JSONL に限定する。
- `assistant` 行の `message.usage` から `input_tokens`、
  `cache_creation_input_tokens`、`cache_read_input_tokens`、`output_tokens` を集計する。
- 同じ `message.id` が content ブロックごとに複数行へ現れても一度だけ加算する。
- `message.id` が無い行は `requestId`、timestamp、usage 内訳から代替キーを作り、
  同一内容の重複を抑える。
- 重複排除は全走査ファイルをまたいで行う。

### サブエージェント

- `*/subagents/**/*.jsonl` はメインの usage 集計へ混ぜない。
- `toolUseResult` にある `agentType` と整数の `totalTokens` をサブエージェントの
  集計へ加える。
- `usage` が併記されている場合は内訳と `resolvedModel` を使い、無い場合は内訳欠落
  件数として報告する。
- サブエージェント詳細ログは MCP ツール接頭辞の走査など必要なメタデータ用途に
  限定し、本文・prompt・content はレポートへ出さない。

### 表示する指標

内訳、キャッシュ再送、出力、素の合計、セッション・モデル・スキル・ツール別の
集計、サブエージェントの利用状況、MCP サーバの検出と実利用の差分を出す。
cache_read の課金上の重みは確定値として扱わず、重み付け値を出す場合も比較用の
参考値と明記する。画像の消費は現在の計測エンジンでは未計測である。
常駐コンテキストの比率は概算または候補値と明示し、一般法則と断定しない。

## 秘密情報の境界

- JSONL の本文、thinking、prompt、tool result content は出力しない。
- settings や MCP 定義は、必要な名前・件数だけを読み、コマンド、環境変数値、
  認証情報は出力しない。
- hook はフルコマンドや引数を出さず、安全化した basename だけを出す。
- `--paths` のパスはリポジトリ内だけ原形を許し、外部・兄弟・相対パスは
  `(repo外)` として集計する。
- モデル名・skill名・サーバ名などの表示値は制御文字や Markdown を壊す記号を
  安全化し、不正値は表示しない。

## エラー処理と互換性

- プロジェクトディレクトリが無い場合は理由を標準エラーへ出し、非0で終了する。
- 不正な `--days`、出力先への書き込み失敗は非0で終了する。
- JSONL の壊れた行、未知の形、型違いの content はその行を無視し、トレースバックを
  出さずに残りを処理する。
- 実データ・設定は読み取り専用とし、テスト実行時もリポジトリへ `__pycache__` や
  `.pyc` を残さない。
- 実装は標準 Python ライブラリだけを使い、既存の Bash 3.2 対応範囲を壊さない。

## テスト方針

`test/test-token-report.sh` に合成 HOME、設定、JSONL、プラグイン fixture を作り、
実データへ依存せず次を検証する。

1. 同じ message.id と id 無し行の重複排除
2. 期間フィルタと `--days 0`
3. 親と subagents の二重計上防止
4. agentType・resolvedModel・usage の分類
5. MCP の設定検出、無効プラグイン除外、実利用との突き合わせ
6. repo外パス、hook引数、環境変数、本文、prompt、秘密値の非出力
7. CLAUDE_CONFIG_DIR、空白・長いパス、プロジェクトキー照合、明示的フォールバック
8. 壊れた JSONL と `content` 型違いへの耐性
9. 読み取り専用性と `.pyc` 残留なし
10. トランスクリプト不在、負の期間、出力失敗の終了コード

ランチャのテストでは、既定出力先、日時名、同名衝突、明示出力先、既存成果物の
誤認防止、Python 不在・計測失敗・空レポートを固定する。既存のテストランナーの
件数台帳も実測値へ更新する。

## 受け入れ条件

- 計測器、ランチャ、スキル、テスト、README、設計書が claude-token-saver のパスと
  運用に一致している。
- レポートの集計値が参照 fixture の期待値と一致し、二重計上がない。
- 共有してはいけない文字列がレポートに一件も現れない。
- `bash test/run.sh`、対象スクリプトの構文検査、`git diff --check` が成功する。
- 実装担当ではないサブエージェントの敵対的レビューで Critical/Important が残らない。
- ユーザーがマージできるPRを作成し、エージェント自身はマージしない。
