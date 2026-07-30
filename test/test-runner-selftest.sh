#!/usr/bin/env bash
# ランナー自身の検証。アサーションが「失敗すべきときに失敗する」ことを確かめる。
# これが緑でなければ、他のテストの緑は信用できない。
#
# 注意: このファイルには「細工したテストファイルの本文」を文字列として埋め込む。
# run.sh は行頭ちょうどの `名前()` を関数定義として数えるため、埋め込む関数定義は
# 必ず字下げして書くこと（行頭に置くと、このファイル自身の関数と数え違う）。

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

# needle は固定文字列として扱われること。呼び出し側の needle は
# ".claude/.handoff/" のようにドットを含むため、正規表現として解釈されると
# 「1件も無いのに1件ある」と誤判定し、冪等性の検証が静かに緩む。
test_assert_count_はneedleを正規表現として解釈しない() {
  assert_eq "0" "$(_status_of assert_count 1 ".claude/.handoff/" ".claude/.handoff/")" \
    "文字どおり一致した場合の終了コード"
  assert_eq "1" "$(_status_of assert_count 1 "Xclaude/Xhandoff/" ".claude/.handoff/")" \
    "ドットをワイルドカードとして解釈した場合の終了コード"
  # a*b を正規表現として読むと haystack "b" に一致してしまう。
  assert_eq "0" "$(_status_of assert_count 0 "b" "a*b")" "アスタリスクを含む needle の終了コード"
  assert_eq "0" "$(_status_of assert_count 1 "x [y] z" "[y]")" "角括弧を含む needle の終了コード"
}

# 先頭がハイフンの needle が grep のオプションとして食われないこと。
test_assert_count_は先頭ハイフンのneedleを扱える() {
  assert_eq "0" "$(_status_of assert_count 1 "x -x y" "-x")" "先頭ハイフンの終了コード"
}

# マッチゼロで grep が非ゼロ終了しても、actual は 0 として扱われること。
test_assert_count_はマッチゼロと空haystackを0と数える() {
  assert_eq "0" "$(_status_of assert_count 0 "abc" "z")" "マッチゼロの終了コード"
  assert_eq "1" "$(_status_of assert_count 1 "abc" "z")" "マッチゼロを1と期待した場合の終了コード"
  assert_eq "0" "$(_status_of assert_count 0 "" "a")" "空 haystack の終了コード"
}

# 空 needle の出現回数は定義できない。呼び出し側の変数が空だった事故を
# 「0 件」や「1 件」に化けさせず、その場で落とす。
test_assert_count_は空のneedleを失敗させる() {
  assert_eq "1" "$(_status_of assert_count 0 "abc" "")" "空 needle の終了コード"
  assert_eq "1" "$(_status_of assert_count 1 "" "")" "空 needle と空 haystack の終了コード"
}

# ---- ランナー自身が壊れたテストを緑にしないこと --------------------------
# 別ディレクトリへランナーを複製し、そこへ細工したテストファイルを置いて回す。
# 実スイートを巻き込まないよう、使い捨てディレクトリには最小のファイルだけ置く。

_make_runner_dir() {
  RUNNER_DIR="$TEST_TMP/runner"
  rm -rf "$RUNNER_DIR"
  mkdir -p "$RUNNER_DIR/lib"
  cp "$REPO_ROOT/test/run.sh" "$RUNNER_DIR/run.sh"
  cp "$REPO_ROOT/test/lib/assert.sh" "$RUNNER_DIR/lib/assert.sh"
}

# 本文は字下げして埋め込む規約（ファイル冒頭の注意を参照）。書き出すときに
# 字下げを剥がし、生成されるテストファイル側では関数定義を行頭へ戻す。
_put_test_file() {
  printf '%s\n' "$2" | sed 's/^  //' >"$RUNNER_DIR/test-$1.sh"
}

# 親側の CTS_MIN_TESTS が漏れると下限の検査結果が変わるため、必ず外して呼ぶ。
_run_runner() {
  RUNNER_OUT="$(env -u CTS_MIN_TESTS bash "$RUNNER_DIR/run.sh" "$@" 2>&1)"
  RUNNER_STATUS=$?
}

_run_runner_with() {
  _make_runner_dir
  _put_test_file subject "$1"
  _run_runner
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
  _run_runner_with '  test_ok() { assert_eq a a; }'
  assert_eq "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "ok   test_ok" "ランナー出力"
}

# 同名の関数は後勝ちで上書きされる。先に書いた検証が消えても件数が1つ減るだけで、
# 誰も気づかない。本文の定義数と実際の関数数を突き合わせて落とすこと。
test_同名のテスト関数は失敗として計上される() {
  _run_runner_with '  test_dup() { assert_eq a b; }
  test_dup() { assert_eq a a; }'
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "FAIL" "ランナー出力"
  assert_contains "$RUNNER_OUT" "重複" "ランナー出力"
}

