# Issue #41: キャリブレーション推奨値のパーセンタイル化 設計

- 作成日: 2026-08-06
- 対象Issue: #41
- 状態: 設計承認済み

## 1. 目的

`--calibrate` が推奨する `suggest_session_cut.initial_cache_read`（snapshot の `baseline_cache_read`）を、中央値（p50）固定から**設定可能なパーセンタイル**に変え、警告が定義上セッションの半分で発動する状態を解消する。

併せて次を満たす。

1. 短命セッションが母集団を押し下げ、「運用改善ほど推奨が厳しくなる」逆向き挙動を抑える。
2. snapshot / レポートに分布（p50/p75/p90/p95）と上位集中度を出し、利用者が根拠を見て選べる。
3. 適用ロジック（`baseline` → `initial` / `increment`）と Stop フックの閾値解釈は変えない。

## 2. 根本原因

現行 `build_calibration()` は、メインセッションの重複排除後 `cache_read` 配列に対し `median_integer`（正の値のみ）で baseline を決めている。

```text
baseline_cache_read = median(cache_read > 0)
recommended_levels = [baseline, 2×, 3×]
source = "メインセッションの重複排除後 cache_read 中央値"
```

中央値は「母集団の約半数が超える値」なので、これを警告の発火点にすると**定義上、約半分のセッションで通知が出る**。

実測（Issue 本体）では次も確認されている。

- 期間を広げると短命セッションが増え、推奨値が下がる（7日 → 30日）。
- 分布は強く右に歪み、上位数本が合計の大半を占める。中央値はコスト中心を代表しない。
- 早めに切る運用ほど短命が増え、推奨がさらに下がる。

問題の本体は `suggest-session-cut` の判定ではなく、**推奨値の算出・snapshot・レポート**側である。

## 3. 採用する方式

**方案 C**: パーセンタイル設定 + 短命セッション除外 + 上位 N 集中度レポート。

| 要素 | 内容 | 備考 |
|---|---|---|
| パーセンタイル | `calibration.percentile`（既定 75） | `50` を指定すれば近い運用に戻せる |
| 短命除外 | `calibration.exclude_below_assistant_turns`（既定 3、`0` = オフ） | 母集団フィルタのみ。eligible の合計ターンゲートとは別 |
| 上位集中度 | レポート常時表示、**N=3 固定** | 設定キーは設けない。適用ロジックには使わない |

方案 A（percentile のみ）や方案 B（除外まで）は採用しない。母集団汚染と分布の可視化の両方が Issue の実測に直結するため。

## 4. 設定キーと既定値

既存（維持）:

| キー | 既定 | 意味 |
|---|---|---|
| `calibration.min_sessions` | `5` | eligible に必要な**サンプル本数**（本 Issue 以降はフィルタ後） |
| `calibration.min_assistant_turns` | `100` | eligible に必要な**期間内合計** assistant ターン（フィルタ前） |

追加:

| キー | 既定 | 意味 | 検証 |
|---|---|---|---|
| `calibration.percentile` | `75` | baseline に使うパーセンタイル | 整数 `1..99`。不正時は既定 |
| `calibration.exclude_below_assistant_turns` | `3` | このターン数**未満**のセッションを母集団から除外。`0` で除外オフ | 整数 `0..CALIBRATION_MAX`。`0` を正当値として許可（現行 `calibration_positive_int` の 1 起点とは別バリデータ） |

例:

```json
{
  "calibration": {
    "min_sessions": 5,
    "min_assistant_turns": 100,
    "percentile": 75,
    "exclude_below_assistant_turns": 3
  }
}
```

- config に新キーが無い場合は上記既定。既存キー（`last_applied` 等）は保持する。
- `top_n_sessions` などの集中度用設定キーは**追加しない**（N=3 固定）。
- `suggest-session-cut` / `calibration-config.awk` / Stop フックは従来どおり適用済み `initial` / `increment` のみを読む。新キーの読み取りは measure / apply 側で完結する。

