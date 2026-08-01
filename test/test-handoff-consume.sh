#!/usr/bin/env bash
# handoff-consume.sh（pending → consumed）の検証。
# handoff-check.sh とは別に、手で消費したいときに単体で使える必要がある。

CONSUME="$REPO_ROOT/scripts/handoff-consume.sh"

_setup_project() {
  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/.token-saver/handoff/pending"
  export CLAUDE_PROJECT_DIR="$PROJ"
}

_write_pending() {
  printf '%s\n' "$2" >"$PROJ/.token-saver/handoff/pending/$1"
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
  assert_file_exists "$PROJ/.token-saver/handoff/consumed/a.md"
  assert_file_exists "$PROJ/.token-saver/handoff/consumed/b.md"
  assert_empty "$(ls -A "$PROJ/.token-saver/handoff/pending")" "pending の残存"
}

test_パスを指定するとそのファイルのみ移す() {
  _setup_project
  _write_pending "a.md" "A"
  _write_pending "b.md" "B"
  _run_consume "$PROJ/.token-saver/handoff/pending/a.md"
  assert_file_exists "$PROJ/.token-saver/handoff/consumed/a.md"
  assert_file_exists "$PROJ/.token-saver/handoff/pending/b.md"
  assert_file_missing "$PROJ/.token-saver/handoff/consumed/b.md"
}

test_pending_が空でも終了コード0で何も壊さない() {
  _setup_project
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_empty "$CONSUME_ERR" "標準エラー"
}

test_pending_ディレクトリが無くても終了コード0() {
  _setup_project
  rm -rf "$PROJ/.token-saver/handoff"
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
}

test_移した内容は失われない() {
  _setup_project
  _write_pending "a.md" "残るべき本文"
  _run_consume
  assert_contains "$(cat "$PROJ/.token-saver/handoff/consumed/a.md")" "残るべき本文" "consumed の内容"
}

test_同名ファイルが_consumed_にあっても既存を上書きしない() {
  _setup_project
  mkdir -p "$PROJ/.token-saver/handoff/consumed"
  printf '先に消費した内容\n' >"$PROJ/.token-saver/handoff/consumed/a.md"
  _write_pending "a.md" "新しい内容"
  _run_consume
  assert_contains "$(cat "$PROJ/.token-saver/handoff/consumed/a.md")" "先に消費した内容" "既存の consumed"
  assert_empty "$(ls -A "$PROJ/.token-saver/handoff/pending")" "pending の残存"
  # 新しい内容も別名でどこかに残っているべきである。
  assert_contains "$(cat "$PROJ"/.token-saver/handoff/consumed/a.md.*)" "新しい内容" "退避先の内容"
}

# 無音で成功扱いにすると、タイプミスが「消費できたつもり」に化ける。
test_存在しないパスを指定したら失敗して理由を示す() {
  _setup_project
  _run_consume "$PROJ/.token-saver/handoff/pending/nope.md"
  assert_ne "0" "$CONSUME_STATUS" "終了コード"
  assert_contains "$CONSUME_ERR" "nope.md" "標準エラー"
}

test_ディレクトリを指定したら失敗する() {
  _setup_project
  mkdir -p "$PROJ/.token-saver/handoff/pending/draft"
  _run_consume "$PROJ/.token-saver/handoff/pending/draft"
  assert_ne "0" "$CONSUME_STATUS" "終了コード"
  assert_contains "$CONSUME_ERR" "draft" "標準エラー"
}

# 不正な引数で落ちても、正しい引数の分は処理を試みたことが分かること。
test_不正な引数があっても正しい引数は消費する() {
  _setup_project
  _write_pending "a.md" "A"
  _run_consume "$PROJ/.token-saver/handoff/pending/a.md" "$PROJ/.token-saver/handoff/pending/nope.md"
  assert_ne "0" "$CONSUME_STATUS" "終了コード"
  assert_file_exists "$PROJ/.token-saver/handoff/consumed/a.md"
}

test_ハイフンで始まるパスでも壊れない() {
  _setup_project
  printf 'ハイフン名の本文\n' >"$PROJ/.token-saver/handoff/pending/-n.md"
  ( cd "$PROJ/.token-saver/handoff/pending" && bash "$CONSUME" -n.md >"$TEST_TMP/.out" 2>"$TEST_TMP/.err" )
  CONSUME_STATUS=$?
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_file_exists "$PROJ/.token-saver/handoff/consumed/-n.md"
}

test_ダブルダッシュ以降は引数として扱う() {
  _setup_project
  printf 'ハイフン名の本文\n' >"$PROJ/.token-saver/handoff/pending/-n.md"
  _run_consume -- "$PROJ/.token-saver/handoff/pending/-n.md"
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_file_exists "$PROJ/.token-saver/handoff/consumed/-n.md"
}

test_引数なしでもハイフン始まりのファイルを移せる() {
  _setup_project
  printf 'A\n' >"$PROJ/.token-saver/handoff/pending/-n.md"
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_empty "$CONSUME_ERR" "標準エラー"
  assert_file_exists "$PROJ/.token-saver/handoff/consumed/-n.md"
}

