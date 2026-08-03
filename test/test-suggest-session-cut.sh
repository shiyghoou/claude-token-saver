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

  trailing_broken="$(printf '{"cwd":"%s","session_id":"broken-tail","transcript_path":"%s",BROKEN' \
    "$FIXTURE_ROOT" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$trailing_broken" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "有効フィールド後に壊れた payload でも rc=0"
  assert_empty "$HOOK_STDOUT" "payload全体が壊れていれば提案しない"
  assert_empty "$HOOK_STDERR" "有効フィールド後に壊れた payload でも stderr 空"

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

test_末尾が壊れた設定JSONは対象値を採用しない() {
  _fixture_repo
  mkdir -p "$FIXTURE_ROOT/.claude"
  printf '%s\n' '{"suggest_session_cut":{"initial_cache_read":20}}BROKEN' \
    >"$FIXTURE_ROOT/.claude/token-saver.json"
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"cfg-broken-tail","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":20,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-config-broken-tail" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "末尾が壊れた設定JSONの終了コード"
  assert_empty "$HOOK_STDOUT" "末尾が壊れた設定値20を採用しない"
  assert_empty "$HOOK_STDERR" "末尾が壊れた設定JSONの stderr"
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

test_実Git_worktreeではworktree_rootへ状態を書きgitdir配下へ書かない() {
  local source_repo gitdir_path git_state_hits
  source_repo="$TEST_TMP/source repo"
  FIXTURE_ROOT="$TEST_TMP/linked worktree"
  FIXTURE_TRANSCRIPT="$FIXTURE_ROOT/session.jsonl"
  FIXTURE_STATE_DIR="$FIXTURE_ROOT/.token-saver/session-cut"

  git init -q "$source_repo"
  git -C "$source_repo" config user.name "claude-token-saver test"
  git -C "$source_repo" config user.email "test@example.invalid"
  printf 'seed\n' >"$source_repo/seed.txt"
  git -C "$source_repo" add seed.txt
  git -C "$source_repo" commit -q -m seed
  git -C "$source_repo" worktree add -q -b fixture-linked-worktree "$FIXTURE_ROOT"
  [ -f "$FIXTURE_ROOT/.git" ] || _fail "linked worktree の .git がファイルではない"
  assert_contains "$(cat "$FIXTURE_ROOT/.git")" "gitdir:" "linked worktree の gitdir 指定"
  gitdir_path="$(git -C "$FIXTURE_ROOT" rev-parse --git-dir)"
  [ -d "$gitdir_path" ] || _fail "linked worktree の gitdir が有効ではない: $gitdir_path"

  mkdir -p "$FIXTURE_ROOT/nested dir"
  cat >"$FIXTURE_TRANSCRIPT" <<'EOF'
{"type":"assistant","message":{"id":"real-worktree","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT/nested dir" "session-real-worktree" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT/nested dir" env
  assert_eq "0" "$HOOK_RC" "実worktreeの終了コード"
  assert_contains "$HOOK_STDOUT" "$SUGGEST_SESSION_CUT_MESSAGE" "実worktreeの提案"
  assert_empty "$HOOK_STDERR" "実worktreeの stderr"
  assert_file_exists "$FIXTURE_STATE_DIR" "worktree root の state dir"
  _pick_state_file ".cache"
  assert_file_exists "$CTS_PICKED_STATE_FILE" "worktree root の cache"
  _pick_state_file ".marker"
  assert_file_exists "$CTS_PICKED_STATE_FILE" "worktree root の marker"
  git_state_hits="$(find "$source_repo/.git" -path '*session-cut*' -print 2>/dev/null)"
  assert_empty "$git_state_hits" "gitdir/.git配下へsession-cut状態を書かない"
  assert_file_missing "$gitdir_path/.token-saver" "worktree gitdir配下へ状態を書かない"
}

test_state_dirのlock競合時は状態も出力も変更しない() {
  _fixture_repo
  mkdir -p "$FIXTURE_STATE_DIR/.suggest-session-cut.lock"
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"locked-a","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-locked" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "lock競合時の終了コード"
  assert_empty "$HOOK_STDOUT" "lock競合時は提案しない"
  assert_empty "$HOOK_STDERR" "lock競合時の stderr"
  _pick_state_file ".cache"
  assert_empty "$CTS_PICKED_STATE_FILE" "lock競合時はcacheを書かない"
  assert_file_missing "$FIXTURE_STATE_DIR/events.log" "lock競合時はlogを書かない"
}

test_同時実行でも同じ境界を二重提案しない() {
  _fixture_repo
  mkdir -p "$FIXTURE_STATE_DIR" "$TEST_TMP/bin"
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"concurrent-a","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-concurrent" "$FIXTURE_TRANSCRIPT")"
  real_mkdir="$(command -v mkdir)"
  lock_dir="$FIXTURE_STATE_DIR/.suggest-session-cut.lock"
  lock_ready="$TEST_TMP/lock.ready"
  lock_release="$TEST_TMP/lock.release"
  cat >"$TEST_TMP/bin/mkdir" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "${1##*/}" = ".suggest-session-cut.lock" ]; then
  "$CTS_TEST_REAL_MKDIR" "$@" || exit 1
  : >"$CTS_TEST_LOCK_READY"
  while [ ! -e "$CTS_TEST_LOCK_RELEASE" ]; do
    sleep 0.02
  done
  exit 0
fi
exec "$CTS_TEST_REAL_MKDIR" "$@"
EOF
  chmod +x "$TEST_TMP/bin/mkdir"

  first_out="$TEST_TMP/concurrent-first.stdout"
  first_err="$TEST_TMP/concurrent-first.stderr"
  second_out="$TEST_TMP/concurrent-second.stdout"
  second_err="$TEST_TMP/concurrent-second.stderr"
  printf '%s\n' "$payload" | PATH="$TEST_TMP/bin:$PATH" \
    CTS_TEST_LOCK_DIR="$lock_dir" CTS_TEST_LOCK_READY="$lock_ready" \
    CTS_TEST_LOCK_RELEASE="$lock_release" CTS_TEST_REAL_MKDIR="$real_mkdir" \
    bash "$REPO_ROOT/scripts/suggest-session-cut.sh" >"$first_out" 2>"$first_err" &
  first_pid=$!
  wait_count=0
  while [ ! -e "$lock_ready" ] && kill -0 "$first_pid" 2>/dev/null && [ "$wait_count" -lt 100 ]; do
    sleep 0.02
    wait_count=$((wait_count + 1))
  done
  if [ ! -e "$lock_ready" ]; then
    wait "$first_pid" 2>/dev/null || true
    _fail "同時実行テストで先行プロセスがlockを取得しなかった"
  fi

  printf '%s\n' "$payload" | PATH="$TEST_TMP/bin:$PATH" \
    CTS_TEST_LOCK_DIR="$lock_dir" CTS_TEST_LOCK_READY="$lock_ready" \
    CTS_TEST_LOCK_RELEASE="$lock_release" CTS_TEST_REAL_MKDIR="$real_mkdir" \
    bash "$REPO_ROOT/scripts/suggest-session-cut.sh" >"$second_out" 2>"$second_err"
  second_rc=$?
  : >"$lock_release"
  wait "$first_pid"
  first_rc=$?

  assert_eq "0" "$first_rc" "先行同時実行の終了コード"
  assert_eq "0" "$second_rc" "競合同時実行の終了コード"
  combined_output="$(cat "$first_out" "$second_out")"
  assert_count "1" "$combined_output" "$SUGGEST_SESSION_CUT_MESSAGE" \
    "同じ境界の同時提案は1回だけ"
  assert_empty "$(cat "$first_err")" "先行同時実行の stderr"
  assert_empty "$(cat "$second_err")" "競合同時実行の stderr"
  assert_file_missing "$lock_dir" "正常終了時はlockを解放する"
}

test_ロック取得直前にstate_dirが差し替わっても外部へ書かない() {
  _fixture_repo
  mkdir -p "$FIXTURE_STATE_DIR" "$TEST_TMP/bin"
  outside="$TEST_TMP/toctou-outside"
  real_state="$TEST_TMP/toctou-state-real"
  swap_done="$TEST_TMP/toctou-swap.done"
  mkdir -p "$outside"
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"toctou-state","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-toctou-state" "$FIXTURE_TRANSCRIPT")"
  real_mkdir="$(command -v mkdir)"
  cat >"$TEST_TMP/bin/mkdir" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "${1##*/}" = ".suggest-session-cut.lock" ] &&
    [ ! -e "$CTS_TEST_SWAP_DONE" ]; then
  mv "$CTS_TEST_STATE_PATH" "$CTS_TEST_REAL_STATE" || exit 1
  ln -s "$CTS_TEST_OUTSIDE" "$CTS_TEST_STATE_PATH" || exit 1
  : >"$CTS_TEST_SWAP_DONE"
