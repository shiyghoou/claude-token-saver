#!/usr/bin/env bash
# Stop hook の軽量キャリブレーション集計と一度だけの促しを検証する。

set -u

_calibration_fixture_repo() {
  FIXTURE_ROOT="$TEST_TMP/calibration repo"
  FIXTURE_TRANSCRIPT="$FIXTURE_ROOT/session.jsonl"
  FIXTURE_CALIBRATION_DIR="$FIXTURE_ROOT/.token-saver/calibration"
  mkdir -p "$FIXTURE_ROOT/.claude" "$FIXTURE_CALIBRATION_DIR"
  cat >"$FIXTURE_ROOT/.claude/token-saver.json" <<'EOF'
{
  "calibration": {
    "min_sessions": 5,
    "min_assistant_turns": 100
  },
  "suggest_session_cut": {
    "initial_cache_read": 30000000,
    "increment_cache_read": 30000000
  },
  "unrelated": "must remain untouched"
}
EOF
}

_write_calibration_transcript() {
  local session_count="$1" turns="$2"
  python3 - "$FIXTURE_TRANSCRIPT" "$session_count" "$turns" <<'PYEOF'
import json
import sys

path, session_count, turns = sys.argv[1:]
session_count = int(session_count)
turns = int(turns)
with open(path, "w", encoding="utf-8") as handle:
    for index in range(turns):
        session_id = "calibration-session-{}".format(index % session_count)
        row = {
            "type": "assistant",
            "sessionId": session_id,
            "message": {
                "id": "calibration-message-{}".format(index),
                "usage": {
                    "input_tokens": 1,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 10,
                    "output_tokens": 1,
                },
                "content": [],
            },
        }
        handle.write(json.dumps(row) + "\n")
PYEOF
}

_write_summary_transcript() {
  cat >"$FIXTURE_TRANSCRIPT" <<'EOF'
{"type":"assistant","sessionId":"summary-session","message":{"id":"summary-1","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":10,"output_tokens":1}}}
{"type":"assistant","sessionId":"summary-session","message":{"id":"summary-1","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":10,"output_tokens":1}}}
{"type":"assistant","sessionId":"summary-session","message":{"id":"summary-2","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":20,"output_tokens":1}}}
EOF
}

_calibration_payload() {
  local session_id="${1:-calibration-stop}"
  printf '{"cwd":"%s","session_id":"%s","transcript_path":"%s"}' \
    "$FIXTURE_ROOT" "$session_id" "$FIXTURE_TRANSCRIPT"
}

_run_calibration_hook() {
  local payload="$1"
  local out="$2" err="$3"
  printf '%s\n' "$payload" | bash "$REPO_ROOT/scripts/suggest-session-cut.sh" >"$out" 2>"$err"
  CALIBRATION_HOOK_RC="$?"
}

test_calibration_config_numberは完全JSON検証後に正整数だけを返す() {
  _calibration_fixture_repo
  value="$(bash -c '. "$1"; cts_calibration_config_number "$2" min_sessions' _ \
    "$REPO_ROOT/scripts/lib/calibration-state.sh" "$FIXTURE_ROOT/.claude/token-saver.json" 2>/dev/null)"
  status=$?
  assert_eq "0" "$status" "calibration config parserの成功"
  assert_eq "5" "$value" "calibration.min_sessions"

  printf '{"calibration":{"min_sessions":-1}}\n' >"$FIXTURE_ROOT/.claude/token-saver.json"
  value="$(bash -c '. "$1"; cts_calibration_config_number "$2" min_sessions' _ \
    "$REPO_ROOT/scripts/lib/calibration-state.sh" "$FIXTURE_ROOT/.claude/token-saver.json" 2>/dev/null)"
  status=$?
  assert_ne "0" "$status" "負数のcalibration設定を拒否"
  assert_empty "$value" "負数のcalibration設定の出力"
}

test_usage_summaryは既存合計を保ちassistant_turnsを追加する() {
  _calibration_fixture_repo
  _write_summary_transcript
  total="$(awk -f "$REPO_ROOT/scripts/lib/suggest-session-cut-usage.awk" "$FIXTURE_TRANSCRIPT")"
  summary="$(awk -v summary=1 -f "$REPO_ROOT/scripts/lib/suggest-session-cut-usage.awk" "$FIXTURE_TRANSCRIPT")"
  assert_eq "30" "$total" "既定usage合計"
  assert_eq $'30\t2' "$summary" "summary usage合計とassistant turns"
}

test_5セッション100ターン未満はキャリブレーションを促さない() {
  _calibration_fixture_repo
  _write_calibration_transcript 1 20
  for session_index in 1 2 3 4; do
    payload="$(_calibration_payload "calibration-stop-$session_index")"
    _run_calibration_hook "$payload" "$TEST_TMP/below-$session_index.stdout" \
      "$TEST_TMP/below-$session_index.stderr"
  done
  assert_eq "0" "$CALIBRATION_HOOK_RC" "サンプル不足の終了コード"
  assert_empty "$(cat "$TEST_TMP/below-4.stdout")" "サンプル不足のstdout"
  assert_empty "$(cat "$TEST_TMP/below-4.stderr")" "サンプル不足のstderr"
  assert_file_exists "$FIXTURE_CALIBRATION_DIR/sessions.tsv" "不足時のsession ledger"
}