## 5. 算出アルゴリズム

`build_calibration()` 内の処理順を次に固定する。

### 5.1 母集団の構築

1. 入力は現行どおり `scan.session_stats`（メインセッション、重複排除後の集計）。
2. 各セッションについて次を満たすものだけを母集団に入れる。
   - `cache_read` が正の整数（現行 `median_integer` と同じ）
   - `exclude_below_assistant_turns == 0`、または `assistant_turns >= exclude_below_assistant_turns`
3. `values` = 上記を通ったセッションの `cache_read` 配列。
4. 計数:
   - `total_session_count` = 期間内メインセッション総数（`len(scan.session_stats)`、フィルタ前）
   - `sample_session_count` = `len(values)`（フィルタ後）
   - `excluded_session_count` = 短命除外で落とした本数（正の `cache_read` を持つが turns 条件で除外された本数）。`cache_read <= 0` のセッションは母集団外だが、この「短命除外カウント」には含めない。

### 5.2 パーセンタイル

新しい純関数（名称は実装任せ、ここでは `percentile_integer`）を導入する。

- 入力: 整数配列とパーセンタイル `p`（1..99）
- 前処理: 正の整数のみを昇順ソート（呼び出し側で既に絞っていても防御的に同じ規則）
- 空なら `None`
- **nearest-rank 法**（再現可能な整数結果）:
  - `n = len(ordered)`
  - `rank = ceil(p / 100 * n)`（1-based）
  - 返す値は `ordered[rank - 1]`
- `p == 50` の結果は、現行 `median_integer` の偶数長平均とは一致しない場合がある。互換が必要な利用者はレポートの p50 と差分を見て判断する。キャリブレーションの「中央値相当」へ戻す手段は `percentile: 50`（nearest-rank）であり、旧 `median_integer` を baseline 経路に残さない。

参考分布として、同じ母集団で **p50 / p75 / p90 / p95** を常に算出する。

### 5.3 baseline と推奨段階

```text
baseline = percentile_integer(values, settings.percentile)
baseline_cache_read = baseline
recommended_levels = [baseline, baseline*2, baseline*3]   # eligible 時のみ。現行どおり
```

フィールド名 `baseline_cache_read` は互換のため据え置き。意味は「選択パーセンタイルの推奨段階1」。

### 5.4 eligible

次をすべて満たすとき `eligible = true`。

1. `sample_session_count >= min_sessions`（**フィルタ後**本数）
2. 期間内全セッションの合計 `assistant_turns >= min_assistant_turns`（**フィルタ前**合計。現行どおり「期間内に十分な活動があったか」のゲート）
3. `baseline` が正の整数

`prompt_key` の形式 `session_count-assistant_turns-min_sessions-min_assistant_turns` は維持する。ここに入れる `session_count` は **フィルタ後の `sample_session_count`** とする（eligible と apply の min_sessions 判定と一致させる）。

### 5.5 source 文言

固定定数 `CALIBRATION_SOURCE = "...中央値"` による単一文字列等価チェックはやめる。

snapshot の `source` は設定から導出する。例:

```text
メインセッションの重複排除後 cache_read p75（assistant_turns>=3 を母集団）
```

除外オフ（`exclude_below_assistant_turns == 0`）のとき:

```text
メインセッションの重複排除後 cache_read p75
```

apply 側は「固定文字列一致」ではなく、後述の構造フィールドと文言の整合で検証する。

## 6. Snapshot スキーマ

現行の必須フィールドは維持・拡張する。適用に効く値は引き続き `baseline_cache_read` と `recommended_levels`。

### 6.1 追加フィールド

