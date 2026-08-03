#!/usr/bin/env bash
# 明示適用コマンドの安全境界を検証する。

set -u

_fixture_with_latest() {
  FIXTURE_REPO="$TEST_TMP/token-calibrate-repo"
  CONFIG="$FIXTURE_REPO/.claude/token-saver.json"
  LATEST="$FIXTURE_REPO/.token-saver/calibration/latest.json"
  OUTSIDE_CONFIG="$TEST_TMP/token-calibrate-outside.json"
  OUTSIDE_SNAPSHOT="$TEST_TMP/token-calibrate-outside-latest.json"
  mkdir -p "$FIXTURE_REPO/.claude" "$FIXTURE_REPO/.token-saver/calibration"
  python3 - "$CONFIG" "$LATEST" "$OUTSIDE_CONFIG" <<'PYEOF'
import json
import sys

config_path, snapshot_path, outside_config = sys.argv[1:]
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
}
for path, data in ((config_path, config), (snapshot_path, snapshot), (outside_config, config)):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
PYEOF
}

_run_calibrate_command() {
  CTS_TOKEN_CALIBRATE_TARGET_ROOT="$FIXTURE_REPO" \
    "$BASH" "$REPO_ROOT/scripts/token-calibrate.sh" "$@" \
    >"$TEST_TMP/token-calibrate.out" 2>"$TEST_TMP/token-calibrate.err"
  STATUS=$?
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

test_現在設定がsnapshotと違えば拒否する() {
  _fixture_with_latest
  _set_initial 123
  before="$(cat "$CONFIG")"
  _run_calibrate_command --apply
  assert_eq "1" "$STATUS" "競合拒否"
  assert_eq "$before" "$(cat "$CONFIG")" "競合時非変更"
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
