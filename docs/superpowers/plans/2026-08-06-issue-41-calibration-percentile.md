# Issue #41 Calibration Percentile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `--calibrate` の baseline を設定可能なパーセンタイル（既定75）＋短命セッション除外（既定3）で算出し、snapshot/レポートに分布と上位3集中度を載せる。旧中央値 snapshot は apply 拒否。

**Architecture:** `build_calibration()` で母集団フィルタ → `percentile_integer`（nearest-rank）→ snapshot 拡張。apply は固定 source 文字列一致をやめ、新フィールド検証と source 再生成一致でゲートする。fingerprint digest には新設定キー行だけを追加し、#39 の path/size/mtime 契約は触らない。

**Tech Stack:** Python 3（measure-token-usage.py / apply-token-calibration.py）、Bash テストランナー、既存 fixture。

## Global Constraints

- 作業ブランチ: `issue-41-calibration-percentile`（worktree `/home/shingo/claude-token-saver-issue-41`）
- 設計: `docs/superpowers/specs/2026-08-06-issue-41-calibration-percentile-design.md`（承認済み・変更禁止）
- #42 の subagent 実装コードは触れない
- #39 の path 集合化／size-mtime 除去は本 PR に含めない（digest への設定キー追記のみ）
- Stop フック / suggest-session-cut / calibration-config.awk は変更しない
- TDD: 各タスクでテスト先行 → RED → 実装 → GREEN → commit
- `git -c safe.directory=*` が必要なら都度使う。git config は更新しない

## File Map

| File | Responsibility |
|---|---|
| `scripts/measure-token-usage.py` | defaults/validators、percentile、filter、snapshot、report、fingerprint keys、source 導出 |
| `scripts/apply-token-calibration.py` | defaults、snapshot/config 検証、fingerprint settings 拡張 |
| `test/test-calibration.sh` | 単位・filter・eligible・snapshot・report |
| `test/test-token-calibrate.sh` | apply 成功/拒否、旧 snapshot 拒否、設定不一致 |
| `test/expected-min-count` | 件数下限 |
| `README.md` | 既定・除外・再 calibrate 注意 |

---

### Task 1: percentile_integer と設定読取の単位テスト

**Files:**
- Modify: `test/test-calibration.sh`
- Modify: `scripts/measure-token-usage.py`
- Modify: `test/expected-min-count`

- [ ] **Step 1: harness に percentile mode を追加する failing test を書く**

`test_percentile_integerはnearest_rankで整数を返す` を追加。例:
- `[10,20,30,40,1000]` p75 → 40（rank=ceil(0.75*5)=4）
- `[10,20,40,1000]` p50 → 20（rank=ceil(0.5*4)=2）
- 空配列 → None
- 非正値を除外

- [ ] **Step 2: focused test を実行して RED を確認**

```bash
bash test/run.sh calibration
```

- [ ] **Step 3: 実装**

`CALIBRATION_DEFAULTS` に `percentile: 75` と `exclude_below_assistant_turns: 3` を追加。
`calibration_percentile_int`（1..99）と `calibration_nonneg_int`（0..CALIBRATION_MAX）を追加。
`percentile_integer(values, percentile)` は正の整数のみを昇順にし nearest-rank（ceil(p/100*n)、1-based）で返す。
`load_calibration_settings` は新キーに専用バリデータを使う。`median_integer` は他用途のため残す（baseline 経路では使わない）。

- [ ] **Step 4: GREEN を確認して commit**

```text
feat: percentile_integer と calibration 既定を追加
```

---

### Task 2: build_calibration 母集団・snapshot・source・fingerprint・レポート

**Files:**
- Modify: `scripts/measure-token-usage.py`
- Modify: `test/test-calibration.sh`
- Modify: `test/expected-min-count`

- [ ] **Step 1: RED tests**

