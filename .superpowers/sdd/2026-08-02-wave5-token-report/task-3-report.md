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

---

## Review fix addendum (2026-08-01)

### 対象

- review target before fix: `a8b9dad`
- scope: `scripts/token-report.sh`, `test/test-token-report-launcher.sh`, `test/expected-min-count`

### 受けた指摘

1. default 出力時に `python3` 不在や engine 非ゼロでも先に `.token-saver/token-reports` を作ってしまい、failure path が read-only でなかった。
2. launcher test が failure path の副作用を検証していなかった。

Minor の success message 二重出力は deferred のまま据え置いた。

### Root cause

- launcher は default 出力時に、engine 実行前に `mkdir -p "$REPO_ROOT/$(cts_base_rel)/token-reports"` を行っていた。
- そのため `python3` 不在、engine 非ゼロ、その他 early failure でも fixture repo に `.token-saver/token-reports` が残った。
- テストは rc / stderr だけを見ており、この mutation を検出していなかった。

### RED

追加した failure-path test を先に実行した。

```bash
bash test/run.sh token-report-launcher
```

出力要約:

- 成功 8 件 / 失敗 2 件 / スキップ 0 件
- 失敗:
  - `test_python3が無ければ既定出力ディレクトリを残さない`
  - `test_計測器が非ゼロなら既定出力ディレクトリを残さない`
- 観測:
  - どちらも `fixture repo/.token-saver/token-reports` が存在してしまい、review 指摘どおり failure path が read-only ではなかった。

### 修正内容

- `scripts/token-report.sh`
  - default 出力時は repo 配下へ直接書かず、まず `mktemp` で `/tmp` 側の一時ファイルへ `--out` を差し替えて engine を実行するよう変更した。
  - 一時ファイルに対して、存在・非空・marker より新しいこと・先頭 40 行に `## 計測条件` があることを検証してから、初めて repo 配下の `token-reports/` を作成するよう順序を変更した。
  - 検証後にだけ collision-safe な最終パスを選び、`mv` で validated artifact を配置するようにした。
  - cleanup trap を関数化し、marker と未移動の temporary report を確実に片付けるようにした。
- `test/test-token-report-launcher.sh`
  - `python3` 不在時に default report directory が残らないことを検証する test を追加した。
  - engine 非ゼロ時に default report directory が残らないことを検証する test を追加した。
  - default path の engine 内部 `--out` は、最終配置前の `/tmp/cts-token-report-output.*` になることへ期待値を更新した。
- `test/expected-min-count`
  - runner 実測に合わせて総件数を `344`、launcher 件数を `10` に更新した。

### 修正後の検証

```bash
bash test/run.sh token-report-launcher
```

出力要約:

- 成功 10 件 / 失敗 0 件 / スキップ 0 件

```bash
bash test/run.sh token-report
```

出力要約:

- 成功 24 件 / 失敗 0 件 / スキップ 0 件

```bash
bash -n scripts/token-report.sh
bash -n test/test-token-report-launcher.sh
git diff --check
```

出力要約:

- いずれも exit `0`

```bash
bash test/run.sh
```

出力要約:

- 実行件数の下限: 総 344 件 / ファイル別 8 件分
- 成功 363 件 / 失敗 0 件 / スキップ 0 件

### fix 後のセルフチェック

- failure paths:
  - default 出力時は `python3` 不在 / engine 非ゼロ / validation failure のいずれでも repo 配下の report directory を作らない。
- explicit `--out` semantics:
  - 明示出力先の親は引き続き自動作成しない。
- Bash 3.2 compatibility:
  - 連想配列、`mapfile`、process substitution、ガード無し配列展開を使っていない。
- collision and symlink safety:
  - 最終配置時だけ `-L` を含む衝突回避を行い、dangling symlink を上書きしない。
- marker freshness:
  - freshness / section validation は temporary artifact に対して先に行い、validated artifact だけを最終配置する。