fi
exec "$CTS_TEST_REAL_MKDIR" "$@"
EOF
  chmod +x "$TEST_TMP/bin/mkdir"

  _run_hook "$payload" "$FIXTURE_ROOT" env \
    CTS_TEST_REAL_MKDIR="$real_mkdir" \
    CTS_TEST_STATE_PATH="$FIXTURE_STATE_DIR" \
    CTS_TEST_REAL_STATE="$real_state" \
    CTS_TEST_OUTSIDE="$outside" \
    CTS_TEST_SWAP_DONE="$swap_done"
  assert_eq "0" "$HOOK_RC" "state_dir差し替え時の終了コード"
  assert_empty "$HOOK_STDERR" "state_dir差し替え時の stderr"
  assert_file_exists "$swap_done" "state_dir差し替え注入が実行される"
  assert_empty "$(find "$outside" -mindepth 1 -print 2>/dev/null)" \
    "state_dir差し替え後も外部ディレクトリへ書かない"
  assert_file_missing "$real_state/.suggest-session-cut.lock" \
    "state_dir差し替え後も物理state dirのlockを解放する"
}

test_ライブlockは尊重しstale_lockだけを回収する() {
  _fixture_repo
  mkdir -p "$FIXTURE_STATE_DIR"
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"stale-lock","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-stale-lock" "$FIXTURE_TRANSCRIPT")"
  lock_dir="$FIXTURE_STATE_DIR/.suggest-session-cut.lock"

  mkdir "$lock_dir"
  printf 'pid=%s\n' "$$" >"$lock_dir/owner"
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "ライブlock競合時の終了コード"
  assert_empty "$HOOK_STDOUT" "ライブlock競合時は提案しない"
  assert_file_exists "$lock_dir" "ライブlockを回収しない"
  rm -f "$lock_dir/owner"
  rmdir "$lock_dir"

  mkdir "$lock_dir"
  printf 'pid=999999999\n' >"$lock_dir/owner"
  touch -t 200001010000 "$lock_dir"
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "stale lock回収時の終了コード"
  assert_contains "$HOOK_STDOUT" "$SUGGEST_SESSION_CUT_MESSAGE" \
    "stale lock回収後に提案する"
  assert_file_missing "$lock_dir" "stale lockを回収して正常終了する"
}

