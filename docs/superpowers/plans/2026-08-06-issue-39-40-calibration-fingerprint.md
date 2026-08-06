# Issue #39 / #40 Calibration Fingerprint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** トランスクリプトのサイズ・mtime 成長だけでは `--apply` が失敗せず、失敗時は `CalibrationError` の理由が stderr に出るようにする。

**Architecture:** `calibration_fingerprint()` から `st_size` / `st_mtime` を外し、期間・設定・selection・project dirs・パス集合だけを digest する。`apply-token-calibration.py` の `main()` は例外メッセージ（または型名）を stderr に出す。既存の「mtime 変化で拒否」テストを新契約へ書き換え、パス増減拒否とエラー文言の回帰を追加する。

**Tech Stack:** Python 3（`measure-token-usage.py` / `apply-token-calibration.py`）、Bash テストランナー（`test/run.sh`）、既存 fixture。

## Global Constraints

- 作業ブランチ: `issue-39-40-calibration-fingerprint`（`main` 直編集禁止）。
- 基点: 設計コミット `6f104c9` を含む現行 `main`。
- 通常 checkout に既にある無関係な modified / untracked（Stage 4 文書、他スクリプト差分）には触れない。
- `--force`、現行セッション除外、指紋バージョン接頭辞は追加しない。
- #41 / #42 のロジックは変更しない。
- TDD: 失敗するテストを先に書き、実装はその後。
- コミットはユーザーが明示したとき、または各 Task 完了時に計画どおり行う。push / PR はユーザー承認後。

### File map

| File | Role |
| --- | --- |
| `scripts/measure-token-usage.py` | `calibration_fingerprint` から size/mtime を削除 |
| `scripts/apply-token-calibration.py` | `main` の except で理由を出力 |
| `test/test-token-calibrate.sh` | mtime 契約更新、パス増減拒否、エラー文言 |
| `test/test-calibration.sh` | 指紋の size 非依存 / パス依存の単体検証 |
| `test/expected-min-count` | 件数下限更新 |
| `README.md` | 再 calibrate 注意を一文 |

---

### Task 1: 指紋の size/mtime 非依存を RED で固定する

**Files:**
- Modify: `test/test-calibration.sh`
- Modify: `test/test-token-calibrate.sh`
- Modify: `test/expected-min-count`

- [ ] **Step 1: `test/test-calibration.sh` に指紋ヘルパと2テストを追加する**

ファイル末尾（既存の最後の `test_*` の後）へ次を追加する。

```bash
_fingerprint_from_paths() {
  python3 - "$REPO_ROOT" "$@" <<'PYEOF'
import os
import runpy
import sys

repo_root = sys.argv[1]
paths = sys.argv[2:]
engine = runpy.run_path(os.path.join(repo_root, "scripts", "measure-token-usage.py"))
args = type("Args", (object,), {})()
args.days = 0
args.all_projects = False
settings = {"min_sessions": 5, "min_assistant_turns": 100}
print(
    engine["calibration_fingerprint"](
        args, None, settings, paths, [], ["/proj"], False
    )
)
PYEOF
}

test_fingerprintはファイルサイズ変化でも一致する() {
  path_a="$TEST_TMP/fp-a.jsonl"
  path_b="$TEST_TMP/fp-b.jsonl"
  printf 'x\n' >"$path_a"
  printf 'y\n' >"$path_b"
  before="$(_fingerprint_from_paths "$path_a" "$path_b")"
  printf 'xxxxx\n' >>"$path_a"
  python3 - "$path_a" <<'PYEOF'
import os, sys
st = os.stat(sys.argv[1])
os.utime(sys.argv[1], (st.st_atime, st.st_mtime + 5))
PYEOF
  after="$(_fingerprint_from_paths "$path_a" "$path_b")"
  assert_eq "$before" "$after" "size/mtime変化でも指紋一致"
}

test_fingerprintはパス集合が変わると不一致になる() {
  path_a="$TEST_TMP/fp-set-a.jsonl"
  path_b="$TEST_TMP/fp-set-b.jsonl"
  path_c="$TEST_TMP/fp-set-c.jsonl"
  printf 'a\n' >"$path_a"
  printf 'b\n' >"$path_b"
  printf 'c\n' >"$path_c"
  first="$(_fingerprint_from_paths "$path_a" "$path_b")"
  second="$(_fingerprint_from_paths "$path_a" "$path_b" "$path_c")"
  assert_ne "$first" "$second" "パス増加で指紋不一致"
}
```

`assert_ne` がテストヘルパに無い場合は次で代替する（既存 `assert_eq` の隣を確認し、無ければ同等の実装を `test/run.sh` から使える形で書くか、次を使う）。

```bash
  if [ "$first" = "$second" ]; then
    fail "パス増加で指紋不一致: 同じ値 $first"
  fi
```

