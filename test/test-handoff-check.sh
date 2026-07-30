#!/usr/bin/env bash
# handoff-check.sh（SessionStart フック）の検証。

HOOK="$REPO_ROOT/scripts/handoff-check.sh"

# 導入先リポジトリを模したディレクトリを作る。
_setup_project() {
  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/.claude/.handoff/pending" "$PROJ/.claude/.handoff/consumed"
  export CLAUDE_PROJECT_DIR="$PROJ"
}

# pending に引き継ぎファイルを置く。
_write_pending() {
  local name="$1" body="$2"
  printf '%s\n' "$body" >"$PROJ/.claude/.handoff/pending/$name"
}

# フックを実行する。標準出力は $HOOK_OUT、終了コードは $HOOK_STATUS に入る。
# コマンド置換ではなく変数に直接入れるのは、サブシェルだと終了コードを持ち帰れないため。
_run_hook() {
  local payload="${1:-}"
  printf '%s' "$payload" | bash "$HOOK" >"$TEST_TMP/.hook-out" 2>"$TEST_TMP/.hook-err"
  HOOK_STATUS=$?
  HOOK_OUT="$(cat "$TEST_TMP/.hook-out")"
}

_startup_payload() {
  printf '{"session_id":"abc","source":"startup","cwd":"%s"}' "$PROJ"
}

test_pending_が空なら無出力で終了コード0() {
  _setup_project
  local out
  _run_hook "$(_startup_payload)"
  out="$HOOK_OUT"
  assert_eq "0" "$HOOK_STATUS" "終了コード"
  assert_empty "$out"
}

test_handoff_ディレクトリ自体が無くても無出力で終了コード0() {
  _setup_project
  rm -rf "$PROJ/.claude/.handoff"
  local out
  _run_hook "$(_startup_payload)"
  out="$HOOK_OUT"
  assert_eq "0" "$HOOK_STATUS" "終了コード"
  assert_empty "$out"
}

test_pending_にファイルがあれば中身を出力する() {
  _setup_project
  _write_pending "2026-07-31-1840-643-stage.md" "# 引き継ぎ (2026-07-31 18:40)
## 次の一手
- 倉庫からの出庫を実装する"
  local out
  _run_hook "$(_startup_payload)"
  out="$HOOK_OUT"
  assert_eq "0" "$HOOK_STATUS" "終了コード"
  assert_contains "$out" "倉庫からの出庫を実装する" "フック出力"
}

test_出力後に_consumed_へ移動する() {
  _setup_project
  _write_pending "2026-07-31-1840-643-stage.md" "本文"
  _run_hook "$(_startup_payload)"
  assert_file_missing "$PROJ/.claude/.handoff/pending/2026-07-31-1840-643-stage.md"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/2026-07-31-1840-643-stage.md"
}

test_consumed_へ移動したファイルの中身は失われない() {
  _setup_project
  _write_pending "2026-07-31-1840-643-stage.md" "消えてはいけない本文"
  _run_hook "$(_startup_payload)"
  assert_contains "$(cat "$PROJ/.claude/.handoff/consumed/2026-07-31-1840-643-stage.md")" \
    "消えてはいけない本文" "consumed のファイル内容"
}

test_発火源が_compact_のときは発火しない() {
  _setup_project
  _write_pending "2026-07-31-1840-643-stage.md" "本文"
  local out
  _run_hook "$(printf '{"source":"compact","cwd":"%s"}' "$PROJ")"
  out="$HOOK_OUT"
  assert_eq "0" "$HOOK_STATUS" "終了コード"
  assert_empty "$out"
  assert_file_exists "$PROJ/.claude/.handoff/pending/2026-07-31-1840-643-stage.md"
}

test_発火源が_clear_のときは発火する() {
  _setup_project
  _write_pending "a.md" "clear でも読む"
  local out
  _run_hook "$(printf '{"source":"clear","cwd":"%s"}' "$PROJ")"
  out="$HOOK_OUT"
  assert_contains "$out" "clear でも読む" "フック出力"
}