test_条件達成時は計測と明示適用の短い案内を一度出す() {
  _calibration_fixture_repo
  _write_calibration_transcript 1 20
  for session_index in 1 2 3 4 5; do
    payload="$(_calibration_payload "calibration-stop-$session_index")"
    _run_calibration_hook "$payload" "$TEST_TMP/eligible-$session_index.stdout" \
      "$TEST_TMP/eligible-$session_index.stderr"
  done
  output="$(cat "$TEST_TMP/eligible-5.stdout")"
  assert_eq "0" "$CALIBRATION_HOOK_RC" "条件達成時の終了コード"
  assert_empty "$(cat "$TEST_TMP/eligible-5.stderr")" "条件達成時のstderr"
  assert_contains "$output" "./.token-saver/token-report.sh --calibrate" "キャリブレーション計測コマンド"
  assert_contains "$output" "./.token-saver/token-calibrate.sh --apply" "明示適用コマンド"
  assert_count "1" "$output" "キャリブレーションのサンプル条件を満たしました" "促しの回数"
}

test_同じ判定キーでは2回目のキャリブレーション案内を出さない() {
  _calibration_fixture_repo
  _write_calibration_transcript 1 20
  for session_index in 1 2 3 4 5; do
    payload="$(_calibration_payload "calibration-stop-$session_index")"
    _run_calibration_hook "$payload" "$TEST_TMP/first-$session_index.stdout" \
      "$TEST_TMP/first-$session_index.stderr"
  done
  payload="$(_calibration_payload "calibration-stop-5")"
  _run_calibration_hook "$payload" "$TEST_TMP/second.stdout" "$TEST_TMP/second.stderr"
  assert_count "1" "$(cat "$TEST_TMP/first-5.stdout")" "キャリブレーションのサンプル条件を満たしました" "初回案内"
  assert_empty "$(cat "$TEST_TMP/second.stdout")" "同じ判定キーの再案内"
  assert_empty "$(cat "$TEST_TMP/second.stderr")" "同じ判定キーのstderr"
}

test_calibration_sessions_tsvのsymlinkとlock失敗は無音で抜ける() {
  _calibration_fixture_repo
  _write_calibration_transcript 1 20
  outside="$TEST_TMP/outside-sessions.tsv"
  printf 'outside\n' >"$outside"
  ln -s "$outside" "$FIXTURE_CALIBRATION_DIR/sessions.tsv"
  payload="$(_calibration_payload)"
  _run_calibration_hook "$payload" "$TEST_TMP/symlink.stdout" "$TEST_TMP/symlink.stderr"
  assert_eq "0" "$CALIBRATION_HOOK_RC" "ledger symlink時の終了コード"
  assert_empty "$(cat "$TEST_TMP/symlink.stdout")" "ledger symlink時のstdout"
  assert_empty "$(cat "$TEST_TMP/symlink.stderr")" "ledger symlink時のstderr"
  assert_eq "outside" "$(cat "$outside")" "ledger symlink先の不変性"

  rm -f "$FIXTURE_CALIBRATION_DIR/sessions.tsv"
  : >"$FIXTURE_CALIBRATION_DIR/.lock"
  _run_calibration_hook "$payload" "$TEST_TMP/lock.stdout" "$TEST_TMP/lock.stderr"
  assert_eq "0" "$CALIBRATION_HOOK_RC" "state lock失敗時の終了コード"
  assert_empty "$(cat "$TEST_TMP/lock.stdout")" "state lock失敗時のstdout"
  assert_empty "$(cat "$TEST_TMP/lock.stderr")" "state lock失敗時のstderr"
}

test_不正payloadは既存Stopフックと同じfail_closed契約を守る() {
  _calibration_fixture_repo
  printf '{"cwd":' | bash "$REPO_ROOT/scripts/suggest-session-cut.sh" \
    >"$TEST_TMP/invalid.stdout" 2>"$TEST_TMP/invalid.stderr"
  status=$?
  assert_eq "0" "$status" "不正payloadの終了コード"
  assert_empty "$(cat "$TEST_TMP/invalid.stdout")" "不正payloadのstdout"
  assert_empty "$(cat "$TEST_TMP/invalid.stderr")" "不正payloadのstderr"
}

test_並行Stopフックでもキャリブレーション案内は一度だけ出す() {
  _calibration_fixture_repo
  _write_calibration_transcript 1 20
  for session_index in 1 2 3 4; do
    payload="$(_calibration_payload "calibration-stop-$session_index")"
    _run_calibration_hook "$payload" "$TEST_TMP/concurrent-seed-$session_index.stdout" \
      "$TEST_TMP/concurrent-seed-$session_index.stderr"
  done
  payload="$(_calibration_payload "calibration-stop-5")"
  printf '%s\n' "$payload" | bash "$REPO_ROOT/scripts/suggest-session-cut.sh" \
    >"$TEST_TMP/concurrent-1.stdout" 2>"$TEST_TMP/concurrent-1.stderr" &
  first_pid=$!
  printf '%s\n' "$payload" | bash "$REPO_ROOT/scripts/suggest-session-cut.sh" \
    >"$TEST_TMP/concurrent-2.stdout" 2>"$TEST_TMP/concurrent-2.stderr" &
  second_pid=$!
  wait "$first_pid"
  first_status=$?
  wait "$second_pid"
  second_status=$?
  combined="$(cat "$TEST_TMP/concurrent-1.stdout" "$TEST_TMP/concurrent-2.stdout")"
  assert_eq "0" "$first_status" "並行1の終了コード"
  assert_eq "0" "$second_status" "並行2の終了コード"
  assert_count "1" "$combined" "キャリブレーションのサンプル条件を満たしました" "並行案内の回数"
  assert_empty "$(cat "$TEST_TMP/concurrent-1.stderr" "$TEST_TMP/concurrent-2.stderr")" "並行実行のstderr"
}
