# Issue #42 Subagent Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** サブエージェント消費を親の `toolUseResult.totalTokens` ではなく `subagents/*.jsonl` の `message.usage` から実測し、型 join・カバレッジ・起動固定コストをレポート／文書へ反映する。

**Architecture:** `scan_transcripts` は親 JSONL だけを扱い、Agent 起動数と `agentId → type` マップを作る（`totalTokens` / `toolUseResult.usage` は合計へ入れない）。`scan_subagent_transcripts` が `sub_paths` を main と同契約で usage 集計し、ファイル名（またはエントリ）の agentId で type を属性付けする。未解決は `(不明)`、親の `subagent_type` 欠落は従来どおり `(既定)`。レポートは usage 実測・カバレッジ注意・固定コスト分布・型別表（起動/ログ/usage）を出し、docs / delegation-policy は環境固有参考へ更新する。

**Tech Stack:** Python 3（`scripts/measure-token-usage.py`）、Bash fixture テスト（`test/test-token-report.sh` ほか）、既存 `test/run.sh`。

## Global Constraints

- 作業ブランチ: `issue-42-subagent-usage`（`main` 直編集禁止）。基点: 設計コミット `65d6f75`。
- 作業場所: この worktree（`/home/shingo/claude-token-saver-issue-42`）。指紋ブランチ側の dirty ファイルと混ぜない。
- worktree 上に既にある無関係な modified（`install.sh` / launcher など）には触れない。計画実装で触るのは本計画の File map のみ。
- #39 / #40 / #41 の指紋・パーセンタイルロジックは変更しない（本 Issue は subagent 集計と文書だけ）。
- Codex 計測・普遍閾値・価格埋め込み・保持期間変更は非目標（spec §8）。
- TDD: 失敗するテストを先に書き、実装はその後。
- push / PR はユーザー承認後。コミットは各 Task の指示どおり、またはユーザー明示時。

### Ambiguity resolutions（実装者が迷わないよう固定）

1. **agentId join キー**
   - 親: `Agent` `tool_use.input.agentId`（文字列）と、あれば `toolUseResult.agentId` の両方で `agentId → type` を記録する。
   - type は tool_use 側では `sanitize_name(subagent_type) or "(既定)"`。toolUseResult のみのときだけ `sanitize_name(agentType) or "(不明)"`。
   - 同一 agentId に type が複数来たら **先勝ち**（最初に書いた値を保持）。
   - サブログ: 既定キーは `basename(path)` から拡張子除去。行に `agentId` 文字列があればそちらを優先。
   - join 成功時だけその type。失敗（キー無し・マップ無し）は usage / ログ本数を **`(不明)`** に入れる。
2. **`safe_agent_id`**
   - `sanitize_name` は subagent_type 用。agentId 用は制御文字・credential 形・path 形・長さ>200・`"'{}\[]\`|/` を拒否する薄い検査にし、アンダースコア付き ID を落とさない。
3. **カバレッジ表示文言（固定）**
   - `サブエージェント起動: {N}`
   - `読めたログ: {M} 本（うち usage あり {K} 本）`
   - `型未解決ログ: {U} 本`
   - `注意: この区間のサブエージェント集合は完全母集団ではない。欠測分は平均値で補完しない。`
4. **比率の表記**
   - main 比は「usage 実測に対する比」とわかる文言にする（例: `main比（usage実測）`）。欠測埋めはしない。
5. **Wave 5 設計書の後追い追記は任意**（必須成果物にしない）。基礎設計・README・SKILL は必須。

### File map

| File | Role |
| --- | --- |
| `scripts/measure-token-usage.py` | sub usage スキャン、totalTokens 除去、固定コスト、カバレッジ、型 join、レポート／診断 |
| `test/test-token-report.sh` | fixture 新契約 + §6 アサーション |
| `test/test-calibration.sh` | 診断 Agent 節が新しい文言でも GREEN（必要なら fixture に agentId / サブログ） |
| `test/test-delegation-policy.sh` | 「直接測定していない」依存を新文言へ |
| `test/test-token-report-docs.sh` | 固定コスト／sub 計測の文書契約（必要分） |
| `test/expected-min-count` | 件数下限 |
| `README.md` | 見られるもの・限界・delegation 節 |
| `skills/token-report/SKILL.md` | 読み方・限界 |
| `skills/delegation-policy/SKILL.md` | §3.4 相当の固定費文言 |
| `docs/specs/2026-07-31-claude-token-saver-design.md` | totalTokens 前提・固定費未測定の整合 |

---

### Task 1: fixture と RED テスト（sub usage / totalTokens 非採用 / main 非混入 / 重複排除）

**Files:**
- Modify: `test/test-token-report.sh`
- Modify: `test/expected-min-count`（この Task では仮更新でもよい。最終確定は Task 7）

