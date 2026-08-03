#!/usr/bin/env bash
# Stop hook のセッション切り提案 fixture。JSONL の usage 集計、閾値判定、
# 状態ファイルの隔離、fail-closed 契約を検証する。

set -u

SUGGEST_SESSION_CUT_MESSAGE="引き継ぎを書いてから、手動で新しいセッションへ切り替えることを検討してください。"

_fixture_repo() {
  FIXTURE_ROOT="$TEST_TMP/repo with spaces"
  FIXTURE_TRANSCRIPT="$FIXTURE_ROOT/session.jsonl"
  FIXTURE_STATE_DIR="$FIXTURE_ROOT/.token-saver/session-cut"
  mkdir -p "$FIXTURE_ROOT"
}

_payload() {
  local root="$1" session_id="$2" transcript="$3"
  printf '{"cwd":"%s","session_id":"%s","transcript_path":"%s"}' \
    "$root" "$session_id" "$transcript"
}

_run_hook() {
  local payload="$1"
  local run_root="$2"
  shift 2
  HOOK_OUT="$TEST_TMP/hook.stdout"
  HOOK_ERR="$TEST_TMP/hook.stderr"
  mkdir -p "$TEST_TMP/bin"
  cat >"$TEST_TMP/bin/clear" <<'EOF'
#!/usr/bin/env bash
touch "$CTS_CLEAR_CALLED"
exit 99
EOF
  chmod +x "$TEST_TMP/bin/clear"
  CTS_CLEAR_CALLED="$TEST_TMP/clear.called"
  PATH="$TEST_TMP/bin:$PATH" "$@" bash "$REPO_ROOT/scripts/suggest-session-cut.sh" \
    >"$HOOK_OUT" 2>"$HOOK_ERR" <<EOF
$payload
EOF
  HOOK_RC="$?"
  HOOK_STDOUT="$(cat "$HOOK_OUT")"
  HOOK_STDERR="$(cat "$HOOK_ERR")"
}

_write_transcript() {
  cat >"$FIXTURE_TRANSCRIPT"
}

