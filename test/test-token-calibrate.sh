#!/usr/bin/env bash
# 明示適用コマンドの安全境界を検証する。

set -u

_fixture_with_latest() {
  FIXTURE_REPO="$TEST_TMP/token-calibrate-repo"
  CONFIG="$FIXTURE_REPO/.claude/token-saver.json"
  LATEST="$FIXTURE_REPO/.token-saver/calibration/latest.json"
  OUTSIDE_CONFIG="$TEST_TMP/token-calibrate-outside.json"
  OUTSIDE_SNAPSHOT="$TEST_TMP/token-calibrate-outside-latest.json"
  FIXTURE_CLAUDE_CONFIG_DIR="$TEST_TMP/token-calibrate-empty-home/.claude"
  mkdir -p "$FIXTURE_REPO/.claude" "$FIXTURE_REPO/.token-saver/calibration" \
    "$FIXTURE_CLAUDE_CONFIG_DIR/projects"
  python3 - "$CONFIG" "$LATEST" "$OUTSIDE_CONFIG" "$REPO_ROOT" \
    "$FIXTURE_CLAUDE_CONFIG_DIR" <<'PYEOF'
import json
import os
import runpy
import sys

config_path, snapshot_path, outside_config, repo_root, claude_dir = sys.argv[1:]
config = {
    "calibration": {"private_note": "keep-calibration-key"},
    "suggest_session_cut": {
        "initial_cache_read": 30000000,
        "increment_cache_read": 30000000,
        "unrelated_threshold": 77,
    },
    "unrelated": "keep",
}
snapshot = {
    "eligible": True,
    "period": "全期間",
    "min_sessions": 5,
    "min_assistant_turns": 100,
    "session_count": 5,
    "assistant_turns": 100,
    "baseline_cache_read": 18000000,
    "current_initial": 30000000,
    "current_increment": 30000000,
    "recommended_levels": [18000000, 36000000, 54000000],
    "fingerprint": "a" * 64,
    "source": "メインセッションの重複排除後 cache_read 中央値",
    "generated_at": "2026-08-04T00:00:00.000000Z",
    "scan_days": 0,
    "all_projects": False,
}
os.environ["CLAUDE_CONFIG_DIR"] = claude_dir
fixture_root = os.path.dirname(os.path.dirname(config_path))
previous_cwd = os.getcwd()
os.chdir(fixture_root)
engine = runpy.run_path(os.path.join(repo_root, "scripts", "measure-token-usage.py"))
args = type("CalibrationArgs", (object,), {})()
args.days = 0
args.all_projects = False
project_dirs, fell_back = engine["select_project_dirs"](args)
main_paths, sub_paths = engine["transcript_paths"](project_dirs)
snapshot["fingerprint"] = engine["calibration_fingerprint"](
    args,
    None,
    {"min_sessions": 5, "min_assistant_turns": 100},
    main_paths,
    sub_paths,
    project_dirs,
    fell_back,
)
os.chdir(previous_cwd)
for path, data in ((config_path, config), (snapshot_path, snapshot), (outside_config, config)):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
PYEOF
}

_run_calibrate_command() {
  if [ -n "${FIXTURE_CLAUDE_CONFIG_DIR:-}" ]; then
    CLAUDE_CONFIG_DIR="$FIXTURE_CLAUDE_CONFIG_DIR" \
      CTS_TOKEN_CALIBRATE_TARGET_ROOT="$FIXTURE_REPO" \
      "$BASH" "$REPO_ROOT/scripts/token-calibrate.sh" "$@" \
      >"$TEST_TMP/token-calibrate.out" 2>"$TEST_TMP/token-calibrate.err"
  else
    CTS_TOKEN_CALIBRATE_TARGET_ROOT="$FIXTURE_REPO" \
      "$BASH" "$REPO_ROOT/scripts/token-calibrate.sh" "$@" \
      >"$TEST_TMP/token-calibrate.out" 2>"$TEST_TMP/token-calibrate.err"
  fi
  STATUS=$?
}