- [ ] **Step 1: `_fixture` の Agent / toolUseResult / subagents を新契約へ書き換える**

既存 fixture 生成 Python のうち、Agent 起動・toolUseResult・subagents 書き出し部分を次の意図で置き換える（他の Read/MCP/id無し行は維持）。

```python
# message-main 内の Agent（agentId 付き）
{"type": "tool_use", "id": "toolu-agent-plot", "name": "Agent",
 "input": {"subagent_type": "plot-adversarial-reviewer",
           "agentId": "agent-plot-1",
           "prompt": "秘密の prompt sentinel"}},

# message-extra 内の Agent（ログ無し起動 → カバレッジ欠測用）
{"type": "tool_use", "id": "toolu-agent-lint", "name": "Agent",
 "input": {"subagent_type": "lint-reviewer",
           "agentId": "agent-lint-missing"}},

# plot の結果（totalTokens は残すが合計非採用。agentId で join）
rows.append({"type": "user", "timestamp": stamp(8), "sessionId": "session",
             "toolUseResult": {"agentType": "plot-adversarial-reviewer",
                               "agentId": "agent-plot-1",
                               "resolvedModel": "claude-opus-4-8[1m]",
                               "totalTokens": 12345, "usage": usage(5, 300, 3000, 40),
                               "prompt": "秘密の tool result prompt",
                               "content": "秘密の tool result content"},
             "message": {"role": "user", "content": "秘密の本文 sentinel"}})

# lint の結果（totalTokens 0）も agentId を付ける
rows.append({"type": "user", "timestamp": stamp(5), "sessionId": "session",
             "toolUseResult": {"agentType": "lint-reviewer",
                               "agentId": "agent-lint-missing",
                               "resolvedModel": "claude-sonnet-5",
                               "totalTokens": 0, "usage": usage(0, 0, 0, 0)},
             "message": {"role": "user", "content": "suppressed helper body"}})

# 結合できるサブログ（固定コスト標本1 + usage 合計）
plot_path = os.path.join(project, "session", "subagents", "agent-plot-1.jsonl")
with open(plot_path, "w", encoding="utf-8") as fh:
    # 同一 message.id の2行 → 重複排除後1回だけ
    for block in ({"type": "thinking", "thinking": "秘密の subagent 本文"},
                  {"type": "text", "text": "秘密の subagent 本文"}):
        fh.write(json.dumps({
            "type": "assistant", "timestamp": stamp(8), "agentId": "agent-plot-1",
            "message": {"id": "sub-msg-1", "model": "sub-model",
                        "usage": usage(9, 900, 9000, 90),
                        "content": [block]},
        }, ensure_ascii=False) + "\n")
    # 2本目の usage（合計確認・固定コストは先頭だけ）
    fh.write(json.dumps({
        "type": "assistant", "timestamp": stamp(7), "agentId": "agent-plot-1",
        "message": {"id": "sub-msg-2", "model": "sub-model",
                    "usage": usage(1, 0, 0, 1),
                    "content": []},
    }, ensure_ascii=False) + "\n")

# 型未解決の孤立ログ（親マップに無い agentId）
orphan_path = os.path.join(project, "session", "subagents", "agent-orphan.jsonl")
with open(orphan_path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({
        "type": "assistant", "timestamp": stamp(6),
        "message": {"id": "sub-orphan", "model": "orphan-model",
                    "usage": usage(2, 20, 200, 2),
                    "content": [{"type": "text", "text": "秘密の orphan 本文"}]},
    }, ensure_ascii=False) + "\n")
```

旧 `session/subagents/a.jsonl` 書き出しは削除する。`alt_project` へ親 jsonl を複製している既存ロジックはそのまま（サブログは HOME 側 project のみでよい。`CLAUDE_CONFIG_DIR` テストが sub 合計を見ないなら複製不要。sub 合計を見る新テストは `--all-projects` + HOME fixture で実行）。

**期待値（日次 `--days 1`、main 契約は変更なし）:**

- main 合計: 引き続き `3,616`（既存テスト維持）
- plot サブログ usage（重複排除後）: `(9+900+9000+90) + (1+0+0+1) = 10,001`
- orphan: `2+20+200+2 = 224`
- sub 別枠合計: `10,001 + 224 = 10,225`
- `12,345` はレポートに出てはならない（または消費合計として出てはならない。文字列としても出さない方針）
- 固定コスト標本: plot 初回入力 `9+900+9000=9909`、orphan 初回 `2+20+200=222` → 中央値・最小・最大・標本数 2

- [ ] **Step 2: 旧 `12,345` 依存テストを置き換え、新テストを追加する**

削除または全面置換:

```bash
# 削除: test_サブエージェントをagentTypeとresolvedModelで分類する
# （resolvedModel / totalTokens 主指標の契約を捨てる）
```