# 日本語の関数名でも定義数を数え違えないこと（数え違えれば健全なファイルが赤くなる）。
test_日本語名のテスト関数でも重複判定は誤検知しない() {
  _run_runner_with '  test_日本語の名前でも数えられる() { assert_eq a a; }
  test_ふたつめの日本語名() { assert_eq a a; }'
  assert_eq "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "成功 2 件" "ランナー出力"
}

# tets_ のような綴り間違いは一度も実行されない。件数が減るだけなので気づけない。
test_testの綴り間違いは失敗として計上される() {
  _run_runner_with '  tets_typo() { assert_eq a b; }
  test_ok() { assert_eq a a; }'
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "綴り" "ランナー出力"
}

# set_ のような正当な補助関数まで綴り間違い扱いにしないこと。
test_正当な補助関数は綴り間違い扱いされない() {
  _run_runner_with '  set_up() { :; }
  make_fixture() { :; }
  test_ok() { assert_eq a a; }'
  assert_eq "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "成功 1 件" "ランナー出力"
}

# 構文検査は構文しか見ない。シェルを終了させないランタイムエラーは
# 列挙のサブシェルで stderr へ出るだけなので、捨てずに拾って落とすこと。
test_source時のエラー出力は失敗として計上される() {
  _run_runner_with 'this_command_does_not_exist_xyz
  test_ok() { assert_eq a a; }'
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "FAIL" "ランナー出力"
  assert_contains "$RUNNER_OUT" "this_command_does_not_exist_xyz" "ランナー出力（stderr の中身）"
}

# ---- 実行件数の下限 ------------------------------------------------------

# 綴りを間違えたパターンは「成功 0 件」ではなくエラーであること。
test_パターンに一致するファイルが無ければエラーになる() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { assert_eq a a; }'
  _run_runner typo-no-such-file
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "typo-no-such-file" "ランナー出力（指定したパターン）"
}

# テストファイルの消失・改名も「成功 0 件」ではなくエラーであること。
test_テストファイルが1つも無ければエラーになる() {
  _make_runner_dir
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "エラー" "ランナー出力"
}

test_実行件数が下限を下回ると失敗になる() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { assert_eq a a; }'
  printf '5\n' >"$RUNNER_DIR/expected-min-count"
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "下限" "ランナー出力"
}

test_実行件数が下限以上なら成功する() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { assert_eq a a; }'
  printf '# コメント行は読み飛ばす\n1\n' >"$RUNNER_DIR/expected-min-count"
  _run_runner
  assert_eq "0" "$RUNNER_STATUS" "ランナーの終了コード"
}

test_実行件数の下限は環境変数で上書きできる() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { assert_eq a a; }'
  printf '1\n' >"$RUNNER_DIR/expected-min-count"
  RUNNER_OUT="$(CTS_MIN_TESTS=5 bash "$RUNNER_DIR/run.sh" 2>&1)"
  RUNNER_STATUS=$?
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "下限" "ランナー出力"
}

# 一部だけ回すときに下限を当てても意味がない（常に下回る）。
test_実行件数の下限はパターン指定時には検査されない() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { assert_eq a a; }'
  printf '5\n' >"$RUNNER_DIR/expected-min-count"
  _run_runner subject
  assert_eq "0" "$RUNNER_STATUS" "ランナーの終了コード"
}

test_下限のファイルが無ければ件数は検査されない() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { assert_eq a a; }'
  _run_runner
  assert_eq "0" "$RUNNER_STATUS" "ランナーの終了コード"
}

# ---- テストの隔離 --------------------------------------------------------
# 隔離は1つのテスト関数からは検証できない（毎回まっさらな tmp で走るため、
# 何を確かめても常に真になる）。2つの関数を組にし、先に走る側が痕跡を残し、
# 後に走る側がそれを見ないことを確かめる。実行順は run.sh のバイト順ソートに
# 依存するため、名前の _1_ / _2_ で順序を固定している。

_isolation_probe_path() {
  printf '%s/cts-isolation-probe' "$(dirname "$TEST_TMP")"
}

test_隔離_1_痕跡を残す() {
  assert_ne "" "${TEST_TMP:-}" "TEST_TMP"
  assert_eq "$TEST_TMP" "$PWD" "カレントディレクトリ"
  printf '%s\n' "$TEST_TMP" >"$(_isolation_probe_path)"
  : >"$TEST_TMP/leaked-from-other-test"
}

test_隔離_2_前のテストの痕跡が見えない() {
  local probe prev
  probe="$(_isolation_probe_path)"
  assert_file_exists "$probe"
  prev="$(cat "$probe")"
  rm -f "$probe"
  assert_ne "$prev" "$TEST_TMP" "一時ディレクトリ"
  assert_file_missing "$TEST_TMP/leaked-from-other-test"
  # 前のテストの一時ディレクトリは実行後に片付けられていること。
  assert_file_missing "$prev"
}