_fixture_with_measured_snapshot() {
  FIXTURE_HOME="$TEST_TMP/token-calibrate-measured-home"
  FIXTURE_REPO="$TEST_TMP/token-calibrate-measured-repo"
  FIXTURE_CLAUDE_CONFIG_DIR="$FIXTURE_HOME/.claude"
  CONFIG="$FIXTURE_REPO/.claude/token-saver.json"
  TRANSCRIPT="$FIXTURE_HOME/.claude/projects/$(printf '%s' "$FIXTURE_REPO" | sed 's#/#-#g; s#_#-#g')/session.jsonl"
  LATEST="$FIXTURE_REPO/.token-saver/calibration/latest.json"
  mkdir -p "$(dirname "$TRANSCRIPT")" "$FIXTURE_REPO/.claude"
  python3 - "$CONFIG" "$TRANSCRIPT" <<'PYEOF'
import json
import sys
from datetime import datetime, timezone

config_path, transcript_path = sys.argv[1:]
config = {
    "suggest_session_cut": {
        "initial_cache_read": 30000000,
        "increment_cache_read": 30000000,
    }
}
with open(config_path, "w", encoding="utf-8") as handle:
    json.dump(config, handle, ensure_ascii=False, indent=2)
    handle.write("\n")

stamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
with open(transcript_path, "w", encoding="utf-8") as handle:
    for index in range(100):
        row = {
            "type": "assistant",
            "timestamp": stamp,
            "sessionId": "measured-session-{}".format(index % 5),
            "message": {
                "id": "measured-message-{}".format(index),
                "usage": {
                    "input_tokens": 1,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 200,
                    "output_tokens": 1,
                },
                "content": [],
            },
        }
        handle.write(json.dumps(row) + "\n")
PYEOF
  CLAUDE_CONFIG_DIR="$FIXTURE_CLAUDE_CONFIG_DIR" \
    CTS_TOKEN_REPORT_TARGET_ROOT="$FIXTURE_REPO" \
    "$BASH" "$REPO_ROOT/scripts/token-report.sh" --calibrate \
    >"$TEST_TMP/token-calibrate-measured-report.out" \
    2>"$TEST_TMP/token-calibrate-measured-report.err"
  MEASURE_STATUS=$?
  assert_eq "0" "$MEASURE_STATUS" "実測snapshot生成"
}

_config_value() {
  python3 - "$CONFIG" "$1" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
print(data["suggest_session_cut"][sys.argv[2]])
PYEOF
}

_json_value() {
  python3 - "$CONFIG" "$@" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
for key in sys.argv[2:]:
    value = value[key]
print(value)
PYEOF
}

_set_initial() {
  python3 - "$CONFIG" "$1" <<'PYEOF'
import json
import sys

path, value = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["suggest_session_cut"]["initial_cache_read"] = value
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PYEOF
}

test_apply指定が無ければ設定を変更しない() {
  _fixture_with_latest
  before="$(cat "$CONFIG")"
  _run_calibrate_command
  assert_eq "64" "$STATUS" "apply無しの拒否"
  assert_eq "$before" "$(cat "$CONFIG")" "apply無しの非変更"
}

test_unknown引数を拒否する() {
  _fixture_with_latest
  _run_calibrate_command --days 30
  assert_eq "64" "$STATUS" "unknown引数の拒否"
  assert_contains "$(cat "$TEST_TMP/token-calibrate.err")" "usage" "unknown引数のusage"
}

test_applyの重複指定を拒否する() {
  _fixture_with_latest
  _run_calibrate_command --apply --apply
  assert_eq "64" "$STATUS" "apply重複の拒否"
}

test_適用は閾値以外のキーを保持する() {
  _fixture_with_latest
  _run_calibrate_command --apply
  assert_eq "0" "$STATUS" "apply成功"
  assert_eq "18000000" "$(_config_value initial_cache_read)" "initial更新"
  assert_eq "18000000" "$(_config_value increment_cache_read)" "increment更新"
  assert_eq "77" "$(_json_value suggest_session_cut unrelated_threshold)" "既存閾値保持"
  assert_eq "keep" "$(_json_value unrelated)" "未知キー保持"
  assert_eq "keep-calibration-key" "$(_json_value calibration private_note)" "calibrationキー保持"
  assert_eq "18000000" "$(_json_value calibration last_applied recommended_initial)" "適用メタデータ"
  assert_eq "30000000" "$(_json_value calibration last_applied previous_initial)" "適用前メタデータ"
}

test_適用はprompt_keyをapplied_keyへ記録する() {
  _fixture_with_latest
  _run_calibrate_command --apply
  state="$FIXTURE_REPO/.token-saver/calibration/state"
  assert_eq "0" "$STATUS" "prompt key apply成功"
  assert_file_exists "$state" "適用後のcalibration state"
  assert_contains "$(cat "$state")" "applied_key=5-100-5-100" "適用済みprompt key"
}