追加（既存 `test_subagentsの詳細usageを親の合計へ混ぜない` も合わせて強化）:

```bash
test_subagentsのmessage_usageを別枠合計に載せる() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" "message.usage" "実測根拠の明示"
  assert_contains "$report" "10,225" "subagents usage 合計"
  assert_contains "$report" "plot-adversarial-reviewer" "join 済み type"
  assert_contains "$report" "(不明)" "未解決バケツ"
}

test_toolUseResultのtotalTokensをsub合計へ入れない() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  assert_not_contains "$report" "12,345" "totalTokens 非採用"
  assert_not_contains "$report" "toolUseResult.totalTokens" "totalTokens 主指標ラベル禁止"
  # toolUseResult.usage (5+300+3000+40=3345) を足した偽合計も禁止
  assert_not_contains "$report" "13,570" "toolUseResult.usage 非加算"
  assert_contains "$report" "10,225" "jsonl usage のみ"
}

test_subagentsの詳細usageを親の合計へ混ぜない() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" "main 合計: **3,616**" "main 不変"
  assert_not_contains "$report" "main 合計: **13,841**" "main+sub 混入禁止"
  assert_contains "$report" "subagents/" "subagents 別枠言及"
}

test_subagent内の同一message_idは一度だけ集計する() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  # 重複を足すと 10,225 + 9,999 = 20,224 になる
  assert_not_contains "$report" "20,224" "sub 内二重計上禁止"
  assert_contains "$report" "10,225" "重複排除後合計"
}

test_subagent本文をレポートへ出さない() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  assert_not_contains "$report" "秘密の subagent 本文" "sub 本文秘匿"
  assert_not_contains "$report" "秘密の orphan 本文" "orphan 本文秘匿"
}
```

- [ ] **Step 3: RED を確認する（実装前）**

```bash
bash test/run.sh token-report
```

Expected: 上記新テストが FAIL（現行は `12,345` を出し、sub `message.usage` を別枠合計へ載せず、`(不明)` バケットも無い）。既存の main 系はまだ通るものもある。

- [ ] **Step 4: Commit（テストのみ）**

```bash
git add test/test-token-report.sh
git commit -m "$(cat <<'EOF'
test: Issue #42 の subagents usage 契約を RED で固定する

EOF
)"
```

（dirty な無関係ファイルを `git add` しない。）

---

### Task 2: RED — 型 join・起動数・固定コスト・カバレッジ

**Files:**
- Modify: `test/test-token-report.sh`

- [ ] **Step 1: 次のテストを追加する**

```bash
test_型joinと不明バケツ() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  # plot 行: 起動1 / ログ1 / usage 10,001
  assert_contains "$report" "plot-adversarial-reviewer" "join type"
  assert_contains "$report" "| plot-adversarial-reviewer | 1 | 1 |" "起動とログ列"
  assert_contains "$report" "10,001" "typed usage"
  # orphan → (不明)
  assert_contains "$report" "| (不明) | 0 | 1 |" "不明はログのみ"
  assert_contains "$report" "224" "不明 usage"
  # (既定) と (不明) を混同しない（この fixture では (既定) 起動は 0）
  assert_not_contains "$report" "| (既定) | 0 | 1 |" "不明を既定へ落とさない"
}

test_起動数が親Agent_tool_useと一致する() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" "| plot-adversarial-reviewer | 1 |" "plot 起動1"
  assert_contains "$report" "| lint-reviewer | 1 | 0 |" "lint 起動1ログ0"
  assert_contains "$report" "サブエージェント起動: 2" "起動合計"
}

test_起動固定コストの中央値最小最大標本数を出す() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" "起動固定コスト" "固定コスト節"
  assert_contains "$report" "中央値" "中央値"
  assert_contains "$report" "最小" "最小"
  assert_contains "$report" "最大" "最大"
  assert_contains "$report" "標本数: 2" "標本数"
  # 9909 と 222 → 中央値は既存 median_non_negative_integer で (222+9909)//2 = 5065
  assert_contains "$report" "9,909" "最大または標本"
  assert_contains "$report" "222" "最小"
  assert_contains "$report" "5,065" "中央値"
}

test_固定コストを合算へ二重加算しない() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  # 10,225 + 9,909 + 222 = 20,356 を合計として出さない
  assert_not_contains "$report" "20,356" "固定コスト二重加算禁止"
  assert_contains "$report" "10,225" "usage 合計のみ"
}

test_カバレッジと欠測注意を出す() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" "サブエージェント起動: 2" "起動数"
  assert_contains "$report" "読めたログ:" "ログ本数"
  assert_contains "$report" "うち usage あり" "usage 本数"
  assert_contains "$report" "型未解決ログ:" "未解決"
  assert_contains "$report" "完全母集団ではない" "欠測注意"
  assert_contains "$report" "欠測分は平均値で補完しない" "補完禁止"
}
```