test_改行を含むファイル名でも移せる() {
  _setup_project
  printf 'A\n' >"$PROJ/.token-saver/handoff/pending/$(printf 'a\nb').md"
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_empty "$(ls -A "$PROJ/.token-saver/handoff/pending")" "pending の残存"
}

# CLAUDE_PROJECT_DIR が無い環境では CWD を導入先とみなす。
test_CLAUDE_PROJECT_DIR_が無いときは_PWD_を使う() {
  _setup_project
  unset CLAUDE_PROJECT_DIR
  mkdir -p "$PWD/.token-saver/handoff/pending"
  printf 'PWD 側\n' >"$PWD/.token-saver/handoff/pending/a.md"
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_file_exists "$PWD/.token-saver/handoff/consumed/a.md"
  # CLAUDE_PROJECT_DIR 側は触られていないこと。
  assert_file_exists "$PROJ/.token-saver/handoff/pending"
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
  chmod 555 "$PROJ/.token-saver/handoff/pending"
  _run_consume
  chmod 755 "$PROJ/.token-saver/handoff/pending"
  assert_ne "0" "$CONSUME_STATUS" "終了コード"
  assert_file_exists "$PROJ/.token-saver/handoff/pending/a.md"
}

test_一括消費は失敗後も後続のファイルを試す() {
  _setup_project
  _write_pending "a.md" "先頭で失敗する本文"
  _write_pending "b.md" "後続で成功する本文"
  local shadow real_mv
  shadow="$TEST_TMP/mv-shadow"
  real_mv="$(command -v mv)"
  mkdir -p "$shadow"
  printf '#!/bin/sh\ncase "$*" in\n  *pending/a.md*) exit 1 ;;\nesac\nexec %s "$@"\n' \
    "$real_mv" >"$shadow/mv"
  chmod +x "$shadow/mv"

  PATH="$shadow:$PATH" bash "$CONSUME" >"$TEST_TMP/.out" 2>"$TEST_TMP/.err"
  CONSUME_STATUS=$?
  CONSUME_ERR="$(cat "$TEST_TMP/.err")"
  assert_ne "0" "$CONSUME_STATUS" "終了コード"
  assert_contains "$CONSUME_ERR" "a.md" "標準エラー"
  assert_file_exists "$PROJ/.token-saver/handoff/pending/a.md"
  assert_file_exists "$PROJ/.token-saver/handoff/consumed/b.md"
}

test_同名宛先への並行移動でも既存と両方を保持する() {
  _setup_project
  local consumed="$PROJ/.token-saver/handoff/consumed"
  local first="$TEST_TMP/source-first/a.md" second="$TEST_TMP/source-second/a.md"
  mkdir -p "$TEST_TMP/source-first" "$TEST_TMP/source-second" "$consumed"
  printf '既存の本文\n' >"$consumed/a.md"
  printf '並行処理1の本文\n' >"$first"
  printf '並行処理2の本文\n' >"$second"

  (
    . "$REPO_ROOT/scripts/lib/common.sh"
    cts_consume_file "$first" "$consumed"
  ) >"$TEST_TMP/.move-1-out" 2>"$TEST_TMP/.move-1-err" &
  local first_pid=$!
  (
    . "$REPO_ROOT/scripts/lib/common.sh"
    cts_consume_file "$second" "$consumed"
  ) >"$TEST_TMP/.move-2-out" 2>"$TEST_TMP/.move-2-err" &
  local second_pid=$!
  wait "$first_pid"
  wait "$second_pid"

  assert_contains "$(cat "$consumed/a.md")" "既存の本文" "既存のconsumed"
  assert_file_exists "$consumed/a.md.dup1"
  assert_file_exists "$consumed/a.md.dup2"
  assert_contains "$(cat "$consumed/a.md.dup1")$(cat "$consumed/a.md.dup2")" \
    "並行処理1の本文" "退避された本文"
  assert_contains "$(cat "$consumed/a.md.dup1")$(cat "$consumed/a.md.dup2")" \
    "並行処理2の本文" "退避された本文"
}

test_サブディレクトリは移動対象にしない() {
  _setup_project
  mkdir -p "$PROJ/.token-saver/handoff/pending/draft"
  printf 'ネストした下書き\n' >"$PROJ/.token-saver/handoff/pending/draft/inner.md"
  _write_pending "a.md" "A"
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_file_exists "$PROJ/.token-saver/handoff/pending/draft"
  assert_file_exists "$PROJ/.token-saver/handoff/pending/draft/inner.md"
  assert_file_missing "$PROJ/.token-saver/handoff/consumed/inner.md"
  assert_file_exists "$PROJ/.token-saver/handoff/consumed/a.md"
}

test_生きたシンボリックリンクを一括消費する() {
  _setup_project
  local target="$TEST_TMP/real-note.md"
  printf 'リンク先の本文\n' >"$target"
  ln -s "$target" "$PROJ/.token-saver/handoff/pending/link.md"
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_file_missing "$PROJ/.token-saver/handoff/pending/link.md"
  if [ ! -L "$PROJ/.token-saver/handoff/consumed/link.md" ]; then
    _fail "symlinkを実体化せずconsumedへ移す"
  fi
  assert_contains "$(cat "$PROJ/.token-saver/handoff/consumed/link.md")" \
    "リンク先の本文" "consumedのsymlink"
  assert_file_exists "$target" "リンク先の実体"
}