追加:
1. `test_exclude_below_assistant_turnsで短命を除外しbaselineが上がる`
2. `test_exclude_belowが0なら短命を残す`
3. `test_フィルタ後本数でmin_sessionsを判定する`
4. 既存レポート／snapshot 期待を新 source（p75・assistant_turns>=3）と新フィールドへ更新
5. `test_percentile設定キー変更でfingerprintが変わる`
6. `test_レポートに分布と上位集中度を出す`

fixture `_fixture_with_calibration_data` を拡張し、任意で percentile / exclude_below_assistant_turns を config に書けるようにする。低ターン数の既存ケースは exclude_below_assistant_turns: 0 を明示。

- [ ] **Step 2: RED 確認**

- [ ] **Step 3: build_calibration 実装（設計 §5）**

1. total_session_count = len(scan.session_stats)
2. cache_read > 0 かつ (exclude==0 or assistant_turns >= exclude) → values
3. excluded_session_count = 正の cache_read だが turns で落ちた本数
4. sample_session_count = session_count = len(values)
5. assistant_turns = フィルタ前合計
6. baseline = percentile_integer(values, settings["percentile"])
7. distribution: p50/p75/p90/p95
8. concentration: top_n=3 fixed
9. source = calibration_source(settings)（固定定数一致チェック廃止）
10. fingerprint digest に percentile / exclude_below_assistant_turns 行を追加（size/mtime 行は現状維持）
11. snapshot に新フィールドを書く

- [ ] **Step 4: レポート節を拡張**

採用条件、分布表、母集団（sample/excluded/total）、上位3集中度を出す。

- [ ] **Step 5: GREEN → commit**

```text
feat: キャリブレーションをパーセンタイル母集団に切り替える
```

---

### Task 3: apply 検証と後方互換拒否

**Files:**
- Modify: `scripts/apply-token-calibration.py`
- Modify: `test/test-token-calibrate.sh`
- Modify: `test/expected-min-count`

- [ ] **Step 1: RED tests**

1. `_fixture_with_latest` を新スキーマへ更新。fingerprint settings にも新キーを渡す
2. `test_旧中央値sourceのsnapshotを拒否する`
3. `test_percentileがconfigと違えば拒否する`
4. `test_exclude_belowがconfigと違えば拒否する`

- [ ] **Step 2: RED 確認**

- [ ] **Step 3: apply 実装**

- CALIBRATION_DEFAULTS に新キー。固定 CALIBRATION_SOURCE 一致は削除
- calibration_source を measure と同じ規則で再生成し一致検証
- load_snapshot: 新フィールド必須・型範囲。sample_session_count == session_count
- _current_calibration_settings: exclude は 0 許可、percentile は 1..99
- validate_scan_identity の settings に新キーを含める
- validate_current_config は全 defaults キーを snapshot と照合

- [ ] **Step 4: GREEN → commit**

```text
feat: apply がパーセンタイル snapshot を検証する
```

---

### Task 4: README・件数・フル検証・PR

**Files:**
- Modify: `README.md`
- Modify: `test/expected-min-count`

- [ ] **Step 1: README のキャリブレーション節を更新**

- 中央値 → 設定可能なパーセンタイル（既定75）
- exclude_below_assistant_turns（既定3、0=オフ）
- アルゴリズム／指紋変更後は再 --calibrate

- [ ] **Step 2: 件数を実測に合わせて更新し focused / full を GREEN にする**

- [ ] **Step 3: docs commit**

```text
docs: Issue #41 のキャリブレーション説明を更新
```

- [ ] **Step 4: push + gh pr create（merge しない）。Closes #41**

---

## expected-min-count 目安（実装後に実測で確定）

| ファイル | 旧 | 目安 |
|---|---|---|
| test-calibration.sh | 21 | 27〜29 |
| test-token-calibrate.sh | 15 | 18〜19 |
| 総件数 | 625 | +9〜12 |

## 完了条件

- 設計の承認済み決定（既定75/3、N=3固定、フィルタ後 min_sessions、旧snapshot拒否、fingerprint key追記のみ）を満たす
- focused + full tests green
- PR 作成済み・未 merge・URL を返す
