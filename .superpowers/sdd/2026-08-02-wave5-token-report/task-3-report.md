# Task 3 report

## 結果

- `scripts/token-report.sh` を追加し、`measure-token-usage.py` の薄い Bash launcher を実装した。
- `test/test-token-report-launcher.sh` を追加し、launcher 専用 fixture で 8 ケースの契約を固定した。
- `test/expected-min-count` を更新し、launcher テスト 8 件と総件数 342 件へ追随した。

## TDD

### RED

実装前に次を実行した。

```bash
bash test/run.sh token-report-launcher
```

- 終了コード: `1`
- 結果: 成功 0 件 / 失敗 8 件 / スキップ 0 件
- 主因: `scripts/token-report.sh` 不在により fixture が launcher を配置できず、全ケースが期待どおり RED になった。

### GREEN

実装後に同じ runner を再実行した。

```bash
bash test/run.sh token-report-launcher
```

- 終了コード: `0`
- 結果: 成功 8 件 / 失敗 0 件 / スキップ 0 件

## 実装概要

### launcher

- `BASH_SOURCE[0]` から `SCRIPT_DIR` と repo root を解決する。
- `scripts/lib/paths.sh` を source し、既定出力先を `$(cts_base_rel)/token-reports` から組み立てる。
- `--out` / `--out=...` の明示有無をフラグで検出し、明示時は親ディレクトリを自動作成しない。
- 既定出力時のみ `mkdir -p` を行い、`YYYYMMDD-HHMMSS.md` を基準に `-2`, `-3`, ... と衝突回避する。
- `python3 -B scripts/measure-token-usage.py "$@"` を呼び、非ゼロ終了コードをそのまま返す。
- 成功時でも、出力ファイルの存在・非空・marker より新しいこと・先頭 40 行に `## 計測条件` があることを検証し、失敗理由を stderr へ出す。

### launcher fixture test

- 実 repo の `.token-saver` を使わず、`$TEST_TMP` 配下の fixture repo に launcher をコピーして実行する。
- fixture 側に `scripts/lib/paths.sh` と `measure-token-usage.py` wrapper を置き、engine 本体は変更しない。
- `date` スタブで時刻を `20260801-123456` に固定し、衝突ケースを再現する。
- `python3` 不在ケースは PATH を fixture wrapper 群だけへ閉じ込めて検証する。

## 検証

```bash
bash test/run.sh token-report-launcher
```

- 成功 8 件 / 失敗 0 件 / スキップ 0 件

```bash
bash test/run.sh token-report
```

- 成功 22 件 / 失敗 0 件 / スキップ 0 件

```bash
bash -n scripts/token-report.sh
bash -n test/test-token-report-launcher.sh
git diff --check
```

- いずれも exit `0`

```bash
bash test/run.sh
```

- 成功 361 件 / 失敗 0 件 / スキップ 0 件

## Self-review

- Bash 3.2 compatibility:
  - 連想配列、`mapfile`、process substitution、ガード無し配列展開を使っていない。
  - engine 引数 forwarding は配列ではなく `"$@"` を使う形へ戻し、selftest gate を通した。
- path quoting:
  - 空白入り fixture path で focused tests を通した。
  - 既定出力先は `paths.sh` 由来で組み立て、実装コードへの新パス literal 直書きを避けた。
- failure propagation:
  - engine 非ゼロはそのまま返す。
  - `python3` 不在、空レポート、stale report、missing section/marker 系は launcher 自身が非ゼロで止める。
- output collision:
  - 同秒の既存候補は `-L` を含めて回避し、`-2` 以降を使う。
- accidental settings/transcript changes:
  - launcher test は fixture-local wrapper だけを使い、実 repo の `.token-saver` や実 transcript/settings へ書かない。

## コミット

予定コミットメッセージ:

`feat: token-reportの出力ランチャを追加する`