（`fail` も無ければ `assert_eq` を逆用せず、`[ "$first" != "$second" ] || { echo "..."; return 1; }` など、既存ファイルの失敗パターンに合わせる。）

- [ ] **Step 2: `test_入力トランスクリプトが変化したsnapshotを適用せず再計測後だけ適用する` を置き換える**

`test/test-token-calibrate.sh` の当該関数を削除し、次の2関数に置き換える。

```bash
test_トランスクリプト追記だけではapplyが失敗しない() {
  _fixture_with_measured_snapshot
  python3 - "$TRANSCRIPT" <<'PYEOF'
import json
import os
import sys
from datetime import datetime, timezone

path = sys.argv[1]
stamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps({
        "type": "assistant",
        "timestamp": stamp,
        "sessionId": "measured-session-0",
        "message": {
            "id": "growth-only",
            "usage": {
                "input_tokens": 1,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 1,
                "output_tokens": 1,
            },
            "content": [],
        },
    }) + "\n")
st = os.stat(path)
os.utime(path, (st.st_atime, st.st_mtime + 3))
PYEOF
  _run_calibrate_command --apply
  assert_eq "0" "$STATUS" "追記のみでもapply成功"
  assert_eq "4000" "$(_config_value initial_cache_read)" "追記後も推奨値適用"
  unset FIXTURE_CLAUDE_CONFIG_DIR
}

test_対象パスが増えたsnapshotはapplyを拒否する() {
  _fixture_with_measured_snapshot
  before="$(cat "$CONFIG")"
  extra="$(dirname "$TRANSCRIPT")/extra-session.jsonl"
  python3 - "$extra" <<'PYEOF'
import json
import sys
from datetime import datetime, timezone

stamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(json.dumps({
        "type": "assistant",
        "timestamp": stamp,
        "sessionId": "extra-session",
        "message": {
            "id": "extra-1",
            "usage": {
                "input_tokens": 1,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 10,
                "output_tokens": 1,
            },
            "content": [],
        },
    }) + "\n")
PYEOF
  _run_calibrate_command --apply
  assert_eq "1" "$STATUS" "パス増加でapply拒否"
  assert_contains "$(cat "$TEST_TMP/token-calibrate.err")" "対象がsnapshot作成時から変化した" "パス増加の理由"
  assert_eq "$before" "$(cat "$CONFIG")" "パス増加時のconfig非変更"
  unset FIXTURE_CLAUDE_CONFIG_DIR
}
```

- [ ] **Step 3: #40 用のエラー文言テストを追加する**

同じファイルへ追加する。

```bash
test_apply失敗時にCalibrationErrorの理由を出す() {
  _fixture_with_latest
  python3 - "$LATEST" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    snapshot = json.load(handle)
snapshot["fingerprint"] = "0" * 64
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(snapshot, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PYEOF
  before="$(cat "$CONFIG")"
  _run_calibrate_command --apply
  assert_eq "1" "$STATUS" "偽fingerprintで失敗"
  err="$(cat "$TEST_TMP/token-calibrate.err")"
  assert_contains "$err" "キャリブレーションを適用できません: " "理由付き接頭辞"
  assert_contains "$err" "対象がsnapshot作成時から変化した" "具体理由"
  assert_eq "$before" "$(cat "$CONFIG")" "失敗時非変更"
}
```

- [ ] **Step 4: `test/expected-min-count` を更新する**

件数の差分:
- `test-calibration.sh`: +2（指紋 size 非依存 / パス集合）→ 21 → 23
- `test-token-calibrate.sh`: 旧1本削除 + 新3本 → 15 → 17（+2）
- 総件数: 625 → 629

```
629
...
test-calibration.sh 23
...
test-token-calibrate.sh 17
```

- [ ] **Step 5: RED を確認する（実装前）**

```bash
bash test/run.sh calibration
bash test/run.sh token-calibrate
```

Expected:
- `test_fingerprintはファイルサイズ変化でも一致する` → FAIL（現行は size/mtime を含むため不一致）
- `test_トランスクリプト追記だけではapplyが失敗しない` → FAIL（現行は拒否して exit 1）
- `test_apply失敗時にCalibrationErrorの理由を出す` → FAIL（stderr が理由なし1行）
- `test_fingerprintはパス集合が変わると不一致になる` と `test_対象パスが増えたsnapshotはapplyを拒否する` は現行でも PASS しうる（パス変化は既に検知）

- [ ] **Step 6: この時点では production を変えず、次 Task へ進む準備だけする**（コミットは Task 3 の GREEN 後でも可。途中コミットするなら「test: Issue #39/#40 の失敗テストを追加」）

---

### Task 2: `calibration_fingerprint` から size/mtime を外す