- [ ] **Step 2: `--top` テストを新表契約へ直す**

`test_top_は一覧ごとの最大行数を制限する` 内の subagent 断言を維持できるならそのまま（plot が lint より usage/起動ソートで先頭）。`resolvedModel`（`claude-opus-4-8[1m]`）必須断言があれば削除する。

```bash
  assert_contains "$report" "plot-adversarial-reviewer" "subagent先頭"
  assert_not_contains "$report" "lint-reviewer" "subagent制限"
  # 次は削除:
  # assert_contains "$report" "claude-opus-4-8[1m]" ...
```

- [ ] **Step 3: RED 確認**

```bash
bash test/run.sh token-report
```

Expected: Task 1–2 の新テストが FAIL。

- [ ] **Step 4: Commit**

```bash
git add test/test-token-report.sh
git commit -m "$(cat <<'EOF'
test: Issue #42 の join・固定コスト・カバレッジを RED で追加する

EOF
)"
```

---

### Task 3: `Scan` / `safe_agent_id` / 親スキャンから totalTokens 経路を外す

**Files:**
- Modify: `scripts/measure-token-usage.py`（`Scan`、`scan_transcripts`、ヘルパ）

- [ ] **Step 1: helper と Scan フィールドを追加する**

`is_token_count` 付近へ:

```python
def safe_agent_id(value):
    if not isinstance(value, str) or not value or len(value) > 200:
        return None
    if (
        any(ch in value for ch in "\"'{}[]\\`|/")
        or has_unsafe_text(value)
        or credential_shaped(value)
        or path_shaped_metadata(value)
    ):
        return None
    return value


def agent_id_from_sub_path(path):
    base = os.path.basename(path)
    if base.endswith(".jsonl"):
        base = base[: -len(".jsonl")]
    return safe_agent_id(base)
```

`Scan.__init__` を次のフィールド構成へ更新する（不要になった totalTokens 集計用は落とす）:

```python
        self.agent_calls = Counter()
        self.agent_id_types = {}  # agentId -> type str
        self.agent_usage = defaultdict(Usage)
        self.agent_usage_total = Usage()
        self.agent_log_counts = Counter()  # type -> log files attributed
        self.agent_fixed_costs = []  # list[int]
        self.sub_files = 0
        self.sub_files_with_usage = 0
        self.sub_unresolved_logs = 0
        self.sub_mcp_calls = Counter()
        # 削除対象（参照が残ればコンパイル/実行で気づく）:
        # agent_results, agent_tokens, agent_models, agent_max, agent_total
```

参照箇所（`build_report` / `build_diagnostics`）は Task 5 で一括置換する。この Task では `scan_transcripts` 内の totalTokens ブロックを削除し、起動と ID マップだけ残す。

- [ ] **Step 2: `scan_transcripts` の Agent / toolUseResult 処理を置き換える**

Agent `tool_use` 分岐:

```python
                        if name == "Agent":
                            tool_input = tool_input if isinstance(tool_input, dict) else {}
                            subagent = (
                                sanitize_name(tool_input.get("subagent_type")) or "(既定)"
                            )
                            scan.agent_calls[subagent] += 1
                            agent_id = safe_agent_id(tool_input.get("agentId"))
                            if agent_id and agent_id not in scan.agent_id_types:
                                scan.agent_id_types[agent_id] = subagent
```

（既存コードは `tool_input` を先に取っているので、その流れに合わせて同じ意味になるよう嵌入する。）

`toolUseResult` の **totalTokens 加算ブロック全体を削除**し、ID マップ補充だけにする:

```python
                result = entry.get("toolUseResult")
                if isinstance(result, dict):
                    agent_id = safe_agent_id(result.get("agentId"))
                    if agent_id and agent_id not in scan.agent_id_types:
                        subagent = sanitize_name(result.get("agentType")) or "(不明)"
                        scan.agent_id_types[agent_id] = subagent
```

- [ ] **Step 3: 構文チェック**

```bash
python3 -m py_compile scripts/measure-token-usage.py
```

Expected: 成功。token-report テストはまだ FAIL（sub スキャン未実装・レポート未更新）。

- [ ] **Step 4: Commit**

```bash
git add scripts/measure-token-usage.py
git commit -m "$(cat <<'EOF'
refactor: 親スキャンから totalTokens 合計経路を除去する

