#!/usr/bin/env bash
# handoff-consume.sh（pending → consumed）の検証。
# handoff-check.sh とは別に、手で消費したいときに単体で使える必要がある。

CONSUME="$REPO_ROOT/scripts/handoff-consume.sh"

_setup_project() {
  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/.claude/.handoff/pending"
  export CLAUDE_PROJECT_DIR="$PROJ"
}

_write_pending() {
  printf '%s\n' "$2" >"$PROJ/.claude/.handoff/pending/$1"
}

_run_consume() {
  bash "$CONSUME" "$@" >"$TEST_TMP/.out" 2>"$TEST_TMP/.err"
  CONSUME_STATUS=$?
  CONSUME_ERR="$(cat "$TEST_TMP/.err")"
}

test_引数なしで_pending_の全ファイルを移す() {
  _setup_project
  _write_pending "a.md" "A"
  _write_pending "b.md" "B"
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/a.md"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/b.md"
  assert_empty "$(ls -A "$PROJ/.claude/.handoff/pending")" "pending の残存"
}

test_パスを指定するとそのファイルのみ移す() {
  _setup_project
  _write_pending "a.md" "A"
  _write_pending "b.md" "B"
  _run_consume "$PROJ/.claude/.handoff/pending/a.md"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/a.md"
  assert_file_exists "$PROJ/.claude/.handoff/pending/b.md"
  assert_file_missing "$PROJ/.claude/.handoff/consumed/b.md"
}

test_pending_が空でも終了コード0で何も壊さない() {
  _setup_project
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_empty "$CONSUME_ERR" "標準エラー"
}

test_pending_ディレクトリが無くても終了コード0() {
  _setup_project
  rm -rf "$PROJ/.claude/.handoff"
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
}

test_移した内容は失われない() {
  _setup_project
  _write_pending "a.md" "残るべき本文"
  _run_consume
  assert_contains "$(cat "$PROJ/.claude/.handoff/consumed/a.md")" "残るべき本文" "consumed の内容"
}

test_同名ファイルが_consumed_にあっても既存を上書きしない() {
  _setup_project
  mkdir -p "$PROJ/.claude/.handoff/consumed"
  printf '先に消費した内容\n' >"$PROJ/.claude/.handoff/consumed/a.md"
  _write_pending "a.md" "新しい内容"
  _run_consume
  assert_contains "$(cat "$PROJ/.claude/.handoff/consumed/a.md")" "先に消費した内容" "既存の consumed"
  assert_empty "$(ls -A "$PROJ/.claude/.handoff/pending")" "pending の残存"
  # 新しい内容も別名でどこかに残っているべきである。
  assert_contains "$(cat "$PROJ"/.claude/.handoff/consumed/a.md.*)" "新しい内容" "退避先の内容"
}

# 無音で成功扱いにすると、タイプミスが「消費できたつもり」に化ける。
test_存在しないパスを指定したら失敗して理由を示す() {
  _setup_project
  _run_consume "$PROJ/.claude/.handoff/pending/nope.md"
  assert_ne "0" "$CONSUME_STATUS" "終了コード"
  assert_contains "$CONSUME_ERR" "nope.md" "標準エラー"
}

test_ディレクトリを指定したら失敗する() {
  _setup_project
  mkdir -p "$PROJ/.claude/.handoff/pending/draft"
  _run_consume "$PROJ/.claude/.handoff/pending/draft"
  assert_ne "0" "$CONSUME_STATUS" "終了コード"
  assert_contains "$CONSUME_ERR" "draft" "標準エラー"
}

# 不正な引数で落ちても、正しい引数の分は処理を試みたことが分かること。
test_不正な引数があっても正しい引数は消費する() {
  _setup_project
  _write_pending "a.md" "A"
  _run_consume "$PROJ/.claude/.handoff/pending/a.md" "$PROJ/.claude/.handoff/pending/nope.md"
  assert_ne "0" "$CONSUME_STATUS" "終了コード"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/a.md"
}

test_ハイフンで始まるパスでも壊れない() {
  _setup_project
  printf 'ハイフン名の本文\n' >"$PROJ/.claude/.handoff/pending/-n.md"
  ( cd "$PROJ/.claude/.handoff/pending" && bash "$CONSUME" -n.md >"$TEST_TMP/.out" 2>"$TEST_TMP/.err" )
  CONSUME_STATUS=$?
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/-n.md"
}

test_ダブルダッシュ以降は引数として扱う() {
  _setup_project
  printf 'ハイフン名の本文\n' >"$PROJ/.claude/.handoff/pending/-n.md"
  _run_consume -- "$PROJ/.claude/.handoff/pending/-n.md"
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/-n.md"
}

test_引数なしでもハイフン始まりのファイルを移せる() {
  _setup_project
  printf 'A\n' >"$PROJ/.claude/.handoff/pending/-n.md"
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_empty "$CONSUME_ERR" "標準エラー"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/-n.md"
}

test_改行を含むファイル名でも移せる() {
  _setup_project
  printf 'A\n' >"$PROJ/.claude/.handoff/pending/$(printf 'a\nb').md"
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_empty "$(ls -A "$PROJ/.claude/.handoff/pending")" "pending の残存"
}

# CLAUDE_PROJECT_DIR が無い環境では CWD を導入先とみなす。
test_CLAUDE_PROJECT_DIR_が無いときは_PWD_を使う() {
  _setup_project
  unset CLAUDE_PROJECT_DIR
  mkdir -p "$PWD/.claude/.handoff/pending"
  printf 'PWD 側\n' >"$PWD/.claude/.handoff/pending/a.md"
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_file_exists "$PWD/.claude/.handoff/consumed/a.md"
  # CLAUDE_PROJECT_DIR 側は触られていないこと。
  assert_file_exists "$PROJ/.claude/.handoff/pending"
}

# root は権限ビットを無視する。chmod に依存するテストは成立しないので飛ばす。
_skip_if_root() {
  if [ "$(id -u)" -eq 0 ]; then
    printf '    skip: root では権限ビットが効かない\n'
    return 0
  fi
  return 1
}

# 一括処理での失敗を握りつぶすと、消費できていないのに成功として返る。
# 呼び出し側（人・スクリプト）は「消費できたつもり」で pending を放置する。
test_一括消費で移動に失敗したら終了コードで知らせる() {
  _skip_if_root && return 0
  _setup_project
  _write_pending "a.md" "A"
  chmod 555 "$PROJ/.claude/.handoff/pending"
  _run_consume
  chmod 755 "$PROJ/.claude/.handoff/pending"
  assert_ne "0" "$CONSUME_STATUS" "終了コード"
  assert_file_exists "$PROJ/.claude/.handoff/pending/a.md"
}

test_サブディレクトリは移動対象にしない() {
  _setup_project
  mkdir -p "$PROJ/.claude/.handoff/pending/draft"
  _write_pending "a.md" "A"
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_file_exists "$PROJ/.claude/.handoff/pending/draft"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/a.md"
}
