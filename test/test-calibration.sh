#!/usr/bin/env bash
# セッション別usage集計と中央値の基礎を、CLIを介さず検証する。

set -u

_fixture_with_sessions() {
  FIXTURE_TRANSCRIPT="$TEST_TMP/sessions.jsonl"
  python3 - "$FIXTURE_TRANSCRIPT" "$@" <<'PYEOF'
import json
import sys

path = sys.argv[1]
values = [int(value) for value in sys.argv[2:]]
with open(path, "w", encoding="utf-8") as handle:
    for index, cache_read in enumerate(values):
        row = {
            "type": "assistant",
            "sessionId": "session-{}".format(index),
            "message": {
                "id": "message-{}".format(index),
                "usage": {
                    "input_tokens": 1,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": cache_read,
                    "output_tokens": 1,
                },
                "content": [],
            },
        }
        handle.write(json.dumps(row) + "\n")
PYEOF
}

_fixture_with_missing_session_id() {
  FIXTURE_TRANSCRIPT="$TEST_TMP/missing-session.jsonl"
  python3 - "$FIXTURE_TRANSCRIPT" <<'PYEOF'
import json
import sys

row = {
    "type": "assistant",
    "message": {
        "id": "message-without-session",
        "usage": {
            "input_tokens": 1,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 10,
            "output_tokens": 1,
        },
        "content": [],
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(json.dumps(row) + "\n")
PYEOF
}

_fixture_with_duplicate_session_events() {
  FIXTURE_TRANSCRIPT="$TEST_TMP/duplicate-session.jsonl"
  python3 - "$FIXTURE_TRANSCRIPT" <<'PYEOF'
import json
import sys

def row(message_id, cache_read):
    return {
        "type": "assistant",
        "sessionId": "session-duplicate",
        "message": {
            "id": message_id,
            "usage": {
                "input_tokens": 1,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": cache_read,
                "output_tokens": 1,
            },
            "content": [],
        },
    }

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(json.dumps(row("message-once", 10)) + "\n")
    handle.write(json.dumps(row("message-once", 10)) + "\n")
    handle.write(json.dumps(row("message-twice", 20)) + "\n")
PYEOF
}

_fixture_with_zero_compact_baseline() {
  FIXTURE_TRANSCRIPT="$TEST_TMP/zero-compact.jsonl"
  python3 - "$FIXTURE_TRANSCRIPT" <<'PYEOF'
import json
import sys

def assistant(message_id, cache_read):
    return {
        "type": "assistant",
        "sessionId": "session-zero-compact",
        "message": {
            "id": message_id,
            "usage": {
                "input_tokens": 1,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": cache_read,
                "output_tokens": 1,
            },
            "content": [],
        },
    }

rows = [assistant("before-0", 0), assistant("before-1", 0), assistant("before-2", 100)]
rows.append({
    "type": "user",
    "sessionId": "session-zero-compact",
    "message": {"role": "user", "content": "/compact"},
})
rows.append(assistant("after-0", 0))

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    for row in rows:
        handle.write(json.dumps(row) + "\n")
PYEOF
}

_run_python_harness() {
  mode="$1"
  shift
  python3 - "$REPO_ROOT/scripts/measure-token-usage.py" "$mode" "$@" <<'PYEOF'
import runpy
import sys

engine_path, mode = sys.argv[1:3]
module = runpy.run_path(engine_path)
if mode == "median":
    values = [int(value) for value in sys.argv[3:]]
    print(module["median_integer"](values))
elif mode == "percentile":
    percentile = int(sys.argv[3])
    values = []
    for token in sys.argv[4:]:
        if token == "None":
            values.append(None)
        else:
            values.append(int(token))
    result = module["percentile_integer"](values, percentile)
    print("None" if result is None else result)
elif mode == "compact":
    scan = module["scan_transcripts"]([sys.argv[3]], None)
    event = scan.compact_events[0]
    print("{},{},{}".format(
        event["pre_compact_baseline"],
        event["post_compact_usage"],
        event["recovery_turns"],
    ))
elif mode == "session_count":
    scan = module["scan_transcripts"]([sys.argv[3]], None)
    print(len(scan.session_stats))
elif mode == "session_stats":
    scan = module["scan_transcripts"]([sys.argv[3]], None)
    stats = scan.session_stats[sys.argv[4]]
    print("{},{}".format(stats.cache_read, stats.assistant_turns))
elif mode == "prompt_key":
    print(module["calibration_prompt_key"](*[int(value) for value in sys.argv[3:7]]))
elif mode == "sync_state":
    root = sys.argv[3]
    stats = {}
    for index in range(5):
        session = module["SessionStats"]()
        session.cache_read = 200
        session.assistant_turns = 20
        stats["sync-session-{}".format(index)] = session
    result = module["sync_calibration_state"](root, stats, 5, 100, root)
    print("1" if result else "0")
else:
    raise SystemExit("unknown harness mode")
PYEOF
}

test_外れ値を中央値から除外する() {
  output="$(_run_python_harness median 10 20 30 40 1000)"
  assert_eq "30" "$output" "中央値"
}

test_偶数サンプルは中央二値の整数平均を切り捨てる() {
  output="$(_run_python_harness median 10 20 40 1000)"
  assert_eq "30" "$output" "偶数中央値"
}

test_percentile_integerはnearest_rankで整数を返す() {
  output="$(_run_python_harness percentile 75 10 20 30 40 1000)"
  assert_eq "40" "$output" "p75 nearest-rank"
  output="$(_run_python_harness percentile 50 10 20 40 1000)"
  assert_eq "20" "$output" "p50 nearest-rank"
  output="$(_run_python_harness percentile 75)"
  assert_eq "None" "$output" "空配列"
  output="$(_run_python_harness percentile 75 0 -1 10 20)"
  assert_eq "20" "$output" "非正値除外"
}

test_ゼロを含むcompact基準とゼロ回復を記録する() {
  _fixture_with_zero_compact_baseline
  output="$(_run_python_harness compact "$FIXTURE_TRANSCRIPT")"
  assert_eq "0,0,1" "$output" "zero compact基準と回復"
}

test_sessionIdが無いusageをサンプル数へ入れない() {
  _fixture_with_missing_session_id
  output="$(_run_python_harness session_count "$FIXTURE_TRANSCRIPT")"
  assert_eq "0" "$output" "不明sessionの除外"
}

test_session_statsがcache_readとassistant_turnsを集計する() {
  _fixture_with_sessions 10 20
  output="$(_run_python_harness session_stats "$FIXTURE_TRANSCRIPT" session-0)"
  assert_eq "10,1" "$output" "通常sessionの統計"
}

test_session_statsは同一sessionの重複usageを一度だけ数える() {
  _fixture_with_duplicate_session_events
  output="$(_run_python_harness session_stats "$FIXTURE_TRANSCRIPT" session-duplicate)"
  assert_eq "30,2" "$output" "重複排除後のsession統計"
}

test_calibration_prompt_keyはshellと同じ形式を返す() {
  output="$(_run_python_harness prompt_key 5 100 5 100)"
  assert_eq "5-100-5-100" "$output" "Pythonとshellのprompt key"
}

test_sync_calibration_stateはsession_ledgerとstateを共有する() {
  sync_root="$TEST_TMP/python-sync-root"
  mkdir -p "$sync_root"
  output="$(_run_python_harness sync_state "$sync_root")"
  assert_eq "1" "$output" "Python側のprompt判定"
  sessions="$sync_root/.token-saver/calibration/sessions.tsv"
  state="$sync_root/.token-saver/calibration/state"
  assert_file_exists "$sessions" "Python側session ledger"
  assert_file_exists "$state" "Python側prompt state"
  assert_count "5" "$(cat "$sessions")" $'\t20\t' "Python側assistant turns"
  assert_contains "$(cat "$state")" "prompted_key=5-100-5-100" "Python側prompt key"
}

_fixture_with_calibration_data() {
  session_count="$1"
  assistant_turns="$2"
  min_sessions="${3:-}"
  min_assistant_turns="${4:-}"
  cache_read="${5:-10}"
  percentile="${6:-}"
  exclude_below="${7:-}"
  FIXTURE_HOME="$TEST_TMP/calibration-home"
  FIXTURE_REPO="$TEST_TMP/calibration-repo"
  FIXTURE_REPORT="$TEST_TMP/calibration-report.md"
  mkdir -p "$FIXTURE_HOME/.claude/projects" "$FIXTURE_REPO/.git" "$FIXTURE_REPO/.claude"

  python3 - "$FIXTURE_HOME" "$FIXTURE_REPO" "$session_count" "$assistant_turns" \
    "$min_sessions" "$min_assistant_turns" "$cache_read" "$percentile" "$exclude_below" <<'PYEOF'
import json
import os
import sys
from datetime import datetime, timezone

(
    home,
    repo,
    session_count,
    assistant_turns,
    min_sessions,
    min_assistant_turns,
    cache_read,
    percentile,
    exclude_below,
) = sys.argv[1:]
session_count = int(session_count)
assistant_turns = int(assistant_turns)
cache_read = int(cache_read)
key = "".join(char if char.isascii() and char.isalnum() else "-" for char in repo)
project = os.path.join(home, ".claude", "projects", key)
os.makedirs(project)
stamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
with open(os.path.join(project, "calibration.jsonl"), "w", encoding="utf-8") as handle:
    for index in range(assistant_turns):
        session = "session-{}".format(index % session_count)
        row = {
            "type": "assistant",
            "timestamp": stamp,
            "sessionId": session,
            "message": {
                "id": "message-{}".format(index),
                "usage": {
                    "input_tokens": 1,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": cache_read,
                    "output_tokens": 1,
                },
                "content": [],
            },
        }
        handle.write(json.dumps(row) + "\n")

config = {
    "suggest_session_cut": {
        "initial_cache_read": 111,
        "increment_cache_read": 222,
        "keep": "unchanged",
    }
}
calibration = {}
if min_sessions and min_assistant_turns:
    calibration["min_sessions"] = int(min_sessions)
    calibration["min_assistant_turns"] = int(min_assistant_turns)
if percentile:
    calibration["percentile"] = int(percentile)
if exclude_below != "":
    calibration["exclude_below_assistant_turns"] = int(exclude_below)
if calibration:
    config["calibration"] = calibration
with open(os.path.join(repo, ".claude", "token-saver.json"), "w", encoding="utf-8") as handle:
    json.dump(config, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PYEOF
}

_run_calibrate() {
  (
    cd "$FIXTURE_REPO" &&
      HOME="$FIXTURE_HOME" CLAUDE_CONFIG_DIR="$FIXTURE_HOME/.claude" \
      python3 -B "$REPO_ROOT/scripts/measure-token-usage.py" --calibrate --days 0 --out "$FIXTURE_REPORT"
  )
}

_fixture_with_diagnostics() {
  FIXTURE_HOME="$TEST_TMP/diagnostics-home"
  FIXTURE_REPO="$TEST_TMP/diagnostics-repo"
  FIXTURE_REPORT="$TEST_TMP/diagnostics-report.md"
  mkdir -p "$FIXTURE_HOME/.claude/projects" "$FIXTURE_REPO/.git" "$FIXTURE_REPO/.claude"

  python3 - "$FIXTURE_HOME" "$FIXTURE_REPO" <<'PYEOF'
import json
import os
import sys
from datetime import datetime, timedelta, timezone

home, repo = sys.argv[1:]
project = os.path.join(home, ".claude", "projects", "".join(
    char if char.isascii() and char.isalnum() else "-" for char in repo
))
os.makedirs(project)
now = datetime.now(timezone.utc)
counter = [0]

def stamp():
    value = now + timedelta(seconds=counter[0])
    counter[0] += 1
    return value.isoformat().replace("+00:00", "Z")

def usage(cache_read):
    return {
        "input_tokens": 1,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": cache_read,
        "output_tokens": 1,
    }

def assistant(session, message_id, cache_read, content=None):
    return {
        "type": "assistant",
        "timestamp": stamp(),
        "sessionId": session,
        "message": {
            "id": message_id,
            "model": "claude-sonnet-5",
            "usage": usage(cache_read),
            "content": content or [],
        },
    }

rows = []
for session, values in (
    ("session-normal-a", [100, 100, 100]),
    ("session-normal-b", [100, 100, 100]),
    ("session-heavy", [600, 600, 600]),
    ("session-normal-c", [100, 100, 100]),
):
    for index, cache_read in enumerate(values):
        rows.append(assistant(session, "{}-{}".format(session, index), cache_read))

# 直前3ターンの中央値は110。圧縮直後の50から、2ターン目の105で90%以上へ戻る。
for index, cache_read in enumerate((100, 120, 110)):
    rows.append(assistant("session-compact", "compact-before-{}".format(index), cache_read))
rows.append({
    "type": "user",
    "timestamp": stamp(),
    "sessionId": "session-compact",
    "message": {"role": "user", "content": "/compact"},
})
rows.append(assistant("session-compact", "compact-after-0", 50))
rows.append(assistant("session-compact", "compact-after-1", 105))
# assistant message内の/compactはイベントではない。
rows.append(assistant(
    "session-compact", "assistant-compact-text", 100,
    [{"type": "text", "text": "/compact"}],
))

# 大きいmain tool_resultはtool_useと同じセッションの後続usageへ対応付ける。
rows.append(assistant(
    "session-normal-a", "heavy-tool-use", 100,
    [{"type": "tool_use", "id": "heavy-tool", "name": "Read",
      "input": {"file_path": repo + "/EXTERNAL_PATH_SENTINEL"}},
     {"type": "tool_use", "id": "mcp-used", "name": "mcp__used_server__run",
      "input": {"argument": "MCP_INPUT_SECRET"}},
     {"type": "tool_use", "id": "mcp-unknown", "name": "mcp__unknown_server__run",
      "input": {"argument": "MCP_UNKNOWN_INPUT_SECRET"}},
     {"type": "tool_use", "id": "agent-call", "name": "Agent",
      "input": {"subagent_type": "diagnostic-agent",
                "agentId": "agent-diagnostic-1",
                "prompt": "PROMPT_BODY_SENTINEL"}}],
))
rows.append({
    "type": "user",
    "timestamp": stamp(),
    "sessionId": "session-normal-a",
    "requestId": "request-heavy",
    "message": {"role": "user", "content": [{
        "type": "tool_result", "tool_use_id": "heavy-tool",
        "content": [{"type": "text", "text": "秘密のtool result本文 " + "x" * 5000}],
    }]},
})
heavy_follow_up = assistant("session-normal-a", "heavy-tool-follow-up", 100)
heavy_follow_up["requestId"] = "request-heavy"
rows.append(heavy_follow_up)
rows.append({
    "type": "user",
    "timestamp": stamp(),
    "sessionId": "session-normal-a",
    "toolUseResult": {"agentType": "diagnostic-agent",
                      "agentId": "agent-diagnostic-1",
                      "totalTokens": 120},
    "message": {"role": "user", "content": "tool result detail"},
})

# usage対応のないtool_resultも記録し、実測値として誤って埋めない。
rows.append({
    "type": "user",
    "timestamp": stamp(),
    "sessionId": "session-unmatched",
    "message": {"role": "user", "content": [{
        "type": "tool_result", "tool_use_id": "unmatched-tool",
        "content": [{"type": "text", "text": "未対応tool result本文 SENTINEL " + "y" * 5000}],
    }]},
})

# requestId/sessionが一致しても、usageなしassistantは対応付けない。
rows.append({
    "type": "user",
    "timestamp": stamp(),
    "sessionId": "session-unmatched",
    "requestId": "request-without-usage",
    "message": {"role": "user", "content": [{
        "type": "tool_result", "tool_use_id": "unmatched-tool-with-request",
        "content": [{"type": "text", "text": "未対応tool result本文2 SENTINEL " + "z" * 5000}],
    }]},
})
rows.append({
    "type": "assistant",
    "timestamp": stamp(),
    "sessionId": "session-unmatched",
    "requestId": "request-without-usage",
    "message": {
        "id": "assistant-without-usage",
        "model": "claude-sonnet-5",
        "content": [],
    },
})

plugin_root = os.path.join(home, "enabled-plugin")
os.makedirs(os.path.join(plugin_root, ".claude-plugin"))
with open(os.path.join(plugin_root, ".claude-plugin", "plugin.json"), "w", encoding="utf-8") as handle:
    json.dump({"mcpServers": ".mcp.json"}, handle)
with open(os.path.join(plugin_root, ".mcp.json"), "w", encoding="utf-8") as handle:
    json.dump({"mcpServers": {
        "plugin_server": {
            "command": "node",
            "args": ["PLUGIN_DEFINITION_SENTINEL"],
        },
    }}, handle)
os.makedirs(os.path.join(home, ".claude", "plugins"))
with open(os.path.join(home, ".claude", "plugins", "installed_plugins.json"), "w", encoding="utf-8") as handle:
    json.dump({"plugins": {
        "demo-plugin@1.0.0": [{
            "scope": "user",
            "installPath": plugin_root,
            "installedAt": "2026-08-04T00:00:00Z",
        }],
    }}, handle)
with open(os.path.join(home, ".claude", "settings.json"), "w", encoding="utf-8") as handle:
    json.dump({"enabledPlugins": {"demo-plugin@1.0.0": True}}, handle)

rows.append({
    "type": "user",
    "timestamp": stamp(),
    "sessionId": "session-compact",
    "message": {"role": "user", "content": [{"type": "text", "text": "/compact"}]},
})

with open(os.path.join(project, "diagnostics.jsonl"), "w", encoding="utf-8") as handle:
    for row in rows:
        handle.write(json.dumps(row, ensure_ascii=False) + "\n")

sub_dir = os.path.join(project, "diagnostics", "subagents")
os.makedirs(sub_dir, exist_ok=True)
with open(os.path.join(sub_dir, "agent-diagnostic-1.jsonl"), "w", encoding="utf-8") as handle:
    handle.write(json.dumps({
        "type": "assistant",
        "timestamp": stamp(),
        "agentId": "agent-diagnostic-1",
        "message": {
            "id": "sub-diagnostic-1",
            "model": "sub-model",
            "usage": {
                "input_tokens": 10,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0,
                "output_tokens": 5,
            },
            "content": [],
        },
    }, ensure_ascii=False) + "\n")

with open(os.path.join(repo, ".claude", "token-saver.json"), "w", encoding="utf-8") as handle:
    json.dump({
        "calibration": {"min_sessions": 5, "min_assistant_turns": 17},
        "suggest_session_cut": {"initial_cache_read": 111, "increment_cache_read": 222},
    }, handle, ensure_ascii=False)

with open(os.path.join(home, ".claude.json"), "w", encoding="utf-8") as handle:
    json.dump({"mcpServers": {
        "unused_server": {"command": "node", "args": ["MCP_UNUSED_INPUT_SECRET"],
                           "env": {"MCP_UNUSED_ENV_SECRET": "hidden"}},
        "used_server": {"command": "node", "args": ["MCP_USED_INPUT_SECRET"]},
        "unknown-server": {"command": "node"},
        "unknown_server": {"command": "node", "url": "/external/MCP_PATH_SECRET"},
    }}, handle, ensure_ascii=False)
PYEOF
}

test_実測診断と概算診断を分離する() {
  _fixture_with_diagnostics
  _run_calibrate >/dev/null
  report="$(cat "$FIXTURE_REPORT")"
  assert_contains "$report" "## 実測診断" "実測節"
  assert_contains "$report" "## 概算診断" "概算節"
  assert_contains "$report" "超過セッション" "超過session"
  assert_contains "$report" "tool_result" "heavy tool_result"
  assert_contains "$report" "usage対応あり" "対応usageあり"
  assert_contains "$report" "usage対応なし" "対応usageなし"
  assert_contains "$report" "compact" "compact診断"
  assert_contains "$report" "/compact 発生: 2 件" "compact形式"
  assert_contains "$report" "回復ターン数: 2" "compact回復"
  assert_contains "$report" "未回復" "compact未回復"
  assert_contains "$report" "unused_server" "未使用MCP"
  assert_contains "$report" "used_server" "利用済みMCP"
  assert_contains "$report" "unknown-server" "判定不能MCP"
  assert_contains "$report" "diagnostic-agent" "Agent診断"
  assert_contains "$report" "画像入力のトークン消費は未計測" "画像境界"
  assert_contains "$report" "定義バイト数 ÷ 4 の概算" "MCP概算根拠"
  assert_not_contains "$report" "PROMPT_BODY_SENTINEL" "prompt秘匿"
  assert_not_contains "$report" "秘密のtool result本文" "tool result本文秘匿"
  assert_not_contains "$report" "MCP_INPUT_SECRET" "MCP入力秘匿"
  assert_not_contains "$report" "EXTERNAL_PATH_SENTINEL" "外部path秘匿"
  assert_not_contains "$report" "MCP_PATH_SECRET" "MCP定義path秘匿"
  measured="${report%%## 概算診断*}"
  assert_not_contains "$measured" "概算トークン" "概算値の実測混入"
}

test_assistantのcompact本文は発生数に含めない() {
  _fixture_with_diagnostics
  _run_calibrate >/dev/null
  assert_contains "$(cat "$FIXTURE_REPORT")" "/compact 発生: 2 件" \
    "assistant本文のcompact除外"
}

test_usageなしassistantはtool_result対応付けをしない() {
  _fixture_with_diagnostics
  _run_calibrate >/dev/null
  report="$(cat "$FIXTURE_REPORT")"
  assert_count 1 "$report" "usage対応あり" "usage受理済みのみ対応"
  assert_count 2 "$report" "usage対応なし" "usageなしassistantの未対応"
}

test_enabled_pluginのMCPを分類と概算へ含める() {
  _fixture_with_diagnostics
  _run_calibrate >/dev/null
  report="$(cat "$FIXTURE_REPORT")"
  measured="${report%%## 概算診断*}"
  estimated="${report#*## 概算診断}"
  assert_contains "$measured" "未使用MCP: unused_server, plugin_server" "plugin MCP分類"
  assert_contains "$estimated" "| plugin:demo-plugin | plugin_server |" "plugin MCP概算行"
  assert_not_contains "$report" "PLUGIN_DEFINITION_SENTINEL" "plugin定義内容の秘匿"
}

test_既定の5セッション100ターン未満は促さない() {
  _fixture_with_calibration_data 4 99
  _run_calibrate >/dev/null
  report="$(cat "$FIXTURE_REPORT")"
  assert_contains "$report" "判定: **サンプル不足**" "不足判定"
  assert_not_contains "$report" "推奨段階1単位" "不足時の推奨抑止"
}

test_設定で必要数を変更できる() {
  _fixture_with_calibration_data 2 3 2 3 10 "" 0
  _run_calibrate >/dev/null
  assert_contains "$(cat "$FIXTURE_REPORT")" "判定: **算出可能**" "設定閾値"
}

test_算出可能なら中央値と現在値をレポートする() {
  _fixture_with_calibration_data 5 100
  _run_calibrate >/dev/null
  report="$(cat "$FIXTURE_REPORT")"
  assert_contains "$report" "算出日:" "算出日時"
  assert_contains "$report" "推奨段階1単位: **200** cache_read" "段階1推奨値"
  assert_contains "$report" "推奨段階2: 400 cache_read" "段階2推奨値"
  assert_contains "$report" "推奨段階3: 600 cache_read" "段階3推奨値"
  assert_contains "$report" "現在値: initial 111 / increment 222 cache_read" "現在値"
}

test_不正なcalibration設定は各項目を既定値へ戻す() {
  _fixture_with_calibration_data 2 3 2 3 10 "" 0
  cat >"$FIXTURE_REPO/.claude/token-saver.json" <<'EOF'
{
  "calibration": {
    "min_sessions": 0,
    "min_assistant_turns": 0,
    "exclude_below_assistant_turns": 0
  },
  "suggest_session_cut": {
    "initial_cache_read": 111,
    "increment_cache_read": 222
  }
}
EOF
  _run_calibrate >/dev/null
  assert_contains "$(cat "$FIXTURE_REPORT")" "判定: **サンプル不足**" "不正設定の既定値"
  assert_contains "$(cat "$FIXTURE_REPORT")" "セッション数 2 件（必要 5 件）" "不正session閾値"
  assert_contains "$(cat "$FIXTURE_REPORT")" "assistant ターン 3 件（必要 100 件）" "不正turn閾値"
}

test_calibrateはtoken_saver_configを書き換えずsnapshotを保存する() {
  _fixture_with_calibration_data 5 100 5 100
  python3 - "$FIXTURE_REPO/.claude/token-saver.json" <<'PYEOF'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    config = json.load(handle)
config["calibration"]["private_note"] = "SECRET_SENTINEL"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(config, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PYEOF
  status=$?
  assert_eq "0" "$status" "秘密fixtureの設定"
  before="$(cat "$FIXTURE_REPO/.claude/token-saver.json")"
  _run_calibrate >/dev/null
  snapshot="$FIXTURE_REPO/.token-saver/calibration/latest.json"
  assert_eq "$before" "$(cat "$FIXTURE_REPO/.claude/token-saver.json")" "自動適用禁止"
  [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || _fail "snapshot が通常ファイルでない"
  [ -s "$snapshot" ] || _fail "snapshot が空である"
  snapshot_json="$(cat "$snapshot")"
  assert_contains "$snapshot_json" '"eligible": true' "snapshot判定"
  assert_contains "$snapshot_json" '"period": "全期間"' "snapshot対象期間"
  assert_contains "$snapshot_json" '"generated_at":' "snapshot算出日時"
  assert_contains "$snapshot_json" '"min_sessions": 5' "snapshot必要session数"
  assert_contains "$snapshot_json" '"min_assistant_turns": 100' "snapshot必要turn数"
  assert_contains "$snapshot_json" '"session_count": 5' "snapshotsession数"
  assert_contains "$snapshot_json" '"assistant_turns": 100' "snapshotturn数"
  assert_contains "$snapshot_json" '"baseline_cache_read"' "snapshot推奨値"
  assert_contains "$snapshot_json" '"current_initial": 111' "snapshot現在initial"
  assert_contains "$snapshot_json" '"current_increment": 222' "snapshot現在increment"
  assert_contains "$snapshot_json" '"recommended_levels": [200, 400, 600]' "snapshot推奨段階"
  assert_contains "$snapshot_json" '"source":' "snapshot算出元"
  assert_contains "$snapshot_json" '"fingerprint":' "snapshot識別情報"
  assert_not_contains "$snapshot_json" "$FIXTURE_REPO" "snapshotのrepo実パス"
  assert_not_contains "$snapshot_json" "SECRET_SENTINEL" "snapshotの秘密値"
  snapshot_schema="$(python3 - "$snapshot" <<'PYEOF'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["period"] == "全期間"
assert data["baseline_cache_read"] == 200
assert data["current_initial"] == 111
assert data["current_increment"] == 222
assert data["recommended_levels"] == [200, 400, 600]
assert data["source"] == "メインセッションの重複排除後 cache_read p75（assistant_turns>=3 を母集団）"
assert data["percentile"] == 75
assert data["exclude_below_assistant_turns"] == 3
assert data["sample_session_count"] == 5
assert data["total_session_count"] == 5
assert data["excluded_session_count"] == 0
assert data["distribution"]["p75"] == 200
assert data["concentration"]["top_n"] == 3
assert "session" not in json.dumps(data["concentration"])
assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z", data["generated_at"])
assert re.fullmatch(r"[0-9a-f]{64}", data["fingerprint"])
print("schema-ok")
PYEOF
)"
  assert_eq "schema-ok" "$snapshot_schema" "snapshot値と形式"
}

test_cache_readの有効サンプルが無ければ推奨を出さない() {
  _fixture_with_calibration_data 5 100 "" "" 0
  _run_calibrate >/dev/null
  report="$(cat "$FIXTURE_REPORT")"
  assert_contains "$report" "判定: **サンプル不足**" "zero cache_read判定"
  assert_not_contains "$report" "推奨段階1単位" "zero cache_read時の推奨抑止"
}

test_configディレクトリsymlinkを追従せず既定値へ戻す() {
  _fixture_with_calibration_data 2 3
  external_config="$TEST_TMP/external-config"
  mkdir -p "$external_config"
  cat >"$external_config/token-saver.json" <<'EOF'
{
  "calibration": { "min_sessions": 2, "min_assistant_turns": 3 }
}
EOF
  rm -f "$FIXTURE_REPO/.claude/token-saver.json"
  rmdir "$FIXTURE_REPO/.claude"
  ln -s "$external_config" "$FIXTURE_REPO/.claude"
  _run_calibrate >/dev/null
  assert_contains "$(cat "$FIXTURE_REPORT")" "判定: **サンプル不足**" \
    "config symlinkの既定値"
}

test_snapshotディレクトリsymlinkを追従せず失敗する() {
  _fixture_with_calibration_data 5 100
  external_snapshot="$TEST_TMP/external-snapshot"
  mkdir -p "$external_snapshot"
  ln -s "$external_snapshot" "$FIXTURE_REPO/.token-saver"
  _run_calibrate >/dev/null 2>"$TEST_TMP/calibrate.err"
  status=$?
  assert_ne "0" "$status" "snapshot directory symlinkの終了コード"
  assert_file_missing "$external_snapshot/calibration/latest.json" "外部snapshot"
}

test_snapshot本体symlinkを追従せず失敗する() {
  _fixture_with_calibration_data 5 100
  snapshot_dir="$FIXTURE_REPO/.token-saver/calibration"
  external_snapshot="$TEST_TMP/external-latest.json"
  mkdir -p "$snapshot_dir"
  printf '{"fixture": "external"}\n' >"$external_snapshot"
  ln -s "$external_snapshot" "$snapshot_dir/latest.json"
  _run_calibrate >/dev/null 2>"$TEST_TMP/calibrate.err"
  status=$?
  assert_ne "0" "$status" "snapshot本体symlinkの終了コード"
  assert_eq '{"fixture": "external"}' "$(cat "$external_snapshot")" "外部snapshot非変更"
}

_fixture_with_varied_cache_reads() {
  FIXTURE_HOME="$TEST_TMP/calibration-varied-home"
  FIXTURE_REPO="$TEST_TMP/calibration-varied-repo"
  FIXTURE_REPORT="$TEST_TMP/calibration-varied-report.md"
  mkdir -p "$FIXTURE_HOME/.claude/projects" "$FIXTURE_REPO/.git" "$FIXTURE_REPO/.claude"
  percentile="${1:-75}"
  exclude_below="${2:-3}"
  python3 - "$FIXTURE_HOME" "$FIXTURE_REPO" "$percentile" "$exclude_below" <<'PYEOF'
import json
import os
import sys
from datetime import datetime, timezone

home, repo, percentile, exclude_below = sys.argv[1:]
key = "".join(char if char.isascii() and char.isalnum() else "-" for char in repo)
project = os.path.join(home, ".claude", "projects", key)
os.makedirs(project)
stamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
sessions = [
    ("short-a", 2, 10),
    ("short-b", 2, 12),
    ("long-a", 5, 100),
    ("long-b", 5, 200),
    ("long-c", 5, 300),
    ("long-d", 5, 400),
    ("long-e", 5, 1000),
]
with open(os.path.join(project, "varied.jsonl"), "w", encoding="utf-8") as handle:
    message = 0
    for session_id, turns, cache_read in sessions:
        for _ in range(turns):
            row = {
                "type": "assistant",
                "timestamp": stamp,
                "sessionId": session_id,
                "message": {
                    "id": "message-{}".format(message),
                    "usage": {
                        "input_tokens": 1,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": cache_read,
                        "output_tokens": 1,
                    },
                    "content": [],
                },
            }
            message += 1
            handle.write(json.dumps(row) + "\n")
with open(os.path.join(repo, ".claude", "token-saver.json"), "w", encoding="utf-8") as handle:
    json.dump({
        "calibration": {
            "min_sessions": 5,
            "min_assistant_turns": 20,
            "percentile": int(percentile),
            "exclude_below_assistant_turns": int(exclude_below),
        },
        "suggest_session_cut": {
            "initial_cache_read": 111,
            "increment_cache_read": 222,
        },
    }, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PYEOF
}

test_exclude_below_assistant_turnsで短命を除外しbaselineが上がる() {
  _fixture_with_varied_cache_reads 75 3
  _run_calibrate >/dev/null
  assert_eq "ok" "$(python3 - "$FIXTURE_REPO/.token-saver/calibration/latest.json" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["excluded_session_count"] == 2
assert data["sample_session_count"] == 5
assert data["total_session_count"] == 7
# values = [500,1000,1500,2000,5000]; p75 rank=ceil(0.75*5)=4 -> 2000
assert data["baseline_cache_read"] == 2000
print("ok")
PYEOF
)" "短命除外後baseline"
}

test_exclude_belowが0なら短命を残す() {
  _fixture_with_varied_cache_reads 75 0
  _run_calibrate >/dev/null
  assert_eq "ok" "$(python3 - "$FIXTURE_REPO/.token-saver/calibration/latest.json" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["excluded_session_count"] == 0
assert data["sample_session_count"] == 7
assert data["exclude_below_assistant_turns"] == 0
assert data["baseline_cache_read"] == 2000
assert "assistant_turns>=" not in data["source"]
print("ok")
PYEOF
)" "短命除外オフ"
}

test_フィルタ後本数でmin_sessionsを判定する() {
  FIXTURE_HOME="$TEST_TMP/calibration-filter-home"
  FIXTURE_REPO="$TEST_TMP/calibration-filter-repo"
  FIXTURE_REPORT="$TEST_TMP/calibration-filter-report.md"
  mkdir -p "$FIXTURE_HOME/.claude/projects" "$FIXTURE_REPO/.git" "$FIXTURE_REPO/.claude"
  python3 - "$FIXTURE_HOME" "$FIXTURE_REPO" <<'PYEOF'
import json
import os
import sys
from datetime import datetime, timezone

home, repo = sys.argv[1:]
key = "".join(char if char.isascii() and char.isalnum() else "-" for char in repo)
project = os.path.join(home, ".claude", "projects", key)
os.makedirs(project)
stamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
sessions = [
    ("a", 3, 100),
    ("b", 3, 100),
    ("c", 3, 100),
    ("d", 3, 100),
    ("e", 1, 100),
]
with open(os.path.join(project, "filter.jsonl"), "w", encoding="utf-8") as handle:
    msg = 0
    for sid, turns, cr in sessions:
        for _ in range(turns):
            handle.write(json.dumps({
                "type": "assistant",
                "timestamp": stamp,
                "sessionId": sid,
                "message": {
                    "id": "m{}".format(msg),
                    "usage": {
                        "input_tokens": 1,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": cr,
                        "output_tokens": 1,
                    },
                    "content": [],
                },
            }) + "\n")
            msg += 1
with open(os.path.join(repo, ".claude", "token-saver.json"), "w", encoding="utf-8") as handle:
    json.dump({
        "calibration": {
            "min_sessions": 5,
            "min_assistant_turns": 10,
            "exclude_below_assistant_turns": 3,
            "percentile": 75,
        },
        "suggest_session_cut": {
            "initial_cache_read": 111,
            "increment_cache_read": 222,
        },
    }, handle)
PYEOF
  _run_calibrate >/dev/null
  report="$(cat "$FIXTURE_REPORT")"
  assert_contains "$report" "判定: **サンプル不足**" "フィルタ後min_sessions"
  assert_contains "$report" "セッション数 4 件（必要 5 件）" "フィルタ後件数表示"
}

test_percentile設定キー変更でfingerprintが変わる() {
  _fixture_with_calibration_data 5 100 5 100 10 75 0
  _run_calibrate >/dev/null
  fp75="$(python3 -c 'import json;print(json.load(open("'"$FIXTURE_REPO"'/.token-saver/calibration/latest.json"))["fingerprint"])')"
  rm -rf "$FIXTURE_HOME" "$FIXTURE_REPO"
  _fixture_with_calibration_data 5 100 5 100 10 90 0
  _run_calibrate >/dev/null
  fp90="$(python3 -c 'import json;print(json.load(open("'"$FIXTURE_REPO"'/.token-saver/calibration/latest.json"))["fingerprint"])')"
  assert_ne "$fp75" "$fp90" "percentileでfingerprint変化"
}

test_レポートに分布と上位集中度を出す() {
  _fixture_with_varied_cache_reads 75 3
  _run_calibrate >/dev/null
  report="$(cat "$FIXTURE_REPORT")"
  assert_contains "$report" "採用パーセンタイル: p75" "percentile表示"
  assert_contains "$report" "短命セッション除外: assistant_turns >= 3 を母集団" "除外表示"
  assert_contains "$report" "| p50 |" "分布p50"
  assert_contains "$report" "| p95 |" "分布p95"
  assert_contains "$report" "採用: p75 = 2,000" "採用値"
  assert_contains "$report" "上位3セッションで全体 cache_read の" "上位集中度"
  assert_contains "$report" "母集団: サンプル 5 件 / 除外 2 件 / 期間内総セッション 7 件" "母集団表示"
}

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