EOF
)"
```

---

### Task 4: `scan_subagent_transcripts` を実装して `main` から呼ぶ

**Files:**
- Modify: `scripts/measure-token-usage.py`

- [ ] **Step 1: 次の関数を `scan_transcripts` の直後に追加する**

```python
def scan_subagent_transcripts(scan, paths, since):
    seen_messages = set()
    for path in paths:
        try:
            handle = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        file_agent_id = agent_id_from_sub_path(path)
        accepted_usage = False
        fixed_cost = None
        line_seen = False
        with handle:
            for line in handle:
                scan.lines += 1
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(entry, dict):
                    continue

                stamp = parse_ts(entry.get("timestamp"))
                if since is not None:
                    if stamp is None:
                        continue
                    if stamp < since:
                        continue
                line_seen = True

                entry_agent_id = safe_agent_id(entry.get("agentId"))
                if entry_agent_id:
                    file_agent_id = entry_agent_id

                message = entry.get("message")
                if entry.get("type") != "assistant" or not isinstance(message, dict):
                    continue
                usage = message.get("usage")
                if not isinstance(usage, dict):
                    continue
                message_id = dedup_scalar(message.get("id"))
                if message_id is None:
                    key = ("sub", path, fallback_message_key(entry, usage))
                else:
                    key = ("sub", "id", message_id)
                if key in seen_messages:
                    if message_id is not None:
                        scan.skipped_dupes += 1
                    else:
                        scan.skipped_fallback_dupes += 1
                    continue
                seen_messages.add(key)
                one = Usage()
                one.add_raw(usage)
                if fixed_cost is None:
                    fixed_cost = one.input + one.cache_creation + one.cache_read
                agent_type = "(不明)"
                if file_agent_id and file_agent_id in scan.agent_id_types:
                    agent_type = scan.agent_id_types[file_agent_id]
                scan.agent_usage[agent_type] += one
                scan.agent_usage_total += one
                accepted_usage = True

        if not line_seen and since is not None:
            # 期間内行が無いファイルは「読めたログ」に入れない
            continue
        scan.sub_files += 1
        agent_type = "(不明)"
        if file_agent_id and file_agent_id in scan.agent_id_types:
            agent_type = scan.agent_id_types[file_agent_id]
        else:
            scan.sub_unresolved_logs += 1
        scan.agent_log_counts[agent_type] += 1
        if accepted_usage:
            scan.sub_files_with_usage += 1
        if fixed_cost is not None:
            scan.agent_fixed_costs.append(fixed_cost)
```

**注意:** `main()` は現在 `scan.sub_files = len(sub_paths)` としている。二重計上しないよう、その代入をやめ、この関数に任せる。

- [ ] **Step 2: `main()` の配線を更新する**

```python
    scan = scan_transcripts(main_paths, since)
    scan_subagent_transcripts(scan, sub_paths, since)
    scan.sub_mcp_calls = scan_mcp_tool_names(sub_paths, since)
