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
elif mode == "session_count":
    scan = module["scan_transcripts"]([sys.argv[3]], None)
    print(len(scan.session_stats))
elif mode == "session_stats":
    scan = module["scan_transcripts"]([sys.argv[3]], None)
    stats = scan.session_stats[sys.argv[4]]
    print("{},{}".format(stats.cache_read, stats.assistant_turns))
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

_fixture_with_calibration_data() {
  session_count="$1"
  assistant_turns="$2"
  min_sessions="${3:-}"
  min_assistant_turns="${4:-}"
  cache_read="${5:-10}"
  FIXTURE_HOME="$TEST_TMP/calibration-home"
  FIXTURE_REPO="$TEST_TMP/calibration-repo"
  FIXTURE_REPORT="$TEST_TMP/calibration-report.md"
  mkdir -p "$FIXTURE_HOME/.claude/projects" "$FIXTURE_REPO/.git" "$FIXTURE_REPO/.claude"

  python3 - "$FIXTURE_HOME" "$FIXTURE_REPO" "$session_count" "$assistant_turns" \
    "$min_sessions" "$min_assistant_turns" "$cache_read" <<'PYEOF'
import json
import os
import sys
from datetime import datetime, timezone

home, repo, session_count, assistant_turns, min_sessions, min_assistant_turns, cache_read = sys.argv[1:]
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
if min_sessions and min_assistant_turns:
    config["calibration"] = {
        "min_sessions": int(min_sessions),
        "min_assistant_turns": int(min_assistant_turns),
    }
with open(os.path.join(repo, ".claude", "token-saver.json"), "w", encoding="utf-8") as handle:
    json.dump(config, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PYEOF
}

_run_calibrate() {
  (
    cd "$FIXTURE_REPO" &&
      CLAUDE_CONFIG_DIR="$FIXTURE_HOME/.claude" \
      python3 -B "$REPO_ROOT/scripts/measure-token-usage.py" --calibrate --days 0 --out "$FIXTURE_REPORT"
  )
}

test_既定の5セッション100ターン未満は促さない() {
  _fixture_with_calibration_data 4 99
  _run_calibrate >/dev/null
  report="$(cat "$FIXTURE_REPORT")"
  assert_contains "$report" "判定: **サンプル不足**" "不足判定"
  assert_not_contains "$report" "推奨段階1単位" "不足時の推奨抑止"
}

test_設定で必要数を変更できる() {
  _fixture_with_calibration_data 2 3 2 3
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
  _fixture_with_calibration_data 2 3 2 3
  cat >"$FIXTURE_REPO/.claude/token-saver.json" <<'EOF'
{
  "calibration": { "min_sessions": 0, "min_assistant_turns": 0 },
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
  _fixture_with_calibration_data 5 100
  before="$(cat "$FIXTURE_REPO/.claude/token-saver.json")"
  _run_calibrate >/dev/null
  snapshot="$FIXTURE_REPO/.token-saver/calibration/latest.json"
  assert_eq "$before" "$(cat "$FIXTURE_REPO/.claude/token-saver.json")" "自動適用禁止"
  [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || _fail "snapshot が通常ファイルでない"
  [ -s "$snapshot" ] || _fail "snapshot が空である"
  snapshot_json="$(cat "$snapshot")"
  assert_contains "$snapshot_json" '"eligible": true' "snapshot判定"
  assert_contains "$snapshot_json" '"baseline_cache_read"' "snapshot推奨値"
  assert_not_contains "$snapshot_json" "$FIXTURE_REPO" "snapshotのrepo実パス"
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
