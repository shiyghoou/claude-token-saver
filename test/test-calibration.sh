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