| フィールド | 型 | 意味 |
|---|---|---|
| `percentile` | int | 採用したパーセンタイル |
| `exclude_below_assistant_turns` | int | 採用した短命除外閾値（0 = オフ） |
| `sample_session_count` | int | フィルタ後サンプル本数 |
| `total_session_count` | int | フィルタ前のメインセッション総数 |
| `excluded_session_count` | int | 短命除外で落とした本数 |
| `distribution` | object | `{ "p50", "p75", "p90", "p95" }`。各値は正整数または算出不能時 `null` |
| `concentration` | object | `{ "top_n": 3, "share": <0..1 の number>, "cache_read_sum_top": int, "cache_read_sum_all": int }`。母集団（フィルタ後）に対する上位3の合計比。セッション id / パスは含めない |

### 6.2 意味が変わる／据え置くフィールド

| フィールド | 扱い |
|---|---|
| `session_count` | **フィルタ後**本数（=`sample_session_count`）。eligible / `prompt_key` / apply の min_sessions 判定に使う |
| `assistant_turns` | フィルタ前の合計（現行どおり） |
| `baseline_cache_read` | 選択パーセンタイル値 |
| `recommended_levels` | `[baseline, 2×, 3×]` の整合は現行どおり検証 |
| `source` | 導出文字列（上記） |
| `fingerprint` | 後述。digest の設定キーを拡張 |

`session_count` と `sample_session_count` は同値を書く（読み手がどちらの名前でも辿れるようにする）。冗長だが snapshot 単体で読めることを優先する。

### 6.3 共有境界

`concentration` および distribution に sessionId・パス・プロンプト断片を載せない（既存の共有境界を維持）。

## 7. Apply と後方互換

### 7.1 変更点

`apply-token-calibration.py`（および measure 側の `CALIBRATION_DEFAULTS`）を次のように合わせる。

1. `CALIBRATION_DEFAULTS` に `percentile` と `exclude_below_assistant_turns` を追加する。
2. `source == 旧 CALIBRATION_SOURCE` の単一等価チェックを廃止する。代わりに:
   - snapshot に `percentile` / `exclude_below_assistant_turns` / `sample_session_count` / `total_session_count` / `excluded_session_count` / `distribution` があること
   - それらの型・範囲が正当であること
   - `source` が上記設定から再生成した文言と一致すること
3. `validate_current_config` は新キーを含む全 `CALIBRATION_DEFAULTS` キーを、現行 config（欠落時は既定）と snapshot で照合する。不一致なら適用拒否（現行契約の延長）。
4. `session_count >= min_sessions` の判定は、フィルタ後本数（`session_count` / `sample_session_count`）で行う。
5. 適用本体は従来どおり `baseline_cache_read` を `suggest_session_cut.initial_cache_read` / `increment_cache_read` に書き、`calibration.last_applied` を更新するだけ。

`validate_scan_identity` が指紋再計算に渡す `settings` にも、新キーを含める（fingerprint 節と一致）。

### 7.2 旧 snapshot

`source` が旧「…中央値」のまま、または新フィールドが無い snapshot は **apply 不可**。利用者は再 `--calibrate` する。

これは破壊的だが正しい挙動である。README のキャリブレーション節に、#39 と同様「アルゴリズム／指紋変更後は再 calibrate」の一文を足す。

旧アルゴリズム専用の特別エラーメッセージは設けない（再 calibrate で解消）。

### 7.3 変えないもの

- apply CLI（`--root` / `--latest`）
- Stop フック / `suggest-session-cut` の閾値解釈（倍増ルール）
- 自動 apply の導入
- `--force`

## 8. レポート

`## キャリブレーション` 節に次を出す（文言は実装で整えるが、情報は必須）。

1. 採用パーセンタイルと短命除外条件（オフならその旨）
2. パーセンタイル表: p50 / p75 / p90 / p95、および「採用: pXX = N」
3. 母集団: サンプル本数 / 除外本数 / 期間内総セッション数
4. 上位集中度（常時）: 例 `上位3セッションで全体 cache_read の 59.2%`（フィルタ後母集団）。セッション識別子は出さない

集中度の分母・分子は snapshot の `concentration` と同じ定義にする。

## 9. 指紋（fingerprint）