test_発火源が_resume_のときは発火する() {
  _setup_project
  _write_pending "a.md" "resume でも読む"
  local out
  _run_hook "$(printf '{"source":"resume","cwd":"%s"}' "$PROJ")"
  out="$HOOK_OUT"
  assert_contains "$out" "resume でも読む" "フック出力"
}

test_未知の発火源では発火しない() {
  _setup_project
  _write_pending "a.md" "本文"
  local out
  _run_hook "$(printf '{"source":"someday-new-source","cwd":"%s"}' "$PROJ")"
  out="$HOOK_OUT"
  assert_empty "$out"
  assert_file_exists "$PROJ/.claude/.handoff/pending/a.md"
}

test_複数ファイルはファイル名の昇順ですべて出力される() {
  _setup_project
  _write_pending "2026-07-31-1840-643-second.md" "二番目の引き継ぎ"
  _write_pending "2026-07-30-0900-101-first.md" "一番目の引き継ぎ"
  local out
  _run_hook "$(_startup_payload)"
  out="$HOOK_OUT"
  assert_contains "$out" "一番目の引き継ぎ" "フック出力"
  assert_contains "$out" "二番目の引き継ぎ" "フック出力"

  local first_pos second_pos
  first_pos="${out%%一番目の引き継ぎ*}"
  second_pos="${out%%二番目の引き継ぎ*}"
  if [ "${#first_pos}" -ge "${#second_pos}" ]; then
    _fail "古い引き継ぎが先に出力されていない"
  fi
}

test_複数ファイルはすべて_consumed_へ移動する() {
  _setup_project
  _write_pending "a.md" "A"
  _write_pending "b.md" "B"
  _run_hook "$(_startup_payload)"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/a.md"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/b.md"
  assert_empty "$(ls -A "$PROJ/.claude/.handoff/pending")" "pending の残存"
}

test_出力には要約して指示を待つ旨の指示が含まれる() {
  _setup_project
  _write_pending "a.md" "本文"
  local out
  _run_hook "$(_startup_payload)"
  out="$HOOK_OUT"
  assert_contains "$out" "要約" "フック出力"
}

test_標準入力が空でも終了コード0で抜ける() {
  _setup_project
  _write_pending "a.md" "本文"
  local out
  _run_hook ""
  out="$HOOK_OUT"
  assert_eq "0" "$HOOK_STATUS" "終了コード"
}

test_壊れた_JSON_でも終了コード0で抜ける() {
  _setup_project
  _write_pending "a.md" "本文"
  _run_hook '{"source": '
  assert_eq "0" "$HOOK_STATUS" "終了コード"
}

test_consumed_ディレクトリが無ければ作成する() {
  _setup_project
  rm -rf "$PROJ/.claude/.handoff/consumed"
  _write_pending "a.md" "本文"
  _run_hook "$(_startup_payload)"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/a.md"
}

test_同名ファイルが_consumed_にあっても既存を上書きしない() {
  _setup_project
  printf '先に消費した内容\n' >"$PROJ/.claude/.handoff/consumed/a.md"
  _write_pending "a.md" "新しい内容"
  _run_hook "$(_startup_payload)"
  assert_contains "$(cat "$PROJ/.claude/.handoff/consumed/a.md")" \
    "先に消費した内容" "既存の consumed ファイル"
  assert_empty "$(ls -A "$PROJ/.claude/.handoff/pending")" "pending の残存"
}

test_CLAUDE_PROJECT_DIR_が無いときは_JSON_の_cwd_を使う() {
  _setup_project
  _write_pending "a.md" "cwd から見つけた"
  unset CLAUDE_PROJECT_DIR
  local out
  _run_hook "$(printf '{"source":"startup","cwd":"%s"}' "$PROJ")"
  out="$HOOK_OUT"
  assert_contains "$out" "cwd から見つけた" "フック出力"
}
