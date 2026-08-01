# Task 4 report

## 結果

- `skills/token-report/SKILL.md` を新規作成し、`./scripts/token-report.sh` を入口にした安全な read-only 計測手順を追加した
- `test/test-token-report-docs.sh` を新規作成し、SKILL / README / 設計書の導線一致と文言制約を固定した
- `README.md` の状態表を更新し、token-report の実行例、保存先、共有時の境界、重複排除とフォールバックの説明を追加した
- `docs/specs/2026-07-31-claude-token-saver-design.md` の §5.2 を、実際の CLI・保存先・集計契約・限界へ合わせて更新した
- `test/expected-min-count` を実測件数へ更新した

## RED

先に `test/test-token-report-docs.sh` を追加し、`bash test/run.sh token-report` で RED を確認した。

- `skills/token-report/SKILL.md` が未作成
- README の状態表が `token-report` を未実装として案内
- 設計書 §5.2 に `scripts/token-report.sh` / `.token-saver/token-reports/` / CLI 契約の記述が不足

## 変更内容

### 1. `skills/token-report/SKILL.md`

- launcher を入口にすることを明記
- `./scripts/token-report.sh`
- `./scripts/token-report.sh --days 30`
- `./scripts/token-report.sh --days 0 --all-projects`
- 既定保存先 `.token-saver/token-reports/`
- `--days` / `--all-projects` / `--paths` / `--top` / `--out`
- read-only、共有時の境界、重複排除、subagent 別枠、project key 不一致時のフォールバック
- `cache_read_input_tokens`、画像、MCP、固定コストの限界
- Stop フック / calibrate / 自動設定変更は未実装

### 2. `README.md`

- 状態表の `計測（token-report）` を **実装済み** に変更
- token-report 節を追加し、CLI 実行例・保存先・共有時の境界・補足を追加
- 既存の段階3〜5は未実装のまま維持

### 3. 設計書 §5.2

- engine を `scripts/measure-token-usage.py`、入口を `scripts/token-report.sh` と明記
- `.token-saver/token-reports/` への既定保存を明記
- `## 計測条件` を持つ非空レポートのみ保存する launcher 契約を明記
- 含める情報 / 含めない情報 / 重複排除 / subagent 別枠 / project key フォールバックを明記
- `cache_read_input_tokens` / 画像 / MCP の限界を実装と一致させた

## 検証

- `bash -n test/test-token-report-docs.sh`
- `bash test/test-token-report-docs.sh`
- `bash test/run.sh token-report`
- `git diff --check`
- `bash test/run.sh`

結果:

- focused docs test: 緑
- token-report focused suite: 29 件成功 / 0 失敗 / 0 スキップ
- full suite: 368 件成功 / 0 失敗 / 0 スキップ

## セルフレビュー

- `token-report` の `未実装` 表記が README 状態表に残っていないことを確認
- 新規文書に PAWARS / Issue / 提出先の漏れが無いことを確認
- launcher を使わず設定やフックを手で変更させる文言が SKILL に無いことを確認
- README の `skills/token-report/SKILL.md` リンクが存在することを確認

## コミット予定

- `docs: token-reportの利用方法と限界を追加する`

## 備考

- 指定レポート先 `.superpowers/sdd/2026-08-02-wave5-token-report/` は **2026-08-02** を含む未来日付のディレクトリ名だが、
  現在日 **Saturday, August 1, 2026** に対するユーザー指定パスとしてそのまま使用した

## Fix report

### 対応したレビュー指摘

- Important: `test/test-token-report-docs.sh` を shared contract 方式へ強化し、README / `skills/token-report/SKILL.md` / 設計書 §5.2 の3文書へ同じ契約を反復適用するように変更した
- Minor: README の token-report 節へ `--top` と `--paths` を含む CLI 案内を追加した

### 変更内容

- `test/test-token-report-docs.sh`
  - 3文書を列挙する `_doc_paths`
  - 共有契約を1文書ずつ検査する `_assert_shared_contract`
  - `./scripts/token-report.sh`
  - `.token-saver/token-reports/`
  - `--days` / `--out` / `--top` / `--all-projects` / `--paths`
  - `cache_read_input_tokens`
  - 画像の限界
  - MCP の限界
  - 読み取り専用
  - 自動変更しない
  - Stop フック / calibrate 未実装
  を README / SKILL / 設計書 §5.2 の全てへ同じ条件で適用するようにした
- `README.md`
  - token-report 節へ `--out` / `--top` / `--all-projects` / `--paths` を追加
  - 「読み取り専用」「自動変更しない」「cache_read_input_tokens」「画像」「MCP」「Stop フック」「calibrate」を token-report 節に追記
- `skills/token-report/SKILL.md`
  - `read-only（読み取り専用）`
  - `自動変更しない`
  の文言を shared contract に合わせて明示した
- `docs/specs/2026-07-31-claude-token-saver-design.md`
  - §5.2 に「読み取り専用」「自動変更しない」「Stop フック / calibrate は後続節の範囲」を追記した
- `test/expected-min-count`
  - 実測件数を確認した結果、総 349 / `test-token-report-docs.sh` 5 件で変化が無かったため更新不要

### RED

shared contract テスト追加後の失敗確認:

- `bash test/run.sh token-report-docs`
  - 1回目: テスト実装がランナー規約に抵触し、`(失敗が飲まれる位置でアサーションを呼んでいる)` で失敗
  - 2回目: `README.md topに [--top] が含まれない` で失敗

### 検証コマンドと結果

```text
$ bash -n test/test-token-report-docs.sh
  -> exit 0

$ bash test/test-token-report-docs.sh
  -> exit 0

$ bash test/run.sh token-report
  -> 成功 29 件 / 失敗 0 件 / スキップ 0 件

$ git diff --check
  -> exit 0

$ bash test/run.sh
  -> 実行件数の下限: 総 349 件 / ファイル別 9 件分
  -> 成功 368 件 / 失敗 0 件 / スキップ 0 件
```