#39 の方針（digest から size/mtime を外し、対象はパス集合）は **変更しない**。本 Issue が触るのは設定キーの追記のみ。

digest に含める設定行（既存 + 追加）:

```text
min_sessions:N
min_assistant_turns:N
percentile:N
exclude_below_assistant_turns:N
```

- 期間・selection・project dirs・対象トランスクリプトのパス集合の扱い（#39 後の仕様）はそのまま。
- 集中度の N は設定でも fingerprint でも扱わない（固定表示のため）。
- #39 未マージの main 上で実装する場合でも、path/size/mtime ロジック自体は #41 の差分に含めない。#39 マージ後はその実装へキー追記する。

## 10. テスト設計

既存の `test/test-calibration.sh` / `test/test-token-calibrate.sh` に寄せ、TDD で追加・更新する。

| 領域 | 内容 |
|---|---|
| 単位 | `percentile_integer`: 奇数/偶数長、境界 50/75/90/99、空配列 → `None`、非正値の除外 |
| フィルタ | `exclude_below_assistant_turns=3` で短セッションが母集団から落ち、baseline が上がる。`0` で除外オフ |
| 既定 | キー無し → `percentile=75` / `exclude_below_assistant_turns=3`。旧「中央値固定」前提のケースは `percentile=50` 明示、または新既定に合わせて更新 |
| eligible | フィルタ後本数で `min_sessions`。合計 turns はフィルタ前。不足時は ineligible |
| snapshot | 新フィールド・`distribution`・`concentration`（id/パス無し）・`source`・`recommended_levels` 整合 |
| apply | 新フィールド一致で成功；config の `percentile` または `exclude_below_assistant_turns` 不一致で失敗；旧中央値 snapshot を拒否 |
| 指紋 | 新設定キーを変えると fingerprint が変わる。パス集合ルール自体の回帰は #39 のテストに委ね、#41 ではキー追記分だけ確認 |
| レポート | p50/75/90/95 表と「上位3…%」文字列 |
| 回帰 | symlink fail-closed、config の無関係キー保持、不足サンプル、token-calibrate フロー |

## 11. 変更ファイル（実装時）

- Modify: `scripts/measure-token-usage.py` — 設定読取、percentile 算出、母集団フィルタ、snapshot/report、fingerprint 設定キー
- Modify: `scripts/apply-token-calibration.py` — defaults、snapshot 検証、config 照合、fingerprint 再計算用 settings
- Modify: `test/test-calibration.sh` および／または `test/test-token-calibrate.sh`
- Modify: `README.md` — 既定パーセント・短命除外・再 calibrate の注意

実装計画書・実装コードは本ドキュメントのスコープ外（別タスク）。

## 12. 非目標（スコープ外）

- **#39 / #40**: 指紋の path 集合化、size/mtime 除去、`--force` 非追加、apply の例外メッセージ露出。#41 は判定条件キーの digest 追記のみ
- **#42**: `subagents/*.jsonl` 実測、起動固定コスト、delegation-policy の損益分岐。baseline は引き続きメイン `session_stats.cache_read` のみ
- Stop フックの発火ロジック / `suggest_session_cut` の閾値解釈そのもの
- 自動 apply、価格・課金加重、レポートへの sessionId 露出
- `exclude` を cache_read 閾値で行う案（必要なら後続 Issue）
- 集中度 N の設定化、および集中度を baseline 算出に使うこと

## 13. 承認済み決定

| 項目 | 決定 |
|---|---|
| Q1 `percentile` 既定 | **75** |
| Q2 `exclude_below_assistant_turns` 既定 | **3**（`0` = オフ） |
| Q3 上位集中度 | レポート常時、**N=3 固定**（設定キー無し） |
| Q4 eligible の min_sessions | **フィルタ後サンプル数**。snapshot に total / excluded も記録 |
| 方式 | 方案 C（percentile + 短命除外 + 上位Nレポート） |