**Files:**
- Modify: `scripts/measure-token-usage.py`（`calibration_fingerprint`、おおよそ 115–149 行）

- [ ] **Step 1: パスループを次の最小形へ変更する**

```python
    for path in sorted(main_paths + sub_paths):
        if not os.path.lexists(path):
            continue
        digest.update(path.encode("utf-8", "surrogateescape"))
        digest.update(b"\0")
```

`os.stat` と `st_size` / `st_mtime` の update を削除する。存在しないパスは従来どおりスキップする（`lexists` または従来の `OSError` continue のどちらか一方に統一。symlink 追従方針は既存の `transcript_paths` 契約に合わせ、stat を使わないなら `lexists` で十分）。

期間・settings・selection・project dirs のループは変更しない。

- [ ] **Step 2: 指紋系テストを再実行する**

```bash
bash test/run.sh calibration
bash test/run.sh token-calibrate
```

Expected:
- size 非依存 / 追記のみ apply → GREEN
- パス増加拒否 → GREEN
- エラー文言テスト → まだ RED（Task 3）

---

### Task 3: apply 失敗理由を stderr に出す

**Files:**
- Modify: `scripts/apply-token-calibration.py`（`main` 末尾の except、おおよそ 449–451 行）

- [ ] **Step 1: except を分割する**

```python
    except CalibrationError as e:
        sys.stderr.write("キャリブレーションを適用できません: {}\n".format(e))
        return 1
    except (OSError, TypeError, ValueError) as e:
        sys.stderr.write("キャリブレーションを適用できません: {}\n".format(type(e).__name__))
        return 1
```

成功時の `print("キャリブレーションを適用しました")` / `return 0` は変更しない。

- [ ] **Step 2: focused テスト全件 GREEN を確認する**

```bash
bash test/run.sh calibration
bash test/run.sh token-calibrate
```

Expected: 失敗 0。新規分を含む全件 PASS。

- [ ] **Step 3: 不正 snapshot 系の既存テストがまだ exit 1 であることを確認する**（メッセージが付いても STATUS 契約は不変）

- [ ] **Step 4: Commit**

```bash
git add scripts/measure-token-usage.py scripts/apply-token-calibration.py \
  test/test-calibration.sh test/test-token-calibrate.sh test/expected-min-count
git commit -m "$(cat <<'EOF'
fix: キャリブレーション指紋をパス集合基準にし apply 理由を出す

ライブトランスクリプト成長で --apply が必ず失敗する問題を直し、
CalibrationError のメッセージを stderr に出す。

EOF
)"
```

---

### Task 4: README と回帰

**Files:**
- Modify: `README.md`（「キャリブレーションと診断」節、おおよそ 274–292 行付近）

- [ ] **Step 1: 再 calibrate 注意を一文追加する**

`fingerprint` を説明する段落の直後へ次を入れる。

```markdown
fingerprint は対象パス集合と計測条件の同一性を検証する（ファイルサイズや
mtime は含めない）。アルゴリズム変更後の古い snapshot は適用できないので、
`--calibrate` をやり直してから `--apply` する。
```

- [ ] **Step 2: 関連回帰を実行する**

```bash
bash test/run.sh calibration
bash test/run.sh token-calibrate
bash test/run.sh token-report
bash -n scripts/token-calibrate.sh
python3 -m py_compile scripts/measure-token-usage.py scripts/apply-token-calibration.py
```

Expected: すべて成功。

- [ ] **Step 3: 可能ならフルスイート**

```bash
CTS_NO_SKIP=1 bash test/run.sh
```

Expected: 総件数 ≥ 629、失敗 0。環境制約でスキップがある場合はその件数を記録する。

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: キャリブレーション指紋の再 calibrate 注意を追記

EOF
)"
```

- [ ] **Step 5: 設計書の状態を更新する（任意だが推奨）**

`docs/superpowers/specs/2026-08-06-issue-39-40-calibration-fingerprint-design.md` の状態を `実装・検証済み` に更新してコミットする。

---

### Task 5: PR 境界（ユーザー承認後）

- [ ] 1. `git diff main...HEAD` とテスト証跡を確認する。
- [ ] 2. ユーザー承認後だけ push と `gh pr create`（`Closes #39` / `Closes #40`）。
- [ ] 3. merge はユーザーへ依頼して停止する。

---

## Spec coverage checklist

| Spec 要件 | Task |
| --- | --- |
| size/mtime を指紋から外す | Task 2 |
| パス集合・期間・設定は残す | Task 2（変更しない部分）+ Task 1 パス増加テスト |
| CalibrationError メッセージ露出 | Task 3 |
| OSError 等は型名のみ | Task 3 |
| 旧 snapshot は再 calibrate | Task 4 README |
| `--force` なし / #41#42 非変更 | Global Constraints |
| TDD | Task 1 → 2 → 3 |