```

`scan.sub_files = len(sub_paths)` 行は削除。

- [ ] **Step 3: focused テスト**

```bash
bash test/run.sh token-report
```

Expected: usage 合計系の一部はまだレポート文字列待ちで FAIL しうるが、実装後 Task 5 で GREEN にする。ここではトレースバック無し・exit 0 を確認。

- [ ] **Step 4: Commit**

```bash
git add scripts/measure-token-usage.py
git commit -m "$(cat <<'EOF'
feat: subagents/*.jsonl の message.usage を実測集計する

EOF
)"
```

---

### Task 5: `build_report` / `build_diagnostics` を新契約へ

**Files:**
- Modify: `scripts/measure-token-usage.py`
- Modify: `test/test-calibration.sh`（診断行が変わる場合のみ）

- [ ] **Step 1: 固定コスト要約ヘルパを追加する**

```python
def fixed_cost_summary(values):
    ordered = [value for value in values if isinstance(value, int) and value >= 0]
    if not ordered:
        return None
    return {
        "median": median_non_negative_integer(ordered),
        "min": min(ordered),
        "max": max(ordered),
        "count": len(ordered),
    }
```

- [ ] **Step 2: 「実測合計」節を置き換える**

`build_report` 内の subagent 行と totalTokens 行:

```python
    rows = [
        ["main", *scan.main.row()],
        ["subagent message.usage", *scan.agent_usage_total.row()],
    ]
    lines.extend(table(
        ["区分", "input", "cache_creation", "cache_read", "output", "usage合計"],
        rows,
    ))
    add(f"- main 合計: **{fmt(scan.main.total)}**")
    add(
        f"- subagent `message.usage` 合計（別枠）: **{fmt(scan.agent_usage_total.total)}**"
    )
    launches = sum(scan.agent_calls.values())
    add(f"- サブエージェント起動: {fmt(launches)}")
    add(
        f"- 読めたログ: {fmt(scan.sub_files)} 本"
        f"（うち usage あり {fmt(scan.sub_files_with_usage)} 本）"
    )
    add(f"- 型未解決ログ: {fmt(scan.sub_unresolved_logs)} 本")
    add(
        "- 注意: この区間のサブエージェント集合は完全母集団ではない。"
        "欠測分は平均値で補完しない。"
    )
    fixed = fixed_cost_summary(scan.agent_fixed_costs)
    if fixed:
        add(
            "- 起動固定コスト（各ログの初回 assistant 入力:"
            " input+cache_creation+cache_read）:"
            f" 中央値 {fmt(fixed['median'])} / 最小 {fmt(fixed['min'])}"
            f" / 最大 {fmt(fixed['max'])} / 標本数: {fmt(fixed['count'])}"
        )
        add("- 起動固定コストは診断用であり、上記 usage 合計へ二重加算しない。")
    add("")
```

旧「`toolUseResult.totalTokens` 合計」行と、旧「subagents/ の詳細ログ N 本は別枠…」だけの行は、上記カバレッジ文に統合してよい。

- [ ] **Step 3: 「モデルとサブエージェント」の型別表を置き換える**

```python
    agent_rows = []
    types = set(scan.agent_calls) | set(scan.agent_usage) | set(scan.agent_log_counts)
    for subagent in sorted(
        types,
        key=lambda item: (
            -scan.agent_usage[item].total,
            -scan.agent_calls.get(item, 0),
            item,
        ),
    ):
        usage = scan.agent_usage[subagent]
        agent_rows.append(
            [
                subagent,
                scan.agent_calls.get(subagent, 0),
                scan.agent_log_counts.get(subagent, 0),
                fmt(usage.total),
                fmt(usage.input),
                fmt(usage.cache_creation),
                fmt(usage.cache_read),
                fmt(usage.output),
            ]
        )
    lines.extend(
        table(
            [
                "subagent_type",
                "起動",
                "ログ",
                "usage合計",
                "input",
                "cache_creation",
                "cache_read",
                "output",
            ],
            top_rows(agent_rows, args.top),
        )
    )
```

- [ ] **Step 4: `build_diagnostics` の Agent 行を更新する**

`agent_total` / `agent_results` 依存をやめ:

```python
    agent_usage_total = scan.agent_usage_total.total
    agent_ratio = (agent_usage_total / float(main_total)) if main_total else 0.0
    ...
            "agent_calls": sum(scan.agent_calls.values()),
            "agent_log_files": scan.sub_files,
            "agent_total_tokens": agent_usage_total,
            "agent_main_ratio": agent_ratio,
            "agent_fixed_median": (
                fixed_cost_summary(scan.agent_fixed_costs) or {}
            ).get("median"),
```

レポート診断文:

```python
        fixed_med = measured.get("agent_fixed_median")
        add(
            "- Agent: 起動 {} 件 / ログ {} 本 / usage実測 {} / main比（usage実測） {:.1%}".format(
                fmt(measured["agent_calls"]),
                fmt(measured["agent_log_files"]),
                fmt(measured["agent_total_tokens"]),
                measured["agent_main_ratio"],
            )
        )
        if fixed_med is not None:
            add("- Agent 起動固定コスト中央値: {}".format(fmt(fixed_med)))
```

- [ ] **Step 5: calibration fixture を最小修正する**

`test/test-calibration.sh` の `_fixture_with_diagnostics` で Agent に `agentId` を付け、対応する空でないサブログを 1 本書く（usage 任意の小さい値）。`assert_contains "$report" "diagnostic-agent"` が型別表または起動言及で通るようにする。古い `totalTokens` だけの結果行は残しても合計には使われない。

診断行アサーションが `totalTokens` 文字列に依存していれば、`usage実測` へ更新する。

- [ ] **Step 6: GREEN 確認**

```bash
bash test/run.sh token-report
bash test/run.sh calibration
```

Expected: Issue #42 関連の token-report 新テストが PASS。calibration 診断も PASS。

- [ ] **Step 7: Commit**

```bash
git add scripts/measure-token-usage.py test/test-calibration.sh
git commit -m "$(cat <<'EOF'
feat: サブエージェント usage・カバレッジ・固定コストをレポートする

EOF
)"
```

---

### Task 6: README / SKILL / 基礎設計 / delegation-policy 文書更新（TDD）

**Files:**
- Modify: `test/test-delegation-policy.sh`
- Modify: `test/test-token-report-docs.sh`（文書契約の否定アサーションを足す）
- Modify: `README.md`
- Modify: `skills/token-report/SKILL.md`
- Modify: `skills/delegation-policy/SKILL.md`
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md`

- [ ] **Step 1: 文書テストを先に RED 化する**

`test/test-delegation-policy.sh` の `test_数値とモデル名を普遍化しない`:

```bash
test_数値とモデル名を普遍化しない() {
  local body
  body="$(_skill_text)"
  assert_not_contains "$body" "直接測定していない" "旧・未測定文言の除去"
  assert_contains "$body" "token-report" "実測参考の参照"
  assert_contains "$body" "環境" "環境固有"
  assert_contains "$body" "固定の損益分岐点" "固定閾値禁止"
  assert_contains "$body" "モデル名" "モデル名非固定"
  assert_contains "$body" "価格" "価格非固定"
  assert_contains "$body" "固定トークン数" "トークン数非固定"
}
```

`test/test-token-report-docs.sh` へ追加:

```bash
test_固定コスト未測定とtotalTokens主指標を文書から除く() {
  readme="$(cat "$REPO_ROOT/README.md")"
  skill="$(_skill)"
  design="$(_design_token_report_section)"
  combined="${readme}
${skill}
${design}"
  assert_not_contains "$combined" "直接測定していない" "未測定文言除去"
  assert_not_contains "$combined" "toolUseResult.totalTokens" "totalTokens 主指標除去"
  assert_contains "$readme" "message.usage" "README sub 実測"
  assert_contains "$skill" "起動固定コスト" "SKILL 固定コスト"
  assert_contains "$design" "完全母集団ではない" "設計のカバレッジ限界"
}
```

```bash
bash test/run.sh delegation-policy
bash test/run.sh token-report-docs
```

Expected: 新断言で RED。

- [ ] **Step 2: `skills/delegation-policy/SKILL.md` 判断順序 3 を置換**

```markdown
3. **起動・指示の受け渡し・結果の読解・統合の固定費**を見積もる。token-report が出す起動固定コストの実測値（その環境・期間）を参考にしてよい。それでも普遍の損益分岐点やモデル名・価格規則にはしない。
```

段階4節の「モデル名、価格、固定トークン数を規則にせず」は維持。旧「直接測定していない」は削除。

- [ ] **Step 3: `skills/token-report/SKILL.md`**

読み方:

```markdown
- 「実測合計」は main session と subagent `message.usage` を別枠で見る
- サブエージェント節のカバレッジ（起動数 / ログ本数 / 欠測注意）と起動固定コスト（中央値・最小・最大・標本数）を読む
- 「モデルとサブエージェント」は join 済み `subagent_type`（および `(不明)` / `(既定)`）ごとの起動・ログ・usage を見る
```

限界:

```markdown
- サブエージェント消費の主合計は `subagents/*.jsonl` の `message.usage` のみである（親の `toolUseResult.totalTokens` は使わない）
- 起動固定コストは各サブログの初回 assistant 入力から実測するが、usage 合計へ二重加算しない
- 期間内のサブエージェント集合は完全母集団ではない。欠測分は平均値で補完しない
- `cache_read_input_tokens` は課金上の重みが不明なので、内訳のまま表示し、加重しない
- 画像の消費は現在の計測エンジンでは未計測である
- MCP サーバごとのトークン消費は実測できない。分かるのは設定済みか、呼ばれたか、何回かまで
```

旧「サブエージェント起動の固定コストは直接測定していない」は削除。

- [ ] **Step 4: `README.md`**

見られるもの:

```markdown
- モデル別 usage、subagent_type ごとの起動数 / ログ本数 / `message.usage` 合計
- サブエージェントのカバレッジ注意と起動固定コスト（中央値・最小・最大・標本数）
```

数値についての断り:

```markdown
- **サブエージェント起動固定コストは各 `subagents/*.jsonl` の初回 assistant 入力から実測する。** 値はその環境・期間の参考であり、普遍の損益分岐点ではない。usage 合計へ二重加算しない。
- サブエージェント消費の主合計は `subagents/*.jsonl` の `message.usage` である。親の `toolUseResult.totalTokens` は同期回収分に偏るため使わない。期間内集合は完全母集団ではない。
```

delegation-policy 節の「起動固定費は直接測定していないため、…」を:

```markdown
token-report が出す起動固定コストの実測値をその環境・期間の参考にしてよいが、固定の損益分岐点、モデル名、価格、固定トークン数を規則として置かない。
```

- [ ] **Step 5: `docs/specs/2026-07-31-claude-token-saver-design.md`**

§5.2 含め・限界:

```markdown
- モデル名、`subagent_type`（join 済み。未解決は `(不明)`）、subagent `message.usage`
```

```markdown
- サブエージェント消費の主合計は `<session>/subagents/**/*.jsonl` の `message.usage` のみとし、親の `toolUseResult.totalTokens` は合計に使わない
- 起動固定コストは各サブログの初回 assistant 入力から実測し、usage 合計へ二重加算しない
- 期間内のサブエージェント集合は完全母集団ではない。欠測分は平均値で補完しない
```

