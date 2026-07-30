#!/usr/bin/env bash
# ランナー自身の検証。アサーションが「失敗すべきときに失敗する」ことを確かめる。
# これが緑でなければ、他のテストの緑は信用できない。

# サブシェルでアサーションを実行し、終了コードだけを返す。
_status_of() {
  ( "$@" ) >/dev/null 2>&1
  printf '%s' "$?"
}

test_assert_eq_は一致で成功し不一致で失敗する() {
  assert_eq "0" "$(_status_of assert_eq a a)" "一致時の終了コード"
  assert_eq "1" "$(_status_of assert_eq a b)" "不一致時の終了コード"
}

test_assert_empty_は非空文字列を失敗させる() {
  assert_eq "0" "$(_status_of assert_empty "")" "空文字列の終了コード"
  assert_eq "1" "$(_status_of assert_empty "x")" "非空文字列の終了コード"
}

test_assert_contains_は不在を失敗させる() {
  assert_eq "0" "$(_status_of assert_contains "abc" "b")" "含む場合の終了コード"
  assert_eq "1" "$(_status_of assert_contains "abc" "z")" "含まない場合の終了コード"
}

test_assert_file_exists_は不在を失敗させる() {
  : >"$TEST_TMP/present"
  assert_eq "0" "$(_status_of assert_file_exists "$TEST_TMP/present")" "存在時の終了コード"
  assert_eq "1" "$(_status_of assert_file_exists "$TEST_TMP/absent")" "不在時の終了コード"
}

test_assert_ne_は一致を失敗させる() {
  assert_eq "0" "$(_status_of assert_ne a b)" "不一致時の終了コード"
  assert_eq "1" "$(_status_of assert_ne a a)" "一致時の終了コード"
}

test_assert_not_contains_は存在を失敗させる() {
  assert_eq "0" "$(_status_of assert_not_contains "abc" "z")" "含まない場合の終了コード"
  assert_eq "1" "$(_status_of assert_not_contains "abc" "b")" "含む場合の終了コード"
}

test_assert_file_missing_は存在を失敗させる() {
  : >"$TEST_TMP/there"
  assert_eq "0" "$(_status_of assert_file_missing "$TEST_TMP/nothing")" "不在時の終了コード"
  assert_eq "1" "$(_status_of assert_file_missing "$TEST_TMP/there")" "存在時の終了コード"
}

# assert_file_missing は [ -e ] && _fail の形であり、set -e 下では
# 最後の判定が偽のときにそこで抜けてしまいうる。明示的に確かめる。
test_assert_file_missing_は_set_e_下でも成功を返す() {
  local status
  ( set -e; . "$TEST_DIR/lib/assert.sh"; assert_file_missing "$TEST_TMP/nothing"; exit 0 ) \
    >/dev/null 2>&1
  status=$?
  assert_eq "0" "$status" "set -e 下の終了コード"
}

test_assert_count_は出現回数の差を失敗させる() {
  local text
  text="$(printf 'a\na\nb\n')"
  assert_eq "0" "$(_status_of assert_count 2 "$text" "a")" "回数一致時の終了コード"
  assert_eq "1" "$(_status_of assert_count 1 "$text" "a")" "回数不一致時の終了コード"
}

# 「一致した行数」ではなく「出現回数」であること。同じ行に2回出れば 2 である。
test_assert_count_は同一行の複数出現を数える() {
  assert_eq "0" "$(_status_of assert_count 2 "aa" "a")" "同一行2回の終了コード"
  assert_eq "1" "$(_status_of assert_count 1 "aa" "a")" "誤った回数の終了コード"
}

# ---- ランナー自身が壊れたテストを緑にしないこと --------------------------
# 別ディレクトリへランナーを複製し、そこへ細工したテストファイルを置いて回す。

_run_runner_with() {
  local body="$1"
  local dir="$TEST_TMP/runner"
  rm -rf "$dir"
  mkdir -p "$dir/lib"
  cp "$REPO_ROOT/test/run.sh" "$dir/run.sh"
  cp "$REPO_ROOT/test/lib/assert.sh" "$dir/lib/assert.sh"
  printf '%s\n' "$body" >"$dir/test-subject.sh"
  RUNNER_OUT="$(bash "$dir/run.sh" 2>&1)"
  RUNNER_STATUS=$?
}

test_構文エラーのテストファイルは失敗として計上される() {
  # 関数定義より前に構文エラーがあると、列挙が黙って 0 件になる。
  _run_runner_with 'broken_function( {
test_something() { :; }'
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "FAIL" "ランナー出力"
}

test_テスト関数が1つも無いファイルは失敗として計上される() {
  _run_runner_with '# 関数を定義し忘れたテストファイル
helper() { :; }'
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "FAIL" "ランナー出力"
}

test_健全なテストファイルは成功として計上される() {
  _run_runner_with 'test_ok() { assert_eq a a; }'
  assert_eq "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "ok   test_ok" "ランナー出力"
}

test_テストは専用の一時ディレクトリで実行される() {
  assert_ne "" "${TEST_TMP:-}" "TEST_TMP"
  assert_eq "$TEST_TMP" "$PWD" "カレントディレクトリ"
  assert_file_missing "$TEST_TMP/leaked-from-other-test"
  : >"$TEST_TMP/leaked-from-other-test"
}