test_state_dir構成要素がsymlinkならroot外へ書かない() {
  for link_kind in base state; do
    FIXTURE_ROOT="$TEST_TMP/symlink-dir-$link_kind"
    FIXTURE_TRANSCRIPT="$FIXTURE_ROOT/session.jsonl"
    FIXTURE_STATE_DIR="$FIXTURE_ROOT/.token-saver/session-cut"
    outside="$TEST_TMP/outside-dir-$link_kind"
    mkdir -p "$FIXTURE_ROOT" "$outside"
    if [ "$link_kind" = base ]; then
      ln -s "$outside" "$FIXTURE_ROOT/.token-saver"
    else
      mkdir -p "$FIXTURE_ROOT/.token-saver"
      ln -s "$outside" "$FIXTURE_STATE_DIR"
    fi
    cat >"$FIXTURE_TRANSCRIPT" <<'EOF'
{"type":"assistant","message":{"id":"symlink-dir","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
    payload="$(_payload "$FIXTURE_ROOT" "session-symlink-dir-$link_kind" "$FIXTURE_TRANSCRIPT")"
    _run_hook "$payload" "$FIXTURE_ROOT" env
    assert_eq "0" "$HOOK_RC" "state dir symlink時の終了コード $link_kind"
    assert_empty "$HOOK_STDOUT" "state dir symlink時は提案しない $link_kind"
    assert_empty "$HOOK_STDERR" "state dir symlink時の stderr $link_kind"
    assert_file_missing "$outside/events.log" "root外へlogを書かない $link_kind"
    outside_files="$(find "$outside" -mindepth 1 -print 2>/dev/null)"
    assert_empty "$outside_files" "root外へ状態を書かない $link_kind"
  done
}

test_cacheとmarkerのsymlinkを置換せず提案しない() {
  for state_kind in cache marker; do
    FIXTURE_ROOT="$TEST_TMP/symlink-state-$state_kind"
    FIXTURE_TRANSCRIPT="$FIXTURE_ROOT/session.jsonl"
    FIXTURE_STATE_DIR="$FIXTURE_ROOT/.token-saver/session-cut"
    mkdir -p "$FIXTURE_ROOT"
    if [ "$state_kind" = cache ]; then
      first_total=1
    else
      first_total=30000000
    fi
    printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"id\":\"symlink-state-first\",\"usage\":{\"input_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":$first_total,\"output_tokens\":0}}}" \
      >"$FIXTURE_TRANSCRIPT"
    payload="$(_payload "$FIXTURE_ROOT" "session-symlink-state-$state_kind" "$FIXTURE_TRANSCRIPT")"
    _run_hook "$payload" "$FIXTURE_ROOT" env
    _pick_state_file ".$state_kind"
    state_path="$CTS_PICKED_STATE_FILE"
    [ -n "$state_path" ] || _fail "symlink化する $state_kind が作成されなかった"
    outside="$TEST_TMP/outside-$state_kind"
    cp "$state_path" "$outside"
    outside_before="$(cat "$outside")"
    rm -f "$state_path"
    ln -s "$outside" "$state_path"
    printf '%s\n' '{"type":"assistant","message":{"id":"symlink-state-second","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":60000000,"output_tokens":0}}}' \
      >"$FIXTURE_TRANSCRIPT"

    _run_hook "$payload" "$FIXTURE_ROOT" env
    assert_eq "0" "$HOOK_RC" "$state_kind symlink時の終了コード"
    assert_empty "$HOOK_STDOUT" "$state_kind symlink時は提案しない"
    assert_empty "$HOOK_STDERR" "$state_kind symlink時の stderr"
    [ -L "$state_path" ] || _fail "$state_kind symlinkを置換してはいけない"
    assert_eq "$outside_before" "$(cat "$outside")" "$state_kind symlink先を変更しない"
  done
}

test_events_logとローテーション世代のsymlinkを追従しない() {
  for log_kind in current generation; do
    FIXTURE_ROOT="$TEST_TMP/symlink-log-$log_kind"
    FIXTURE_TRANSCRIPT="$FIXTURE_ROOT/session.jsonl"
    FIXTURE_STATE_DIR="$FIXTURE_ROOT/.token-saver/session-cut"
    outside="$TEST_TMP/outside-log-$log_kind"
    mkdir -p "$FIXTURE_STATE_DIR"
    printf 'outside-safe' >"$outside"
    if [ "$log_kind" = current ]; then
      ln -s "$outside" "$FIXTURE_STATE_DIR/events.log"
      log_max=1048576
    else
      printf 'rotation-source' >"$FIXTURE_STATE_DIR/events.log"
      ln -s "$outside" "$FIXTURE_STATE_DIR/events.log.1"
      log_max=1
    fi
    cat >"$FIXTURE_TRANSCRIPT" <<'EOF'
{"type":"assistant","message":{"id":"symlink-log","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
    payload="$(_payload "$FIXTURE_ROOT" "session-symlink-log-$log_kind" "$FIXTURE_TRANSCRIPT")"
    _run_hook "$payload" "$FIXTURE_ROOT" env \
      CTS_SESSION_CUT_LOG_MAX_BYTES="$log_max" CTS_SESSION_CUT_LOG_BACKUPS=2
    assert_eq "0" "$HOOK_RC" "$log_kind log symlink時の終了コード"
    assert_empty "$HOOK_STDOUT" "$log_kind log symlink時は提案しない"
    assert_empty "$HOOK_STDERR" "$log_kind log symlink時の stderr"
    assert_eq "outside-safe" "$(cat "$outside")" "$log_kind log symlink先を変更しない"
    if [ "$log_kind" = current ]; then
      [ -L "$FIXTURE_STATE_DIR/events.log" ] || _fail "events.log symlinkを置換してはいけない"
    else
      [ -L "$FIXTURE_STATE_DIR/events.log.1" ] || _fail "events.log.1 symlinkを移動してはいけない"
    fi
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

test_新しいcacheと対になる古いmarkerを削除せず再提案しない() {
  _fixture_repo
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"marker-pair","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-marker-pair" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env CTS_SESSION_CUT_RETENTION_DAYS=1
  assert_contains "$HOOK_STDOUT" "$SUGGEST_SESSION_CUT_MESSAGE" "初回境界を提案する"
  _pick_state_file ".marker"
  marker_path="$CTS_PICKED_STATE_FILE"
  touch -t 200001010000 "$marker_path"

  _run_hook "$payload" "$FIXTURE_ROOT" env CTS_SESSION_CUT_RETENTION_DAYS=1
  assert_eq "0" "$HOOK_RC" "cacheが新しいときの古いmarker処理終了コード"
  assert_empty "$HOOK_STDOUT" "古いmarkerだけを消して同じ境界を再提案しない"
  assert_empty "$HOOK_STDERR" "cacheが新しいときの古いmarker処理 stderr"
  assert_file_exists "$marker_path" "新しいcacheと対になるmarkerを保持する"
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
if [ "$#" -eq 2 ] && [ "${1##*/}" = "${CTS_TEST_FAIL_MV_SOURCE##*/}" ] && \
    [ "${2##*/}" = "${CTS_TEST_FAIL_MV_DESTINATION##*/}" ]; then
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

test_巨大log_backupsでも実在世代数に比例して速やかに完了する() {
  _fixture_repo
  mkdir -p "$FIXTURE_STATE_DIR"
  printf 'rotation-source' >"$FIXTURE_STATE_DIR/events.log"
  printf 'previous-generation' >"$FIXTURE_STATE_DIR/events.log.1"
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"huge-backups","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-huge-backups" "$FIXTURE_TRANSCRIPT")"
  bounded_out="$TEST_TMP/huge-backups.stdout"
  bounded_err="$TEST_TMP/huge-backups.stderr"
  printf '%s\n' "$payload" | env CTS_SESSION_CUT_LOG_MAX_BYTES=1 \
    CTS_SESSION_CUT_LOG_BACKUPS=1000000000000000000000000 \
    bash "$REPO_ROOT/scripts/suggest-session-cut.sh" >"$bounded_out" 2>"$bounded_err" &
  hook_pid=$!
  completed=0
  for wait_second in 1 2 3; do
    sleep 1
    if ! kill -0 "$hook_pid" 2>/dev/null; then
      completed=1
      break
    fi
  done
  if [ "$completed" -eq 0 ]; then
    kill "$hook_pid" 2>/dev/null || true
    wait "$hook_pid" 2>/dev/null || true
    _fail "巨大log_backupsの処理が3秒以内に完了しなかった"
  fi
  wait "$hook_pid"
  hook_rc=$?
  assert_eq "0" "$hook_rc" "巨大log_backupsの終了コード"
  assert_contains "$(cat "$bounded_out")" "$SUGGEST_SESSION_CUT_MESSAGE" \
    "巨大log_backupsでも提案を完了する"
  assert_empty "$(cat "$bounded_err")" "巨大log_backupsの stderr"
  assert_file_exists "$FIXTURE_STATE_DIR/events.log.1" "巨大log_backupsでも現行ログを退避する"
  assert_eq "previous-generation" "$(cat "$FIXTURE_STATE_DIR/events.log.2")" \
    "巨大log_backupsでも既存世代を失わない"
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

test_SCRIPT_DIR解決時のdirname失敗でも無音で終了する() {
  local dirname_called="$TEST_TMP/dirname.called"
  mkdir -p "$TEST_TMP/bin"
  cat >"$TEST_TMP/bin/dirname" <<'EOF'
#!/usr/bin/env bash
printf 'dirname wrapper failure\n' >&2
touch "$CTS_TEST_DIRNAME_CALLED"
exit 1
EOF
  chmod +x "$TEST_TMP/bin/dirname"

  _run_hook '{}' "$TEST_TMP" env CTS_TEST_DIRNAME_CALLED="$dirname_called"
  assert_file_exists "$dirname_called" "PATH上のdirnameラッパーが実行される"
  assert_eq "0" "$HOOK_RC" "dirname失敗時の終了コード"
  assert_empty "$HOOK_STDOUT" "dirname失敗時の stdout"
  assert_empty "$HOOK_STDERR" "dirname失敗時の stderr"
}

test_cache更新がtmpからrenameされる() {
  implementation="$(cat "$REPO_ROOT/scripts/suggest-session-cut.sh")"
  assert_contains "$implementation" 'dirname "${BASH_SOURCE[0]}"' \
    "SCRIPT_DIRのsource path解決"
  assert_contains "$implementation" '2>/dev/null && pwd -P 2>/dev/null' \
    "SCRIPT_DIR解決失敗時のstderr抑止"
  assert_contains "$implementation" 'mktemp "$directory/.suggest-session-cut.XXXXXX"' \
    "cacheの一時ファイル"
  assert_contains "$implementation" 'mv "$tmp" "$destination"' \
    "cacheの原子的なrename"
  assert_contains "$implementation" "_cts_cleanup_state" "session状態の掃除"
  assert_contains "$implementation" "_cts_rotate_log" "発火ログのローテーション"
}

test_cacheのrename失敗時は旧状態を保持して提案しない() {
  local payload cache_path cache_before real_mv
  _fixture_repo
  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"rename-cache-old","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":1,"output_tokens":0}}}
EOF
  payload="$(_payload "$FIXTURE_ROOT" "session-cache-rename-fail" "$FIXTURE_TRANSCRIPT")"
  _run_hook "$payload" "$FIXTURE_ROOT" env
  assert_eq "0" "$HOOK_RC" "rename失敗注入前の終了コード"
  assert_empty "$HOOK_STDOUT" "rename失敗注入前は境界未満"
  _pick_state_file ".cache"
  cache_path="$CTS_PICKED_STATE_FILE"
  [ -n "$cache_path" ] || _fail "rename失敗注入前の cache が無い"
  cache_before="$(cat "$cache_path")"

  _write_transcript <<'EOF'
{"type":"assistant","message":{"id":"rename-cache-new","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":30000000,"output_tokens":0}}}
EOF
  real_mv="$(command -v mv)"
  cat >"$TEST_TMP/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -eq 2 ] && [ "${2##*/}" = "${CTS_TEST_FAIL_MV_DESTINATION##*/}" ]; then
  exit 1
fi
exec "$CTS_TEST_REAL_MV" "$@"
EOF
  chmod +x "$TEST_TMP/bin/mv"
  _run_hook "$payload" "$FIXTURE_ROOT" env \
    CTS_TEST_REAL_MV="$real_mv" CTS_TEST_FAIL_MV_DESTINATION="$cache_path"
  assert_eq "0" "$HOOK_RC" "cache rename失敗時の終了コード"
  assert_empty "$HOOK_STDOUT" "cache rename失敗時は提案しない"
  assert_empty "$HOOK_STDERR" "cache rename失敗時の stderr"
  assert_eq "$cache_before" "$(cat "$cache_path")" "cache rename失敗時は旧状態を保持する"
  _pick_state_file ".marker"
  assert_empty "$CTS_PICKED_STATE_FILE" "cache rename失敗時はmarkerを作らない"
  assert_eq "0" "$(_count_tmp_files)" "cache rename失敗時はtmpを残さない"
  assert_file_missing "$CTS_CLEAR_CALLED" "cache rename失敗時もclearを呼ばない"
}