§5.4 相当の delegation 文（「起動固定費は直接測定していないため…」）を Step 2 と同じ趣旨へ置換。

- [ ] **Step 6: GREEN**

```bash
bash test/run.sh delegation-policy
bash test/run.sh token-report-docs
bash test/run.sh token-report
```

Expected: すべて PASS。

- [ ] **Step 7: Commit**

```bash
git add README.md skills/token-report/SKILL.md skills/delegation-policy/SKILL.md \
  docs/specs/2026-07-31-claude-token-saver-design.md \
  test/test-delegation-policy.sh test/test-token-report-docs.sh
git commit -m "$(cat <<'EOF'
docs: サブエージェント実測と起動固定コストの文書契約を更新する

EOF
)"
```

---

### Task 7: `expected-min-count` と全件検証

**Files:**
- Modify: `test/expected-min-count`

- [ ] **Step 1: 件数を実測して台帳を更新する**

想定差分（実装時に `grep -c '^test_.*()'` で再確認すること）:

| ファイル | 旧 | 新 | 差分 |
| --- | --- | --- | --- |
| `test-token-report.sh` | 19 | 27 | +8（置換1 + 新規 roughly 8、旧1削除なら net +8） |
| `test-token-report-docs.sh` | 8 | 9 | +1 |
| `test-delegation-policy.sh` | 17 | 17 | 0（中身変更のみ） |
| `test-calibration.sh` | 21 | 21 | 0（fixture/断言のみ） |
| 総件数 | 625 | 634 | +9 |

