# Auto-mode Auxiliary Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `token-report` に Claude Code の permission classifier 呼出件数と Codex の `codex-auto-review` 実測 usage を独立区分で追加し、欠測を 0 や推計値に置き換えず安全に報告する。

**Architecture:** 既存の読み取り専用 Python エンジンに、Claude JSONL の classifier メタデータ検出器と Codex sessions JSONL の guardian/auto-review usage 検出器を追加する。どちらも本文を保持・出力せず、既存 main/subagent 集計および calibration snapshot/fingerprint から分離する。テスト fixture では `CLAUDE_CONFIG_DIR` と `CODEX_HOME` を明示的に隔離し、期間・repo・重複・型・欠測・秘匿境界を RED/GREEN で固定する。

**Tech Stack:** Python 3.6 互換の標準ライブラリ、Bash 3.2 互換テスト、JSONL、Markdown、既存 `test/run.sh` harness。

## Global Constraints

- 対象 Issue は [#56](https://github.com/shiyghoou/claude-token-saver/issues/56)。作業場所は `/home/shingo/claude-token-saver-issue-56`、ブランチは `issue-56-auto-mode-auxiliary-usage` に固定する。
- 設計の正は `docs/superpowers/specs/2026-08-08-issue-56-auto-mode-auxiliary-usage-design.md`。設計 commit は `1112f15a56e10dec6e845e044c1f0d9a44e1780c`、開始時の `origin/main` は `1bc544356c05050694964f25f71f069967716179`。
- 元の `/home/shingo/claude-token-saver` にある利用者の dirty file は変更・退避・削除しない。
- Claude の `classifierMetaLines` 本文、Codex の session id・path・本文、prompt、tool result、環境変数値をレポートへ出さない。
- Claude classifier の token usage は必ず `N/A` とし、0 や推計値を出さない。Codex も欠測・型不正・整合性不一致を推計しない。
- `cached_input_tokens` は input の内数、`reasoning_output_tokens` は output の内数として表示し、合計へ再加算しない。
- calibration snapshot、fingerprint、recommendation、`token-calibrate --apply` の入力契約を変更しない。
- Python 3.6 と Bash 3.2 の範囲を守る。`datetime.fromisoformat`、`str.isascii`、dataclass、pathlib の新しい API は追加しない。
- 各タスクは RED を観測してから最小実装で GREEN にする。各タスク末尾で `git diff --no-renames --check` を実行してローカル commit する。
- push、PR 作成、merge、rebase、branch/worktree 削除は行わない。

---

### Task 1: Claude permission classifier の呼出件数を分離計測する

**Files:**

- Modify: `test/test-token-report.sh`
- Modify: `scripts/measure-token-usage.py:940-1274`
- Modify: `scripts/measure-token-usage.py:1685-1805`

- [ ] **Step 1: fixture の Codex 入力を空ディレクトリへ隔離する**

`_fixture` に次を追加する。

```bash
FIXTURE_CODEX_HOME="$TEST_TMP/codex-home"
mkdir -p "$FIXTURE_CODEX_HOME/sessions"
```

`_execute_report_from` は次の環境を渡す。

```bash
( cd "$run_dir" && HOME="$FIXTURE_HOME" \
    CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR_OVERRIDE:-}" \
    CODEX_HOME="$FIXTURE_CODEX_HOME" \
    python3 -B "$REPO_ROOT/scripts/measure-token-usage.py" \
      --out "$FIXTURE_OUT" "$@" )
```

- [ ] **Step 2: Claude classifier の RED fixture とテストを追加する**

親 JSONL へ、同一 `uuid` の重複、`uuid` 無しで `sessionId` / `sourceToolAssistantUUID` / tool-result `tool_use_id` の代替キーが揃う行、識別子欠測、timestamp 欠測、期間外の行を追加する。`subagents/*.jsonl` にも 1 行追加する。`classifierMetaLines` には `CLASSIFIER_PRIVATE_SENTINEL` を入れる。

追加テストは次の 4 本とする。

```bash
test_Claude_auto_classifierを親とsubagentから重複なく数える
test_Claude_auto_classifierの代替キーと欠測を区別する
test_Claude_auto_classifierはtimestamp欠測を全期間でも除外する
test_Claude_classifier本文を出さずtokenをN_Aにする
```

期待値は `--days 1` で呼出 3、重複 1、識別子欠測 1、timestamp 欠測 1、usage `N/A`。`--days 0` では期間外の valid row だけ増えて呼出 4、timestamp 欠測は依然 1。sentinel と `usage 実測: **0**` は出力されない。

- [ ] **Step 3: RED を確認する**

Run:

```bash
bash test/run.sh test/test-token-report.sh
```

Expected: 新規 4 テストが `permission classifier` / `N/A` 欠落で FAIL。既存 28 テストは PASS。

- [ ] **Step 4: classifier の安全な識別・期間判定を実装する**

`Scan.__init__` に次を追加する。

```python
self.auto_classifier_calls = 0
self.auto_classifier_duplicates = 0
self.auto_classifier_identifier_missing = 0
self.auto_classifier_timestamp_missing = 0
self._auto_classifier_keys = set()
```

`content_blocks` 付近へ次の interface を実装する。

```python
def classifier_tool_use_id(entry):
    values = []
    for block in content_blocks(entry.get("message")):
        if not isinstance(block, dict) or block.get("type") != "tool_result":
            continue
        value = dedup_scalar(block.get("tool_use_id"))
        if value is not None:
            values.append(value)
    if len(values) != 1:
        return None
    return values[0]


def record_claude_auto_classifier(scan, entry, since):
    meta = entry.get("classifierMetaLines")
    if entry.get("type") != "user" or not isinstance(meta, str) or not meta.strip():
        return
    stamp = parse_ts(entry.get("timestamp"))
    if stamp is None:
        scan.auto_classifier_timestamp_missing += 1
        return
    if since is not None and stamp < since:
        return
    uuid = dedup_scalar(entry.get("uuid"))
    if uuid is not None:
        key = ("uuid", uuid)
    else:
        session_id = dedup_scalar(entry.get("sessionId"))
        source_uuid = dedup_scalar(entry.get("sourceToolAssistantUUID"))
        tool_use_id = classifier_tool_use_id(entry)
        if session_id is None or source_uuid is None or tool_use_id is None:
            scan.auto_classifier_identifier_missing += 1
            return
        key = ("fallback", session_id, source_uuid, tool_use_id)
    if key in scan._auto_classifier_keys:
        scan.auto_classifier_duplicates += 1
        return
    scan._auto_classifier_keys.add(key)
    scan.auto_classifier_calls += 1
```

親・subagent scanner の JSON object 確認直後、既存 timestamp filter より前に `record_claude_auto_classifier(scan, entry, since)` を呼ぶ。これで親/subagent が同じ dedup set を共有し、`--days 0` でも classifier の timestamp 必須条件を保つ。

- [ ] **Step 5: Claude の独立レポート区分を追加する**

`## オートモード補助エージェント` / `### Claude Code permission classifier` を `## 実測合計` 後に追加する。出力は呼出、`usage 実測: **N/A**（ログに usage が無いため 0 や推計値へ置き換えない）`、重複、識別子欠測、timestamp 欠測だけとする。

- [ ] **Step 6: GREEN と差分を確認して commit する**

```bash
bash test/run.sh test/test-token-report.sh
python3 -B test/python-compatibility.py
git diff --no-renames --check
git diff --no-renames -- scripts/measure-token-usage.py test/test-token-report.sh
git add scripts/measure-token-usage.py test/test-token-report.sh
git commit -m "Issue #56 Claude auto classifier計測を追加する"
```

Expected: `32 PASS / 0 FAIL / 0 SKIP`、Python compatibility 終了 0。

---

### Task 2: Codex guardian / codex-auto-review usage の実測集計を追加する

**Files:**

- Modify: `test/test-token-report.sh`
- Modify: `scripts/measure-token-usage.py:25-27`
- Modify: `scripts/measure-token-usage.py:893-979`
- Modify: `scripts/measure-token-usage.py:1311-1684`
- Modify: `scripts/measure-token-usage.py:1685-1805`
- Modify: `scripts/measure-token-usage.py:2150-2200`

- [ ] **Step 1: Codex の確定 fixture を追加する**

`$FIXTURE_CODEX_HOME/sessions/2026/08/08/guardian.jsonl` を次の順序で作る。

1. `session_meta.payload.source.subagent.other == "guardian"`、`cwd == FIXTURE_REPO`
2. `turn_context.payload.model == "codex-auto-review"`
3. valid token_count 1: last `(100, 40, 10, 20, 5, 120)`、cumulative 同値
4. 同じ cumulative tuple の再掲
5. valid token_count 2: last `(50, 10, 0, 10, 2, 60)`、cumulative `(150, 50, 10, 30, 7, 180)`
6. model 不一致の token_count 1 行
7. `turn_context.payload.model == "codex-auto-review"` へ戻す
8. `last_token_usage` 欠測 1 行
9. `total_tokens != input_tokens + output_tokens` の不正 usage 1 行

tuple 順は input、cached input、cache write input、output、reasoning output、total。別 file の non-guardian source へ 999 token を置く。

- [ ] **Step 2: Codex 集計の RED テストを 4 本追加する**

```bash
test_Codex_guardian_auto_reviewのusageを別枠集計する
test_Codex_cachedとreasoningを二重加算しない
test_Codex累積usage再掲を二重加算しない
test_Codex識別条件不一致とusage欠測を推計しない
```

期待値は guardian session 1、usage turn 2、row `150 | 50 | 10 | 30 | 7 | 180`、合計 180、cumulative duplicate 1、model 不一致 1、usage 欠測 1、usage 不正 1。999 は出力されない。同じテストで既存 `main 合計: **3,616**` と subagent `10,225` も assert し、Codex 別枠が既存合計へ混ざらないことを固定する。

- [ ] **Step 3: RED を確認する**

```bash
bash test/run.sh test/test-token-report.sh
```

Expected: Task 1 の 32 テストは PASS、新規 4 テストは Codex section 欠落で FAIL。

- [ ] **Step 4: Codex の型検証と集計 object を実装する**

```python
CODEX_HOME = os.environ.get("CODEX_HOME") or os.path.join(HOME, ".codex")
CODEX_SESSIONS_DIR = os.path.join(CODEX_HOME, "sessions")
CODEX_USAGE_FIELDS = (
    "input_tokens",
    "cached_input_tokens",
    "cache_write_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "total_tokens",
)


def validated_codex_usage(value):
    if not isinstance(value, dict):
        return None
    if any(not is_token_count(value.get(name)) for name in CODEX_USAGE_FIELDS):
        return None
    if value["total_tokens"] != value["input_tokens"] + value["output_tokens"]:
        return None
    return dict((name, value[name]) for name in CODEX_USAGE_FIELDS)
```

`safe_int` は型不正を 0 にするため使わない。`CodexAutoStats` は `history_status`、`guardian_sessions`、`usage_turns`、5 breakdown、model mismatch、usage missing/invalid、duplicate、timestamp missing、malformed line、read error を持つ。`total` property は `input + output` だけを返す。

- [ ] **Step 5: `scan_codex_auto_review(args, since)` を実装する**

scanner の契約:

1. sessions root 無しは `history_status = "missing"`、directory でなければ `"unreadable"`。
2. symlink directory/file を辿らず、`.jsonl` を sort して読む。walk/open error は `read_errors`。
3. file ごとに `session_meta.payload.source` が object、`source.subagent` が object、`source.subagent.other` が文字列 `guardian` であることと cwd repo match を確定する。型違いは対象外とする。`--all-projects` の場合だけ cwd filter を外す。
4. 最新 `turn_context.payload.model` を保持する。
5. eligible な `event_msg.payload.type == "token_count"` だけを見る。
6. timestamp は必須。期間外は除外、欠測は `timestamp_missing`。
7. `info.last_token_usage` と `info.total_token_usage` を両方 `validated_codex_usage` に通す。
8. `total_token_usage` の 6-field tuple を file 内 dedup key とする。新規 tuple のときだけ last usage を加算する。

repo 判定 helper は実パスを返さず、既存 `within` を使う。

```python
def codex_cwd_matches_project(value):
    if not isinstance(value, str) or not value:
        return False
    try:
        candidate = os.path.realpath(value)
    except (OSError, ValueError):
        return False
    return candidate == PROJECT_ROOT or within(PROJECT_ROOT, candidate)
```

Claude の親/subagent scan 後、`scan.codex_auto = scan_codex_auto_review(args, since)` を設定する。

- [ ] **Step 6: Codex の独立レポートを追加する**

`### Codex guardian / codex-auto-review` へ history status、guardian session、usage turn、breakdown table、合計、重複、model 不一致、usage 欠測/不正、timestamp 欠測、JSONL 不正行/read error を出す。table header は `input | cached input | cache write input | output | reasoning output | 合計`。末尾に「cached input と reasoning output は内数であり、合計へ再加算しない」と明記する。

- [ ] **Step 7: GREEN と commit**

```bash
bash test/run.sh test/test-token-report.sh
python3 -B test/python-compatibility.py
git diff --no-renames --check
git add scripts/measure-token-usage.py test/test-token-report.sh
git commit -m "Issue #56 Codex auto review usageを計測する"
```

Expected: `36 PASS / 0 FAIL / 0 SKIP`、Python compatibility 終了 0。

---

### Task 3: repo・期間・欠測・秘匿・calibration 境界を強化する

**Files:**

- Modify: `test/test-token-report.sh`
- Modify: `scripts/measure-token-usage.py`
- Modify: `test/python-compatibility.py:80-180`

- [ ] **Step 1: 境界 fixture helper と 5 本の RED テストを追加する**

`_add_unrelated_codex_project` は repo 外 cwd の guardian/auto-review session を作り、last/cumulative usage `(input=200, output=20, total=220)` を持たせる。別 helper は期間外 330 token、timestamp 欠測、壊れた JSONL、本文 `CODEX_PRIVATE_SENTINEL`、session id `CODEX_SESSION_SECRET` を作る。

```bash
test_Codex_auto_reviewはrepoとall_projectsを分ける
test_Codex_auto_reviewは期間外とtimestamp欠測を除外する
test_Codex履歴なし読取不能壊れたJSONLを区別する
test_Codex本文ID実パスをレポートへ出さない
test_オート補助計測をcalibration_snapshotへ入れない
```

期待値:

- repo default 180、`--all-projects` 400
- `--days 1` は 180、`--days 0` は期間外 330 が加わり 510、timestamp 欠測 1
- history root 自体が無い場合を `missing`、`$FIXTURE_CODEX_HOME/sessions` が regular file の場合を `unreadable` として別表示
- 同じ test 内で guardian fixture を `$FIXTURE_HOME/.codex/sessions` へ置き、subshell で `unset CODEX_HOME` して実行し、未設定時の既定値 `~/.codex` でも合計 180 になる
- malformed JSONL 1、全 sentinel と `FIXTURE_CODEX_HOME` 非出力
- Codex fixture ありで生成した `.token-saver/calibration/latest.json` の bytes を保存し、空の Codex sessions root に切り替えて再生成した bytes と `assert_eq` する。さらに `classifier` / `codex_auto` / `guardian` が無いことを確認し、snapshot 内の fingerprint・推奨値も同一であることを固定する

- [ ] **Step 2: RED を確認する**

```bash
bash test/run.sh test/test-token-report.sh
```

Expected: 既存 36 テストは PASS。新規境界テストの repo/all-projects、history status、malformed counter が FAIL。

- [ ] **Step 3: scanner を fail closed に仕上げる**

- 既定実行では `session_meta.cwd` が repo root と同一または配下でなければ除外する。`--all-projects` だけ filter を外す。
- JSON decode error は `malformed_lines`、open/walk error は `read_errors`。例外本文・path は出力しない。
- bool、負数、float、numeric string、欠落 field、total 不一致は `usage_invalid` とし、加算しない。
- `last_token_usage` 自体が無い場合だけ `usage_missing`。
- history missing/unreadable でも report は終了 0。0 token と断定する文言や推計値を出さない。
- cumulative dedup key は session file ごとに閉じ、異なる session の同じ累積値を落とさない。

- [ ] **Step 4: Python compatibility CLI を実環境から隔離する**

`check_calibration_cli` の environment に空の Codex root を指定する。

```python
codex_root = os.path.join(temp_root, "codex-home")
os.makedirs(os.path.join(codex_root, "sessions"))
environment["CODEX_HOME"] = codex_root
```

- [ ] **Step 5: GREEN と commit**

```bash
bash test/run.sh test/test-token-report.sh
bash test/run.sh test/test-python-compatibility.sh
git diff --no-renames --check
git add scripts/measure-token-usage.py test/test-token-report.sh test/python-compatibility.py
git commit -m "Issue #56 オート補助計測の境界を強化する"
```

Expected: token report `41 PASS / 0 FAIL / 0 SKIP`、Python compatibility `2 PASS / 0 FAIL / 0 SKIP`。

---

### Task 4: README・SKILL・基本設計の契約を同期する

**Files:**

- Modify: `test/test-token-report-docs.sh`
- Modify: `README.md`
- Modify: `skills/token-report/SKILL.md`
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md`
- Modify: `test/expected-min-count`

- [ ] **Step 1: 文書契約の RED テストを 2 本追加する**

```bash
_assert_auto_auxiliary_contract() {
  local body="$1" label="$2"
  assert_contains "$body" "オートモード補助エージェント" "$label section"
  assert_contains "$body" "permission classifier" "$label Claude classifier"
  assert_contains "$body" "N/A" "$label Claude usage unavailable"
  assert_contains "$body" "推計しない" "$label no estimation"
  assert_contains "$body" "CODEX_HOME" "$label Codex root"
  assert_contains "$body" "guardian" "$label guardian source"
  assert_contains "$body" "codex-auto-review" "$label Codex model"
  assert_contains "$body" "last_token_usage" "$label measured usage"
  assert_contains "$body" "cached input" "$label cached subset"
  assert_contains "$body" "reasoning output" "$label reasoning subset"
  assert_contains "$body" "calibration" "$label calibration boundary"
}
```

新規テスト:

```bash
test_オート補助計測契約がREADME_SKILL_設計書で一致する
test_Codex全使用量を測るとの誤記を残さない
```

後者は「Codexの全使用量を計測」と旧文言「token-reportによるCodex使用量計測は提供しない」の両方を禁止する。

- [ ] **Step 2: RED を確認する**

```bash
bash test/run.sh test/test-token-report-docs.sh
```

Expected: 新規 2 テストが補助エージェント契約欠落と旧 Codex 非対応文言で FAIL。

- [ ] **Step 3: 3 文書へ同じ安全境界を記載する**

各 token-report 節に次の意味を同じ用語で記載する。

```text
オートモード補助エージェントは main/subagent と別枠で表示する。Claude Code は
classifierMetaLines を持つ permission classifier 呼出件数だけを数え、usage はログに無い
ため N/A とし推計しない。Codex は CODEX_HOME/sessions のうち source が guardian、現在の
model が codex-auto-review である token_count.info.last_token_usage だけを実測する。
cached input と reasoning output は内数で、合計へ二重加算しない。欠測・型不正・整合性
不一致は件数化し、本文・session id・実パスは出力しない。この別枠は calibration の
snapshot、fingerprint、recommendation、apply 入力へ含めない。
```

基本設計の「Codex 使用量計測は提供しない」は、「Codex 全体は対象外だが guardian / codex-auto-review の補助 usage に限定して提供する」へ変更する。delegation-policy を自動起動しない境界は維持する。

- [ ] **Step 4: 件数台帳を更新する**

`test/expected-min-count` の総数を 685、`test-token-report.sh` を 41、`test-token-report-docs.sh` を 11 にする。他の値は変更しない。根拠は 670 + 13 + 2 = 685。

- [ ] **Step 5: GREEN と commit**

```bash
bash test/run.sh test/test-token-report-docs.sh
bash test/run.sh test/test-token-report.sh
git diff --no-renames --check
git add README.md skills/token-report/SKILL.md \
  docs/specs/2026-07-31-claude-token-saver-design.md \
  test/test-token-report-docs.sh test/expected-min-count
git commit -m "Issue #56 オート補助計測の文書を更新する"
```

Expected: docs `11 PASS / 0 FAIL / 0 SKIP`、token report `41 PASS / 0 FAIL / 0 SKIP`。

---

### Task 5: 全体検証・敵対的独立レビュー・Issue 記録を完了する

**Files:**

- Verify only: all Issue #56 changed files
- External record: GitHub Issue #56 comment

- [ ] **Step 1: worktree と変更範囲を再確認する**

```bash
git rev-parse --show-toplevel
git branch --show-current
git status --porcelain=v1 --untracked-files=all --ignored=matching
git log --oneline --decorate -6
```

Expected: root は `/home/shingo/claude-token-saver-issue-56`、branch は `issue-56-auto-mode-auxiliary-usage`。想定外 path があれば停止する。

- [ ] **Step 2: focused tests と全 suite を bounded 実行する**

```bash
bash test/run.sh test/test-token-report.sh
bash test/run.sh test/test-token-report-docs.sh
bash test/run.sh test/test-python-compatibility.sh
timeout 900 bash test/run.sh
```

Expected:

- token-report: `41 PASS / 0 FAIL / 0 SKIP`
- token-report-docs: `11 PASS / 0 FAIL / 0 SKIP`
- python-compatibility: `2 PASS / 0 FAIL / 0 SKIP`
- full suite: `685 PASS / 0 FAIL / 0 SKIP`

timeout はテスト失敗と断定せず、終了 code と最後の出力を記録して原因を調査する。

- [ ] **Step 3: Base/Head と review scope を実 SHA へ固定する**

```bash
git fetch origin main
BASE_SHA="$(git merge-base origin/main HEAD)"
HEAD_SHA="$(git rev-parse HEAD)"
git rev-parse --verify "${BASE_SHA}^{commit}"
git rev-parse --verify "${HEAD_SHA}^{commit}"
git diff --no-renames --name-only "$BASE_SHA..$HEAD_SHA"
git diff --no-renames --check "$BASE_SHA..$HEAD_SHA"
git status --short
```

Expected: diff path は Issue #56 の設計、計画、engine、対象テスト、README/SKILL/基本設計、件数台帳だけ。worktree は clean。

- [ ] **Step 4: 実装者とは別の fresh subagent に敵対的レビューを依頼する**

reviewer は read-only とし、Base/Head/changed paths/Issue #56/承認済み設計を渡す。Claude の dedup/fallback/timestamp/N/A、Codex の guardian+model+repo+period+tuple dedup/内数、欠測 fail-closed、秘匿、calibration 非干渉、Python 3.6 を重点確認させる。各指摘は `P0`〜`P3`、blocking yes/no、file/line、根拠つき。指摘なしも明記させる。

blocking 指摘があれば該当タスクへ戻り、RED/GREEN で修正・focused/full test・commit を行う。その後、同じ Base と新しい Head を明示して fresh re-review する。

- [ ] **Step 5: review と検証結果を Issue #56 に記録する**

Issue comment に reviewer identifier、Base SHA、Head SHA、対象 commits、検証の PASS/FAIL/SKIP、各指摘の priority/blocking/根拠、対応 commit、再レビュー結果を記録する。記録失敗時は完了・merge 可能と宣言しない。

- [ ] **Step 6: 最終状態を報告する**

変更内容、正確な PASS/FAIL/SKIP、Base/Head、review 結果、Issue comment URL、push/PR/merge 未実施を報告する。追加の GitHub 公開操作はユーザーの明示承認を待つ。
