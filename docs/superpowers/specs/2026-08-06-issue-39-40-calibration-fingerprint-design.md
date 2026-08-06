# Issue #39 / #40: キャリブレーション指紋と apply エラー表示 設計

- 作成日: 2026-08-06
- 対象Issue: #39, #40
- 状態: 設計承認済み

## 1. 目的

1. `token-report.sh --calibrate` で作った snapshot を、**別ターン**で `token-calibrate.sh --apply` しても、実行中セッションのトランスクリプト成長だけでは失敗しない。
2. `--apply` が失敗したとき、利用者がソースを読まずに原因を特定できる。

README が想定する「snapshot を確認してから明示適用する」2段階運用を成立させる。

## 2. 根本原因

### #39

`measure-token-usage.py` の `calibration_fingerprint()` が、対象トランスクリプト各パスについて `st_size` と `st_mtime` を digest に含めている。

Claude Code セッション実行中、自セッションのトランスクリプトはツール呼び出しごとに成長する。snapshot 作成と apply のあいだにサイズと mtime が必ず変わり、`validate_scan_identity()` が `対象がsnapshot作成時から変化した` を投げる。

指紋の本来の目的は「集計対象の入れ替わり検知」であり、「ログが1バイトも増えていないこと」の保証ではない。

### #40

`apply-token-calibration.py` の `main()` が `CalibrationError` を含む例外を握りつぶし、常に次の1行だけを出す。

```text
キャリブレーションを適用できません
```

`CalibrationError` のメッセージは利用者向け日本語で、パスや認証情報を含まない設計である。出さない理由がない。

## 3. 採用する方式

### #39: 案 A — サイズ・mtime を指紋から外す

`calibration_fingerprint()` の digest から `st_size` と `st_mtime` を削除する。残す要素は次のとおり。

- 期間（`all` または `days:N`）
- `min_sessions` / `min_assistant_turns`
- selection（`all-projects` / `fallback` / `current-project`）
- project dirs（ソート済み）
- 対象トランスクリプトのパス集合（ソート済み、パス文字列のみ）

検知できる変化:

- 期間や判定条件の変更
- プロジェクト選択の変更
- 対象パスの増減（新規セッションファイル出現、削除）

検知しない変化（意図的）:

- 同一パス内の内容追記・サイズ変化・mtime 更新

現行セッション除外（案 B）や `--force`（案 C）は採用しない。案 B は環境変数依存で他プロセス成長に弱く、案 C は README の2段階運用を直さない。

### #40: 例外メッセージの露出

```python
except CalibrationError as e:
    sys.stderr.write("キャリブレーションを適用できません: {}\n".format(e))
    return 1
except (OSError, TypeError, ValueError) as e:
    sys.stderr.write("キャリブレーションを適用できません: {}\n".format(type(e).__name__))
    return 1
```

- `CalibrationError`: メッセージ本文を出す（パス非露出の契約を維持）
- `OSError` / `TypeError` / `ValueError`: 型名のみ（外部パス漏洩を避ける）

## 4. 互換性

- 指紋アルゴリズム変更により、**変更前に作った snapshot は apply 時に不一致になる**。利用者は再 `--calibrate` が必要。これは破壊的だが正しい挙動であり、README のキャリブレーション節に一文追記する。
- `--force` は追加しない。
- snapshot JSON の公開フィールド名、apply CLI（`--root` / `--latest`）、閾値適用ロジックは変更しない。
- #41（パーセンタイル）、#42（subagent 実測）は本設計のスコープ外。

## 5. エラーと利用者向け文言

既存の `CalibrationError` 文言はそのまま使う。指紋不一致時も従来どおり `対象がsnapshot作成時から変化した` を出し、#40 によりそれが stderr に見えるようになる。

旧アルゴリズムの snapshot に対する特別メッセージは設けない（再 calibrate で解消）。

## 6. テスト設計

既存の `test/test-calibration.sh` / `test/test-token-calibrate.sh` に寄せ、TDD で追加する。

1. **指紋のサイズ非依存**: 同一パス集合でファイル内容を追記（size/mtime 変化）しても `calibration_fingerprint` の戻り値が一致する。
2. **指紋のパス集合依存**: 対象パスが増えた（または減った）場合は不一致になる。
3. **apply エラー表示**: `CalibrationError` を起こす不正 snapshot（例: 偽 fingerprint）で `--apply` 相当を実行し、stderr に具体メッセージが含まれること、汎用1行だけではないこと。

## 7. 変更ファイル

- Modify: `scripts/measure-token-usage.py` — `calibration_fingerprint`
- Modify: `scripts/apply-token-calibration.py` — `main` の except
- Modify: `test/test-calibration.sh` および／または `test/test-token-calibrate.sh`
- Modify: `README.md` — 再 calibrate の注意を一文

## 8. 非目標

- 指紋へのバージョンプレフィックス追加
- 現行セッション除外ロジック
- `--force` / `--verbose` フラグ
- キャリブレーション推奨値アルゴリズムの変更（#41）
- サブエージェント計測の変更（#42）