`expected-min-count` 例:

```
634
skip-max 5
...
test-token-report.sh 27
...
test-token-report-docs.sh 9
...
```

実装後に `bash test/run.sh` の「実行件数」と一致するよう必ず実測値に合わせる（詐欺防止の台帳なので推測のまま残さない）。

- [ ] **Step 2: 検証コマンド（必須）**

```bash
python3 -m py_compile scripts/measure-token-usage.py
bash test/run.sh token-report
bash test/run.sh token-report-docs
bash test/run.sh delegation-policy
bash test/run.sh calibration
CTS_NO_SKIP=1 bash test/run.sh
```

Expected:

- py_compile 成功
- focused スイート失敗 0
- フルスイート失敗 0、実行件数 ≥ `expected-min-count` 総件数

- [ ] **Step 3: Commit**

```bash
git add test/expected-min-count
git commit -m "$(cat <<'EOF'
test: Issue #42 に合わせて expected-min-count を更新する

EOF
)"
```

- [ ] **Step 4: 設計書の状態更新（任意）**

`docs/superpowers/specs/2026-08-06-issue-42-subagent-usage-design.md` の状態を `実装・検証済み` に更新してよい（ユーザーが求めれば別コミット）。

---

### Task 8: PR 境界（ユーザー承認後のみ）

- [ ] 1. `git diff main...HEAD` が File map の範囲であること、#39/#40/#41 混入が無いことを確認する。
- [ ] 2. 無関係 dirty ファイルをコミットしていないことを `git status` で確認する。
- [ ] 3. ユーザー承認後だけ push と `gh pr create`（`Closes #42`）。
- [ ] 4. merge はユーザーへ依頼して停止する。**承認前に push しない。**

---

## Spec coverage checklist

| Spec 要件 | Task |
| --- | --- |
| sub 消費源泉 = `subagents/**/*.jsonl` の `message.usage` | Task 4–5 |
| `totalTokens` / `toolUseResult.usage` を合計へ入れない | Task 1, 3, 5 |
| main へ sub usage を混ぜない | Task 1, 4–5 |
| 側内 `message.id` 重複排除 / 側間 ID 非結合 | Task 4（`("sub", ...)` キー） |
| 親 Agent 自身の usage は main | 変更なし（Task 3 で維持） |
| 固定コスト非加算 | Task 2, 5 |
| 起動数 = 親 Agent `tool_use` | Task 2–3, 5 |
| agentId join + `(不明)` / `(既定)` 区別 | Ambiguity + Task 2–4 |
| カバレッジ・欠測注意・補完禁止 | Task 2, 5 |
| 型別表 起動/ログ/usage | Task 5 |
| 固定コスト中央値/最小/最大/標本数 | Task 2, 5 |
| calibrate 診断追随 | Task 5 |
| README / token-report / delegation-policy / 基礎設計 | Task 6 |
| §6 テスト 1–10 | Task 1–2, 5–6 |
| `expected-min-count` | Task 7 |
| #41 非対象 / push 承認後 | Global Constraints, Task 8 |
| TDD | Task 1–2 RED → 3–5 GREEN → 6 docs |

## Self-review notes

- Placeholders（TBD /「適切に」）は置かない。agentId join・カバレッジ文言・期待トークン値を Ambiguity / fixture で固定済み。
- `Scan` から `agent_total` 等を削除したら、旧参照を Task 5 で必ず消す（`rg agent_total|agent_tokens|agent_results|agent_models|agent_max`）。
- fixture の all-time 合計 `81,323` 系は **main のみ**の契約。sub usage を main に足していないことを回帰で守る。
- `test_表示メタデータとMarkdown表を安全化する` は adversarial `toolUseResult` の agentType が type 表へ出ないこと（totalTokens 経路削除後）を確認。出るなら launch 経由でない限り `(不明)` にも載せない。