_pick_state_file() {
  local suffix="$1"
  local candidate found=""
  for candidate in "$FIXTURE_STATE_DIR"/*"$suffix"; do
    [ -e "$candidate" ] || continue
    if [ -n "$found" ]; then
      _fail "状態ファイルが複数ある: $suffix"
    fi
    found="$candidate"
  done
  CTS_PICKED_STATE_FILE="$found"
}

_state_file_text() {
  _pick_state_file "$1"
  [ -n "$CTS_PICKED_STATE_FILE" ] || _fail "状態ファイルが無い: $1"
  CTS_STATE_FILE_TEXT="$(cat "$CTS_PICKED_STATE_FILE")"
}

_count_tmp_files() {
  local count=0 candidate
  for candidate in "$FIXTURE_STATE_DIR"/*.tmp "$FIXTURE_STATE_DIR"/.*.tmp; do
    [ -e "$candidate" ] || continue
    count=$((count + 1))
  done
  printf '%s' "$count"
}

test_3000万境界と重複抑止と6000万境界を扱う() {
  _fixture_repo
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":29999999,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-a" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "29999999 の終了コード"
  assert_empty "$HOOK_STDOUT" "29999999 の stdout"
  assert_empty "$HOOK_STDERR" "29999999 の stderr"

  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "30000000 の終了コード"
  assert_contains "$HOOK_STDOUT" "$SUGGEST_SESSION_CUT_MESSAGE" "30000000 の提案"
  assert_empty "$HOOK_STDERR" "30000000 の stderr"
  _state_file_text ".marker"
  marker_text="$CTS_STATE_FILE_TEXT"
  assert_contains "$marker_text" "boundary=30000000" "30000000 marker"

  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "同一 Stop 再実行の終了コード"
  assert_empty "$HOOK_STDOUT" "同一 Stop 再実行では再提案しない"
  assert_empty "$HOOK_STDERR" "同一 Stop 再実行の stderr"

  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
{"type":"assistant","message":{"id":"m2","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "60000000 の終了コード"
  assert_contains "$HOOK_STDOUT" "$SUGGEST_SESSION_CUT_MESSAGE" "60000000 の提案"
  _state_file_text ".marker"
  marker_text="$CTS_STATE_FILE_TEXT"
  assert_contains "$marker_text" "boundary=60000000" "60000000 marker"
}

test_複数境界を一度に越えても一回だけ提案する() {
  _fixture_repo
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"m95","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":95000000,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-b" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "95000000 の終了コード"
  assert_count "1" "$HOOK_STDOUT" "$SUGGEST_SESSION_CUT_MESSAGE" "複数境界でも提案は1回"
  _state_file_text ".marker"
  marker_text="$CTS_STATE_FILE_TEXT"
  assert_contains "$marker_text" "boundary=90000000" "最新境界まで進める"
}

test_message_idとrequestId重複を除外し文字列中の同名キーを数えない() {
  _fixture_repo
  _write_transcript <<'EOF'
{"type":"assistant","requestId":"req-a","timestamp":"2026-08-03T00:00:00Z","message":{"id":"dup-a","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":10000000,"output_tokens":0},"content":[{"type":"text","text":"{\"input_tokens\":99999999,\"message\":{\"id\":\"fake\"}}"}]}}
{"type":"assistant","requestId":"req-a","timestamp":"2026-08-03T00:00:01Z","message":{"id":"dup-a","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":10000000,"output_tokens":0},"content":[]}}
{"type":"assistant","requestId":"req-b","timestamp":"2026-08-03T00:00:02Z","message":{"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":5000000,"output_tokens":0},"content":[]}}
{"type":"assistant","requestId":"req-b","timestamp":"2026-08-03T00:00:02Z","message":{"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":5000000,"output_tokens":0},"content":[]}}
{"type":"assistant","requestId":"req-b","timestamp":"2026-08-03T00:00:02Z","message":{"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":5000000,"output_tokens":0},"content":[]}}
{"type":"assistant","requestId":"req-c","timestamp":"2026-08-03T00:00:03Z","message":{"id":"unique","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":15000000,"output_tokens":0},"content":[]}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-c" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "重複排除の終了コード"
  assert_contains "$HOOK_STDOUT" "$SUGGEST_SESSION_CUT_MESSAGE" "重複排除後に3000万で提案"
  _state_file_text ".cache"
  cache_text="$CTS_STATE_FILE_TEXT"
  assert_contains "$cache_text" "total=30000000" "重複排除後の合計"
}

test_id無しfallbackはtimestamp差だけでは重複集計しない() {
  _fixture_repo
  _write_transcript <<'EOF'
{"type":"assistant","requestId":"req-same","timestamp":"2026-08-03T00:00:00Z","message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":15000000,"output_tokens":3},"content":[]}}
{"type":"assistant","requestId":"req-same","timestamp":"2026-08-03T00:00:01Z","message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":15000000,"output_tokens":3},"content":[]}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-c-timestamp" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "timestamp差分重複排除の終了コード"
  assert_empty "$HOOK_STDOUT" "timestamp差だけの重複では閾値に届かない"
  assert_empty "$HOOK_STDERR" "timestamp差分重複排除の stderr"
  _state_file_text ".cache"
  cache_text="$CTS_STATE_FILE_TEXT"
  assert_contains "$cache_text" "total=15000000" "timestampを除いたfallback keyで重複排除する"
}

test_欠落入力と壊れたJSONと読めないJSONLでは誤発火しない() {
  _fixture_repo
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF

  _run_hook '{"session_id":"missing-cwd","transcript_path":"/tmp/x.jsonl"}' "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "cwd 欠落でも rc=0"
  assert_empty "$HOOK_STDOUT" "cwd 欠落では無出力"
  assert_empty "$HOOK_STDERR" "cwd 欠落でも stderr 空"

  payload_missing_session="$(printf '{"cwd":"%s","transcript_path":"%s"}' "$FIXTURE_ROOT" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload_missing_session" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "session_id 欠落でも rc=0"
  assert_empty "$HOOK_STDOUT" "session_id 欠落では無出力"
  assert_empty "$HOOK_STDERR" "session_id 欠落でも stderr 空"

  payload_missing_transcript="$(printf '{"cwd":"%s","session_id":"missing-transcript"}' "$FIXTURE_ROOT")"
  _run_hook "$payload_missing_transcript" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "transcript_path 欠落でも rc=0"
  assert_empty "$HOOK_STDOUT" "transcript_path 欠落では無出力"
  assert_empty "$HOOK_STDERR" "transcript_path 欠落でも stderr 空"

  _run_hook '{"cwd":' "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "壊れた payload でも rc=0"
  assert_empty "$HOOK_STDOUT" "壊れた payload では無出力"
  assert_empty "$HOOK_STDERR" "壊れた payload でも stderr 空"

  payload_missing_file="$(_payload "$FIXTURE_ROOT" "missing-file" "$FIXTURE_ROOT/missing.jsonl")"
  _run_hook "$payload_missing_file" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "存在しない JSONL でも rc=0"
  assert_empty "$HOOK_STDOUT" "存在しない JSONL では無出力"
  assert_empty "$HOOK_STDERR" "存在しない JSONL でも stderr 空"

  chmod 000 "$FIXTURE_TRANSCRIPT"
  payload="$(_payload "$FIXTURE_ROOT" "session-d" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "読めない JSONL でも rc=0"
  assert_empty "$HOOK_STDOUT" "読めない JSONL では無出力"
  assert_empty "$HOOK_STDERR" "読めない JSONL でも stderr 空"
}

test_設定値の環境変数上書きと無効値フォールバックを使う() {
  _fixture_repo
  mkdir -p "$FIXTURE_ROOT/.claude"
  cat >"$FIXTURE_ROOT/.claude/token-saver.json" <<'EOF'
{
  "suggest_session_cut": {
    "initial_cache_read": 20,
    "increment_cache_read": 7,
    "retention_days": 1,
    "log_max_bytes": 128,
    "log_backups": 1
  }
}
EOF
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"cfg-a","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":14,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-e" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "設定ファイル閾値未満の終了コード"
  assert_empty "$HOOK_STDOUT" "設定ファイルの20未満では提案しない"

  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"cfg-a","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":20,"output_tokens":0}}}
EOF
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_contains "$HOOK_STDOUT" "$SUGGEST_SESSION_CUT_MESSAGE" "設定ファイルの初回閾値"

  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"cfg-a","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":19,"output_tokens":0}}}
EOF
  payload_env="$(_payload "$FIXTURE_ROOT" "session-e-env" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload_env" "$FIXTURE_ROOT" env \
    CTS_SESSION_CUT_INITIAL_CACHE_READ=15 CTS_SESSION_CUT_INCREMENT_CACHE_READ=5
  assert_eq "0" "$HOOK_RC" "環境変数上書きの終了コード"
  assert_contains "$HOOK_STDOUT" "$SUGGEST_SESSION_CUT_MESSAGE" "環境変数が設定ファイルより優先される"

  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"cfg-a","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":15,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-e2" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env \
    CTS_SESSION_CUT_INITIAL_CACHE_READ=15 CTS_SESSION_CUT_INCREMENT_CACHE_READ=5
  assert_contains "$HOOK_STDOUT" "$SUGGEST_SESSION_CUT_MESSAGE" "環境変数上書きの閾値"

  _fixture_repo
  mkdir -p "$FIXTURE_ROOT/.claude"
  cat >"$FIXTURE_ROOT/.claude/token-saver.json" <<'EOF'
{
  "suggest_session_cut": {
    "initial_cache_read": "30000000",
    "increment_cache_read": 0,
    "retention_days": -1,
    "log_max_bytes": "big",
    "log_backups": -1
  }
}
EOF
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"cfg-b","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-f" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env \
    CTS_SESSION_CUT_INITIAL_CACHE_READ=abc CTS_SESSION_CUT_INCREMENT_CACHE_READ=0
  assert_eq "0" "$HOOK_RC" "無効値フォールバックの終了コード"
  assert_contains "$HOOK_STDOUT" "$SUGGEST_SESSION_CUT_MESSAGE" "無効値は既定値へフォールバック"
}

test_設定値はroot直下suggest_session_cutの直下だけから読む() {
  for case_name in unrelated_parent nested_parent nested_target string_value; do
    FIXTURE_ROOT="$TEST_TMP/config scope $case_name"
    FIXTURE_TRANSCRIPT="$FIXTURE_ROOT/session.jsonl"
    FIXTURE_STATE_DIR="$FIXTURE_ROOT/.token-saver/session-cut"
    mkdir -p "$FIXTURE_ROOT/.claude"
    case "$case_name" in
      unrelated_parent)
        cat >"$FIXTURE_ROOT/.claude/token-saver.json" <<'EOF'
{
  "other": { "initial_cache_read": 1 },
  "suggest_session_cut": { "initial_cache_read": 20 }
}
EOF
        ;;
      nested_parent)
        cat >"$FIXTURE_ROOT/.claude/token-saver.json" <<'EOF'
{
  "other": { "suggest_session_cut": { "initial_cache_read": 1 } },
  "suggest_session_cut": { "initial_cache_read": 20 }
}
EOF
        ;;
      nested_target)
        cat >"$FIXTURE_ROOT/.claude/token-saver.json" <<'EOF'
{
  "suggest_session_cut": {
    "nested": { "initial_cache_read": 1 },
    "initial_cache_read": 20
  }
}
EOF
        ;;
      string_value)
        cat >"$FIXTURE_ROOT/.claude/token-saver.json" <<'EOF'
{
  "note": "文字列中の \"initial_cache_read\": 1 は設定ではない",
  "suggest_session_cut": { "initial_cache_read": 20 }
}
EOF
        ;;
    esac

    _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"cfg-scope-low","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":19,"output_tokens":0}}}
EOF
    payload="$(_payload "$FIXTURE_ROOT" "session-config-scope-low-$case_name" "$FIXTURE_TRANSCRIPT")"
    _run_hook "$payload" "$FIXTURE_ROOT" env
    assert_eq "0" "$HOOK_RC" "設定スコープ閾値未満の終了コード $case_name"
    assert_empty "$HOOK_STDOUT" "設定スコープ外の値では提案しない $case_name"
    assert_empty "$HOOK_STDERR" "設定スコープ閾値未満の stderr $case_name"

    _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"cfg-scope-high","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":20,"output_tokens":0}}}
EOF
    payload="$(_payload "$FIXTURE_ROOT" "session-config-scope-high-$case_name" "$FIXTURE_TRANSCRIPT")"
    _run_hook "$payload" "$FIXTURE_ROOT" env
    assert_eq "0" "$HOOK_RC" "root直下設定値の終了コード $case_name"
    assert_contains "$HOOK_STDOUT" "$SUGGEST_SESSION_CUT_MESSAGE" \
      "root直下suggest_session_cutの直下値を使う $case_name"
    assert_empty "$HOOK_STDERR" "root直下設定値の stderr $case_name"
  done
}

test_状態パスはgit形状や空白に依らずtoken_saver配下を使う() {
  for kind in no_git git_dir git_file; do
    FIXTURE_ROOT="$TEST_TMP/root $kind"
    FIXTURE_TRANSCRIPT="$FIXTURE_ROOT/session.jsonl"
    FIXTURE_STATE_DIR="$FIXTURE_ROOT/.token-saver/session-cut"
    mkdir -p "$FIXTURE_ROOT"
    case "$kind" in
      git_dir) mkdir -p "$FIXTURE_ROOT/.git" ;;
      git_file) printf 'gitdir: /tmp/worktree\n' >"$FIXTURE_ROOT/.git" ;;
    esac
    cat >"$FIXTURE_TRANSCRIPT" <<'EOF'
{"type":"assistant","message":{"id":"path-a","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
    payload="$(_payload "$FIXTURE_ROOT" "session-path-$kind" "$FIXTURE_TRANSCRIPT")"
    _run_hook "$payload" "$FIXTURE_ROOT" env
    assert_eq "0" "$HOOK_RC" "状態パスの終了コード $kind"
    assert_contains "$HOOK_STDOUT" "$SUGGEST_SESSION_CUT_MESSAGE" "状態パスの提案 $kind"
    assert_file_exists "$FIXTURE_STATE_DIR" "state dir $kind"
    assert_file_missing "$FIXTURE_ROOT/.git/session-cut" "git 配下へ作らない $kind"
  done
}

test_ログローテーションと期限掃除と一時ファイル掃除を行う() {
  _fixture_repo
  mkdir -p "$FIXTURE_STATE_DIR"
  printf 'updated_at=1\ntotal=1\n' >"$FIXTURE_STATE_DIR/old.cache"
  printf 'updated_at=1\nboundary=1\n' >"$FIXTURE_STATE_DIR/old.marker"
  printf 'stale\n' >"$FIXTURE_STATE_DIR/.old.cache.1.tmp"
  stale_atomic_tmp="$(mktemp "$FIXTURE_STATE_DIR/.suggest-session-cut.XXXXXX")"
  printf 'stale atomic\n' >"$stale_atomic_tmp"
  touch -t 200001010000 "$FIXTURE_STATE_DIR/old.cache" \
    "$FIXTURE_STATE_DIR/old.marker" "$FIXTURE_STATE_DIR/.old.cache.1.tmp" \
    "$stale_atomic_tmp"
  printf '0123456789abcdef0123456789abcdef0123456789abcdef' >"$FIXTURE_STATE_DIR/events.log"
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"gc-a","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-g" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env \
    CTS_SESSION_CUT_RETENTION_DAYS=1 CTS_SESSION_CUT_LOG_MAX_BYTES=32
  assert_eq "0" "$HOOK_RC" "cleanup の終了コード"
  assert_file_missing "$FIXTURE_STATE_DIR/old.cache" "古い cache を掃除する"
  assert_file_missing "$FIXTURE_STATE_DIR/old.marker" "古い marker を掃除する"
  assert_file_missing "$FIXTURE_STATE_DIR/.old.cache.1.tmp" "古い tmp を掃除する"
  assert_file_missing "$stale_atomic_tmp" "古い mktemp 実名を掃除する"
  assert_file_exists "$FIXTURE_STATE_DIR/events.log.1" "ログローテーション"
  tmp_count="$(_count_tmp_files)"
  assert_eq "0" "$tmp_count" "cache 更新後に tmp を残さない"
}

test_ログ追記で上限を超える場合は追記前にローテーションする() {
  for case_name in exact_max one_before_max; do
    FIXTURE_ROOT="$TEST_TMP/rotation $case_name"
    FIXTURE_TRANSCRIPT="$FIXTURE_ROOT/session.jsonl"
    FIXTURE_STATE_DIR="$FIXTURE_ROOT/.token-saver/session-cut"
    mkdir -p "$FIXTURE_STATE_DIR"
    case "$case_name" in
      exact_max) seed='0123456789' ;;
      one_before_max) seed='012345678' ;;
    esac
    printf '%s' "$seed" >"$FIXTURE_STATE_DIR/events.log"
    cat >"$FIXTURE_TRANSCRIPT" <<'EOF'
{"type":"assistant","message":{"id":"rotate-a","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
    payload="$(_payload "$FIXTURE_ROOT" "session-rotation-$case_name" "$FIXTURE_TRANSCRIPT")"
    _run_hook "$payload" "$FIXTURE_ROOT" env \
      CTS_SESSION_CUT_LOG_MAX_BYTES=10 CTS_SESSION_CUT_LOG_BACKUPS=1
    assert_eq "0" "$HOOK_RC" "追記前ローテーションの終了コード $case_name"
    assert_contains "$HOOK_STDOUT" "$SUGGEST_SESSION_CUT_MESSAGE" "追記前ローテーションの提案 $case_name"
    assert_file_exists "$FIXTURE_STATE_DIR/events.log.1" "追記前に既存ログを退避する $case_name"
    rotated_text="$(cat "$FIXTURE_STATE_DIR/events.log.1")"
    assert_eq "$seed" "$rotated_text" "退避ログは追記前の内容だけを持つ $case_name"
    current_log="$(cat "$FIXTURE_STATE_DIR/events.log")"
    assert_contains "$current_log" "boundary=30000000" "追記は新しいevents.logへ行う $case_name"
    assert_not_contains "$current_log" "$seed" "追記後ログへ退避前内容を混ぜない $case_name"
  done
}

test_events_log追記不能時は状態を進めて無出力で終了する() {
  _fixture_repo
  mkdir -p "$FIXTURE_STATE_DIR/events.log"
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"log-write-fail","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-log-write-fail" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "events.log追記不能時の終了コード"
  assert_empty "$HOOK_STDOUT" "events.log追記不能時は提案しない"
  assert_empty "$HOOK_STDERR" "events.log追記不能時の stderr"
  _state_file_text ".cache"
  assert_contains "$CTS_STATE_FILE_TEXT" "total=30000000" "追記失敗前にcacheを更新する"
  _state_file_text ".marker"
  assert_contains "$CTS_STATE_FILE_TEXT" "boundary_index=1" "追記失敗前にmarkerを進める"
  assert_contains "$CTS_STATE_FILE_TEXT" "boundary=30000000" "追記失敗時のmarker境界"

  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "events.log追記不能後の再実行終了コード"
  assert_empty "$HOOK_STDOUT" "events.log追記不能後に即時再提案しない"
  assert_empty "$HOOK_STDERR" "events.log追記不能後の再実行 stderr"
}

test_ログローテーション失敗時は状態を進めて無出力で終了する() {
  _fixture_repo
  mkdir -p "$FIXTURE_STATE_DIR/events.log.1"
  printf 'rotation source' >"$FIXTURE_STATE_DIR/events.log"
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"log-rotate-fail","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-log-rotate-fail" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env \
    CTS_SESSION_CUT_LOG_MAX_BYTES=1 CTS_SESSION_CUT_LOG_BACKUPS=1
  assert_eq "0" "$HOOK_RC" "ログローテーション失敗時の終了コード"
  assert_empty "$HOOK_STDOUT" "ログローテーション失敗時は提案しない"
  assert_empty "$HOOK_STDERR" "ログローテーション失敗時の stderr"
  assert_file_exists "$FIXTURE_STATE_DIR/events.log" "失敗時は元ログを残す"
  assert_eq "rotation source" "$(cat "$FIXTURE_STATE_DIR/events.log")" \
    "失敗時は元ログを変更しない"
  _state_file_text ".marker"
  assert_contains "$CTS_STATE_FILE_TEXT" "boundary=30000000" "ローテーション失敗前にmarkerを進める"

  _run_hook "$payload" "$FIXTURE_ROOT" env \
    CTS_SESSION_CUT_LOG_MAX_BYTES=1 CTS_SESSION_CUT_LOG_BACKUPS=1
  assert_eq "0" "$HOOK_RC" "ローテーション失敗後の再実行終了コード"
  assert_empty "$HOOK_STDOUT" "ローテーション失敗後に即時再提案しない"
  assert_empty "$HOOK_STDERR" "ローテーション失敗後の再実行 stderr"
}

test_ログローテーション途中失敗時も全世代を保持する() {
  _fixture_repo
  mkdir -p "$FIXTURE_STATE_DIR"
  printf 'current generation' >"$FIXTURE_STATE_DIR/events.log"
  printf 'backup generation one' >"$FIXTURE_STATE_DIR/events.log.1"
  printf 'backup generation two' >"$FIXTURE_STATE_DIR/events.log.2"
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"log-rotate-midway-fail","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-log-rotate-midway-fail" "$FIXTURE_TRANSCRIPT")"

  real_mv="$(command -v mv)"
  mkdir -p "$TEST_TMP/bin"
  cat >"$TEST_TMP/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -eq 2 ] && [ "$1" = "$CTS_TEST_FAIL_MV_SOURCE" ] && \
    [ "$2" = "$CTS_TEST_FAIL_MV_DESTINATION" ]; then
  exit 1
fi
exec "$CTS_TEST_REAL_MV" "$@"
EOF
  chmod +x "$TEST_TMP/bin/mv"

  _run_hook "$payload" "$FIXTURE_ROOT" env \
    CTS_SESSION_CUT_LOG_MAX_BYTES=1 CTS_SESSION_CUT_LOG_BACKUPS=2 \
    CTS_TEST_REAL_MV="$real_mv" \
    CTS_TEST_FAIL_MV_SOURCE="$FIXTURE_STATE_DIR/events.log.1" \
    CTS_TEST_FAIL_MV_DESTINATION="$FIXTURE_STATE_DIR/events.log.2"
  assert_eq "0" "$HOOK_RC" "ローテーション途中失敗時の終了コード"
  assert_empty "$HOOK_STDOUT" "ローテーション途中失敗時は提案しない"
  assert_empty "$HOOK_STDERR" "ローテーション途中失敗時の stderr"
  assert_eq "current generation" "$(cat "$FIXTURE_STATE_DIR/events.log")" \
    "途中失敗時も現行ログを保持する"
  assert_eq "backup generation one" "$(cat "$FIXTURE_STATE_DIR/events.log.1")" \
    "途中失敗時も第1世代を保持する"
  assert_eq "backup generation two" "$(cat "$FIXTURE_STATE_DIR/events.log.2")" \
    "途中失敗時も第2世代を保持する"
  rotation_tmp=""
  for candidate in "$FIXTURE_STATE_DIR"/.suggest-session-cut.rotate.*; do
    [ -e "$candidate" ] || continue
    rotation_tmp="$candidate"
  done
  assert_empty "$rotation_tmp" "ロールバック成功時はローテーション退避を残さない"

  _run_hook "$payload" "$FIXTURE_ROOT" env \
    CTS_SESSION_CUT_LOG_MAX_BYTES=1 CTS_SESSION_CUT_LOG_BACKUPS=2 \
    CTS_TEST_REAL_MV="$real_mv" \
    CTS_TEST_FAIL_MV_SOURCE="$FIXTURE_STATE_DIR/events.log.1" \
    CTS_TEST_FAIL_MV_DESTINATION="$FIXTURE_STATE_DIR/events.log.2"
  assert_eq "0" "$HOOK_RC" "ローテーション途中失敗後の再実行終了コード"
  assert_empty "$HOOK_STDOUT" "ローテーション途中失敗後に即時再提案しない"
  assert_empty "$HOOK_STDERR" "ローテーション途中失敗後の再実行 stderr"
}

test_状態書き込み失敗時は提案せずclearも他状態も触らない() {
  _fixture_repo
  mkdir -p "$FIXTURE_ROOT/.token-saver"
  chmod 500 "$FIXTURE_ROOT/.token-saver"
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"ro-a","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-h" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "書き込み失敗でも rc=0"
  assert_empty "$HOOK_STDOUT" "書き込み失敗時は提案しない"
  assert_empty "$HOOK_STDERR" "書き込み失敗でも stderr 空"
  assert_file_missing "$CTS_CLEAR_CALLED" "clear を呼ばない"
  assert_file_missing "$FIXTURE_ROOT/.token-saver/handoff" "handoff へ混ぜない"
  assert_file_missing "$FIXTURE_ROOT/.token-saver/token-report.sh" "token-report へ混ぜない"
}

test_cache更新がtmpからrenameされる() {
  implementation="$(cat "$REPO_ROOT/scripts/suggest-session-cut.sh")"
  assert_contains "$implementation" 'mktemp "$directory/.suggest-session-cut.XXXXXX"' \
    "cacheの一時ファイル"
  assert_contains "$implementation" 'mv "$tmp" "$destination"' \
    "cacheの原子的なrename"
  assert_contains "$implementation" "_cts_cleanup_state" "session状態の掃除"
  assert_contains "$implementation" "_cts_rotate_log" "発火ログのローテーション"
}