test_applyは現在値と推奨値を更新前に表示する() {
  _fixture_with_latest
  _run_calibrate_command --apply
  assert_eq "0" "$STATUS" "preview付きapply成功"
  output="$(cat "$TEST_TMP/token-calibrate.out")"
  assert_contains "$output" "現在値: initial 30000000 / increment 30000000 cache_read" "apply previewの現在値"
  assert_contains "$output" "推奨値: initial 18000000 / increment 18000000 cache_read" "apply previewの推奨値"
}

test_現在設定がsnapshotと違えば拒否する() {
  _fixture_with_latest
  _set_initial 123
  before="$(cat "$CONFIG")"
  _run_calibrate_command --apply
  assert_eq "1" "$STATUS" "競合拒否"
  assert_eq "$before" "$(cat "$CONFIG")" "競合時非変更"
}

test_state_lock競合時はconfigとstateを変更しない() {
  _fixture_with_latest
  state="$FIXTURE_REPO/.token-saver/calibration/state"
  printf 'prompted_key=5-100-5-100\napplied_key=\n' >"$state"
  before_config="$(cat "$CONFIG")"
  before_state="$(cat "$state")"
  mkdir "$FIXTURE_REPO/.token-saver/calibration/.lock"
  _run_calibrate_command --apply
  assert_eq "1" "$STATUS" "state lock競合拒否"
  assert_eq "$before_config" "$(cat "$CONFIG")" "state lock競合時のconfig非変更"
  assert_eq "$before_state" "$(cat "$state")" "state lock競合時のstate非変更"
}

test_不正snapshotを拒否する() {
  _fixture_with_latest
  python3 - "$LATEST" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    snapshot = json.load(handle)
snapshot["eligible"] = False
snapshot["fingerprint"] = "not-a-fingerprint"
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(snapshot, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PYEOF
  before="$(cat "$CONFIG")"
  _run_calibrate_command --apply
  assert_eq "1" "$STATUS" "不正snapshot拒否"
  assert_eq "$before" "$(cat "$CONFIG")" "不正snapshot時非変更"
}

test_不正な暦日のsnapshotを拒否する() {
  _fixture_with_latest
  python3 - "$LATEST" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    snapshot = json.load(handle)
snapshot["generated_at"] = "2026-99-99T00:00:00.000000Z"
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(snapshot, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PYEOF
  before="$(cat "$CONFIG")"
  _run_calibrate_command --apply
  assert_eq "1" "$STATUS" "不正な暦日のsnapshot拒否"
  assert_eq "$before" "$(cat "$CONFIG")" "不正な暦日のsnapshot時非変更"
}

test_設定とsnapshotのsymlinkを追従しない() {
  _fixture_with_latest
  outside_before="$(cat "$OUTSIDE_CONFIG")"
  rm -f "$CONFIG"
  ln -s "$OUTSIDE_CONFIG" "$CONFIG"
  _run_calibrate_command --apply
  assert_eq "1" "$STATUS" "config symlink拒否"
  assert_eq "$outside_before" "$(cat "$OUTSIDE_CONFIG")" "外部config非変更"
}

test_snapshotのsymlinkを追従しない() {
  _fixture_with_latest
  printf '%s\n' '{"eligible": true}' >"$OUTSIDE_SNAPSHOT"
  rm -f "$LATEST"
  ln -s "$OUTSIDE_SNAPSHOT" "$LATEST"
  before="$(cat "$CONFIG")"
  _run_calibrate_command --apply
  assert_eq "1" "$STATUS" "snapshot symlink拒否"
  assert_eq "$before" "$(cat "$CONFIG")" "snapshot symlink時非変更"
}

test_claudeディレクトリのsymlinkを追従しない() {
  _fixture_with_latest
  external_claude="$TEST_TMP/token-calibrate-external-claude"
  mkdir -p "$external_claude"
  rm -rf "$FIXTURE_REPO/.claude"
  ln -s "$external_claude" "$FIXTURE_REPO/.claude"
  _run_calibrate_command --apply
  assert_eq "1" "$STATUS" ".claude symlink拒否"
  assert_file_missing "$external_claude/token-saver.json" "外部config非変更"
}

test_configが無ければ既定値との一致を確認して作成する() {
  _fixture_with_latest
  rm -f "$CONFIG"
  _run_calibrate_command --apply
  assert_eq "0" "$STATUS" "config新規apply"
  assert_eq "18000000" "$(_config_value initial_cache_read)" "新規initial"
  assert_eq "18000000" "$(_config_value increment_cache_read)" "新規increment"
}

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
