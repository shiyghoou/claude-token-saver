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
  # runner-allow: 終了コード自体を検証するため、意図してサブシェルで呼んでいる。
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
  # 台帳が無いこと自体がエラーになるため、既定で緩い台帳を置く。
  # 台帳そのものを検証するテストは、これを上書きするか消して使う。
  printf '1\n' >"$RUNNER_DIR/expected-min-count"

  # 複製した run.sh は TEST_DIR/.. を REPO_ROOT に解決する。TEST_DIR は
  # 複製先の run.sh 自身のディレクトリ（$RUNNER_DIR）なので、REPO_ROOT は
  # $TEST_TMP に解決される。パスの単一情報源ゲートはその REPO_ROOT 側の
  # install.sh / uninstall.sh / scripts / lib を対象に見るため、複製先には
  # 実装コードが1つも無い。ゲートは「対象が1つも無ければエラー」で打ち切る
  # 守りを持つため、これを外さずに既存のセルフテストを通すには、対象になり
  # うる最小の実装コードをここへ用意する必要がある。
  #
  # scripts/lib/paths.sh だけは実物を複製する。除外が「本物の paths.sh」を
  # 正しく除外できることを検証したいテストがあるため、内容が空のダミーでは
  # 検証にならない（本物には新旧両方のパスのリテラルが実際に含まれる）。
  mkdir -p "$TEST_TMP/scripts/lib" "$TEST_TMP/lib"
  : >"$TEST_TMP/install.sh"
  : >"$TEST_TMP/uninstall.sh"
  printf '#!/usr/bin/env bash\n# テスト用の空実装。\n' >"$TEST_TMP/scripts/handoff-check.sh"
  cp "$REPO_ROOT/scripts/lib/paths.sh" "$TEST_TMP/scripts/lib/paths.sh" \
    || _fail "paths.sh の複製に失敗した（移動または改名されていないか確認すること）"
  : >"$TEST_TMP/lib/.keep"
}

# 本文は字下げして埋め込む規約（ファイル冒頭の注意を参照）。書き出すときに
# 字下げを剥がし、生成されるテストファイル側では関数定義を行頭へ戻す。
#
# @A@ は書き出し時に assert_ へ展開する。run.sh は「失敗が飲まれる位置での
# アサーション呼び出し」を静的に探すため、その細工を素の文字列で埋め込むと
# このファイル自身が引っ掛かる（検証したい細工と、検証する側のファイルが
# 文字列で衝突する）。トークンを介して、生成されるファイルにだけ現れさせる。
_put_test_file() {
  printf '%s\n' "$2" | sed 's/^  //; s/@A@/assert_/g' >"$RUNNER_DIR/test-$1.sh"
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

# 台帳ひとつの消失で、件数が減ったことを知る唯一の手段が無言で失われてはならない。
test_下限のファイルが無ければエラーになる() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { assert_eq a a; }'
  rm -f "$RUNNER_DIR/expected-min-count"
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "台帳" "ランナー出力"
}

# 無検査にしたいときは明示させる。既定を無検査にしてはいけない。
test_件数の検査は明示的にのみ無効化できる() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { assert_eq a a; }'
  rm -f "$RUNNER_DIR/expected-min-count"
  RUNNER_OUT="$(CTS_MIN_TESTS=0 bash "$RUNNER_DIR/run.sh" 2>&1)"
  RUNNER_STATUS=$?
  assert_eq "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "検査しない" "ランナー出力"
}

# 総件数だけでは、実テストを空のテストで置き換えて件数を満たす詐称を見抜けない。
test_ファイル別の下限を下回ると失敗になる() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { assert_eq a a; }'
  printf 'test-subject.sh 3\n' >"$RUNNER_DIR/expected-min-count"
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "test-subject.sh" "ランナー出力"
}

# 台帳に載っているファイルが消えたことを、総件数の充足で隠せないこと。
test_台帳にあるテストファイルが消えていればエラーになる() {
  _make_runner_dir
  _put_test_file subject '  test_a() { assert_eq a a; }
  test_b() { assert_eq a a; }'
  printf '2\ntest-subject.sh 1\ntest-gone.sh 1\n' >"$RUNNER_DIR/expected-min-count"
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "test-gone.sh" "ランナー出力"
}

# 一部だけ回すときも、選んだファイルのファイル別下限は検査できる。
test_ファイル別の下限はパターン指定時にも検査される() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { assert_eq a a; }'
  printf '99\ntest-subject.sh 3\n' >"$RUNNER_DIR/expected-min-count"
  _run_runner subject
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "test-subject.sh" "ランナー出力（ファイル別の下限）"
  assert_not_contains "$RUNNER_OUT" "実行 1 件 / 下限 99 件" "ランナー出力（総件数は検査しない）"
}

# ---- 検証を含まないテスト ------------------------------------------------

# 空の本文でも「ok」と出る。件数の下限をフィラーで満たす詐称を防ぐ。
test_検証を含まないテスト関数は失敗として計上される() {
  _run_runner_with '  test_nothing() { :; }'
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "検証を含まない" "ランナー出力"
  assert_contains "$RUNNER_OUT" "test_nothing" "ランナー出力（関数名）"
}

# _fail で直接落とすテストは正当である（アサーション経由でなくてもよい）。
test_failで落とすテストは検証ありと見なす() {
  _run_runner_with '  test_via_fail() { [ 1 = 1 ] || _fail "ありえない"; }'
  assert_eq "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "ok   test_via_fail" "ランナー出力"
}

# 失敗が飲まれる位置での呼び出しは、緑になってしまう前に静的に落とす。
test_コマンド置換内のアサーションは失敗として計上される() {
  _run_runner_with '  test_smothered() { x="$(@A@eq a b)"; @A@eq a a; }'
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "飲まれる" "ランナー出力"
}

test_サブシェル内のアサーションは失敗として計上される() {
  _run_runner_with '  test_smothered() { ( . "$TEST_DIR/lib/assert.sh"; @A@eq a b ); @A@eq a a; }'
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "飲まれる" "ランナー出力"
}

# ---- アサーション層そのものが壊れた場合 ----------------------------------
# ここが独立したオラクルである。スイート内のアサーションで検べると、_fail が
# 壊れた時点で検べる側も壊れるため何も検出できない。ランナーを複製し、その
# assert.sh に改変を加えて、ランナーが自力で気づくことを確かめる。

# 原本の末尾へ改変を追記する。bash は後に定義した関数を採るため、これで
# 任意の関数を差し替えられる。原本から行を削る方式にすると、原本の行構成が
# 変わったときに黙って「改変していない」状態になる。
_break_assert_layer() {
  cp "$REPO_ROOT/test/lib/assert.sh" "$RUNNER_DIR/lib/assert.sh"
  printf '%s\n' "$1" | sed 's/^  //' >>"$RUNNER_DIR/lib/assert.sh"
}

# _fail が exit ではなく return になると、失敗したあとの文が実行され続け、
# 最後の文が成功すればテストは緑になる。終了コードだけを見ても捕まらない。
test_failが呼び出し元を終了させなければ実行を打ち切る() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { assert_eq a a; }'
  _break_assert_layer '_fail() { printf "    %s\n" "$*" >&2; return 1; }'
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "アサーション層" "ランナー出力"
}

# _fail が常に成功すると、全アサーションが一斉に無効化される。
test_failが常に成功するなら実行を打ち切る() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { assert_eq a a; }'
  _break_assert_layer '_fail() { printf "    %s\n" "$*" >&2; return 0; }'
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "アサーション層" "ランナー出力"
}

# 個別のアサーションが「常に成功」に化けた場合も打ち切ること。
test_個別のアサーションが常に成功するなら実行を打ち切る() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { assert_eq a a; }'
  _break_assert_layer '  _fail() { printf "    %s\n" "$*" >&2; exit 1; }
  assert_contains() { return 0; }'
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "assert_contains" "ランナー出力"
}

# 「常に失敗」への改変も、理由付きで打ち切れること。
test_アサーションが常に失敗するなら実行を打ち切る() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { assert_eq a a; }'
  _break_assert_layer '  _fail() { printf "    %s\n" "$*" >&2; exit 1; }
  assert_eq() { _fail "always"; }'
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "アサーション層" "ランナー出力"
}

# 健全な assert.sh では打ち切らないこと（このゲート自体が誤検知しないこと）。
test_健全なアサーション層では打ち切らない() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { assert_eq a a; }'
  _run_runner
  assert_eq "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_not_contains "$RUNNER_OUT" "アサーション層" "ランナー出力"
}

# ---- テストの隔離 --------------------------------------------------------
# 隔離は1つのテスト関数からは検証できない（毎回まっさらな tmp で走るため、
# 何を確かめても常に真になる）。2つの関数を組にし、先に走る側が痕跡を残し、
# 後に走る側がそれを見ないことを確かめる。実行順は run.sh のバイト順ソートに
# 依存するため、名前の _1_ / _2_ で順序を固定している。

# 痕跡は run.sh がこの実行のために作った専用ディレクトリへ置く。共有の /tmp に
# 固定名で置くと、(1) 並行実行が互いのファイルを奪い合って偽の赤になり、
# (2) 事前に張られたシンボリックリンクを追従して無関係なファイルを上書きする。
_isolation_probe_path() {
  printf '%s/isolation-probe' "$CTS_RUN_DIR"
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

# ---- パスの単一情報源ゲート -----------------------------------------------
# run.sh は実装コード（install.sh / uninstall.sh / scripts/** / lib/**）に
# パスのリテラルが残っていれば、テストを1本も走らせずに打ち切る。
# _make_runner_dir が複製先の REPO_ROOT 側（$TEST_TMP）へ最小の実装コードを
# 用意しているので、ここへリテラルを足して打ち切りを検証する。

test_実装コードに新パスのリテラルがあれば打ち切る() {
  _make_runner_dir
  printf 'echo ".token-saver/handoff"\n' >>"$TEST_TMP/scripts/handoff-check.sh"
  _put_test_file subject '  test_ok() { @A@eq a a; }'
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "終了コード"
  assert_contains "$RUNNER_OUT" "scripts/handoff-check.sh" "違反したファイル名"
}

test_実装コードに旧パスのリテラルがあれば打ち切る() {
  _make_runner_dir
  printf 'echo ".claude/.handoff"\n' >>"$TEST_TMP/install.sh"
  _put_test_file subject '  test_ok() { @A@eq a a; }'
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "終了コード"
  assert_contains "$RUNNER_OUT" "install.sh" "違反したファイル名"
}

test_paths_sh_自身のリテラルは許す() {
  # scripts/lib/paths.sh の本物には新旧両方のパスのリテラルが実際に含まれる
  # （cts_base_rel 等の定義そのものと、cts_legacy_* の旧パス）。それでも
  # 打ち切られないことが、除外が効いていることの証明になる。
  _run_runner_with '  test_ok() { @A@eq a a; }'
  assert_eq "0" "$RUNNER_STATUS" "終了コード"
  assert_not_contains "$RUNNER_OUT" "実装コードにパスのリテラルが残っている" "ゲートに掛からない"
}

test_テスト側のリテラルは許す() {
  # test/ 配下（複製先では $RUNNER_DIR）はゲートの走査対象そのものに
  # 含まれない。テスト本文にパスのリテラルを書いても打ち切られないこと。
  _run_runner_with '  test_ok() {
    local x=".token-saver"
    @A@eq a a
  }'
  assert_eq "0" "$RUNNER_STATUS" "終了コード"
  assert_not_contains "$RUNNER_OUT" "実装コードにパスのリテラルが残っている" "test/ は対象外"
}

test_ゲートはテストより前に走る() {
  _make_runner_dir
  printf 'echo ".token-saver"\n' >>"$TEST_TMP/install.sh"
  _put_test_file subject '  test_ok() { @A@eq a a; }'
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "終了コード"
  # 1本も実行されていないこと。「他は緑だから大丈夫」と読まれる余地を残さない。
  assert_not_contains "$RUNNER_OUT" "  ok   " "テストが走っていない"
}

# 新パスは値としての直書きだけを禁じる。行頭コメント（行の最初の非空白文字が
# # である行）は、なぜそう書いたかを述べる散文であり、値の重複を作らないので
# 許される。
test_実装コードの行頭コメントにある新パスのリテラルは許す() {
  _make_runner_dir
  printf '# .token-saver はここに置く\n' >>"$TEST_TMP/scripts/handoff-check.sh"
  _put_test_file subject '  test_ok() { @A@eq a a; }'
  _run_runner
  assert_eq "0" "$RUNNER_STATUS" "終了コード"
  assert_not_contains "$RUNNER_OUT" "実装コードにパスのリテラルが残っている" "行頭コメントは対象外"
}

# 旧パスにはコメントの免除が無い。旧パスを語る記述そのものが、次に読む人を
# 移行前の世界へ誘導するためである。
test_実装コードの行頭コメントにある旧パスのリテラルは打ち切る() {
  _make_runner_dir
  printf '# .claude/.handoff は旧パスである\n' >>"$TEST_TMP/install.sh"
  _put_test_file subject '  test_ok() { @A@eq a a; }'
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "終了コード"
  assert_contains "$RUNNER_OUT" "install.sh" "違反したファイル名"
}

# paths.sh の除外は「行に paths.sh という文字列が含まれるか」ではなく
# 「ファイルパスそのものが scripts/lib/paths.sh に一致するか」で行う。前者
# （grep -v によるパターン一致）だと、違反行の行末コメントに "paths.sh:" と
# 書くだけで、無関係な新パスの値ごと免除されてしまう。ゲート自身の案内文
# （「定義は scripts/lib/paths.sh の1箇所だけに置くこと」）を読んだ書き手が
# 自然に書きそうな参照コメントである。
test_行末コメントにpaths_shへの参照があっても新パスの値は打ち切られる() {
  _make_runner_dir
  printf 'STATE=".token-saver"  # 定義は scripts/lib/paths.sh: cts_base_rel を見よ\n' \
    >>"$TEST_TMP/install.sh"
  _put_test_file subject '  test_ok() { @A@eq a a; }'
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "終了コード"
  assert_contains "$RUNNER_OUT" "install.sh" "違反したファイル名"
}

# 除外はファイルパスの完全一致でなければならない。ファイル名だけで判定すると、
# scripts/ や lib/ の下の別の場所に paths.sh という名前のファイルを置くだけで
# 免除されてしまう。それはまさにこのゲートが防ぐべき「2つ目のパス定義ファイル」
# そのものであり、免除されては本末転倒である。
test_別の場所のpaths_shという名前のファイルは免除されない() {
  _make_runner_dir
  printf 'CTS_BASE=".token-saver"\n' >"$TEST_TMP/lib/paths.sh"
  _put_test_file subject '  test_ok() { @A@eq a a; }'
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "終了コード"
  assert_contains "$RUNNER_OUT" "lib/paths.sh" "違反したファイル名"
}

# 「対象が1つも無ければエラー」の守りは、_make_runner_dir が種まきする
# 最小の実装コードのおかげで通常は発火しない。この守り自体が生きていることを
# 別立てで確かめないと、種まきが守りを恒久的に迂回しているだけになる。
test_実装コードが1つも無ければ対象ゼロのエラーで打ち切る() {
  _make_runner_dir
  rm -rf "$TEST_TMP/install.sh" "$TEST_TMP/uninstall.sh" "$TEST_TMP/scripts" "$TEST_TMP/lib"
  _put_test_file subject '  test_ok() { @A@eq a a; }'
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "終了コード"
  assert_contains "$RUNNER_OUT" "パス検査の対象が1つも無い" "対象ゼロのエラーメッセージ"
}

# ---- リポジトリ本体の汚染の検査 --------------------------------------------
# 実測: test-uninstall.sh の一部のテストが、スキルがディレクトリのコピーとして
# 設置された状態で `rm -f "$dest"` を使っていた。`rm -f` はディレクトリを
# 消せず黙って失敗し、直後の `ln -s` が既存のディレクトリの中にリンクを
# 作ってしまう。この経路は複製先の $TARGET（$TEST_TMP の下）に閉じているが、
# テストが $REPO_ROOT を握っている以上、同種の書き込みが本体へ向かない保証は
# 無い。ここでは「本体（複製先の REPO_ROOT）が実際に汚れたら run.sh 自身が
# 赤になる」ことを検べる。

# 複製先の REPO_ROOT（$TEST_TMP）は git 管理下に無い。`git status --porcelain`
# だけに頼ると常に空文字列を返し、「何も検出しない」まま緑になる（守りが黙って
# no-op になる、このリポジトリが最も嫌う形）。git が使えない場合の指紋（ファイル
# 一覧・シンボリックリンク先・内容のチェックサム）が実際に効くことを、
# あえて git 管理下に置かない複製先で確かめる。
test_複製先が_git_管理下でなくても本体の汚染を検出する() {
  _make_runner_dir
  _put_test_file subject '  test_本体を汚す() {
    : >"$REPO_ROOT/leaked-from-test"
    assert_eq a a "何もしない"
  }'
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "リポジトリ本体を変更した" "ランナー出力"
  assert_contains "$RUNNER_OUT" "leaked-from-test" "汚したファイルの名前"
  # git 管理下でない枝が実際に走ったことを形で確かめる。フォールバックの
  # 指紋はタブ区切りの「path<TAB>file<TAB>チェックサム」であり、porcelain の
  # 「?? path」とは形が違う。ここでこの形が出ていなければ、実は git 管理下に
  # 巻き込まれていて（$TMPDIR が git リポジトリの中にある等）、非 git の枝を
  # 検証したつもりで何も検証していないことになる。
  assert_contains "$RUNNER_OUT" "$(printf 'leaked-from-test\tfile\t')" \
    "非 git 経路（タブ区切り）の指紋形式"
}

# 本物のリポジトリでは git が使える。追跡ファイルの書き換えと未追跡ファイルの
# 増加の両方を見ることを、複製先を明示的に git 管理下へ置いて確かめる
# （controller の候補: 「複製先のテストでは、種まきした $TEST_TMP を git init
# して git 管理下にする」）。
#
# 汚染は「既存の未追跡ディレクトリの中」に作る。git status の既定
# （-unormal 相当）は未追跡ディレクトリを `?? dir/` の1行へ畳み、中の
# 増減を区別しない。リポジトリ直下に汚染を作るだけでは -unormal でも
# -uall でも同じく検出できてしまい、-uall を使っていることの証拠にならない。
test_git管理下では追跡ファイルの書き換えと未追跡ディレクトリの中の増加も検出する() {
  _make_runner_dir
  ( cd "$TEST_TMP" &&
    git init -q . &&
    git add install.sh &&
    git -c user.email=t@example.com -c user.name=t commit -qm '種まき'
  ) >/dev/null 2>&1 || _fail "複製先の git init に失敗した"
  mkdir -p "$TEST_TMP/untracked-dir"
  : >"$TEST_TMP/untracked-dir/existing.txt"
  _put_test_file subject '  test_追跡ファイルを書き換え未追跡ディレクトリの中も増やす() {
    printf "leaked\n" >>"$REPO_ROOT/install.sh"
    : >"$REPO_ROOT/untracked-dir/leaked-inside.txt"
    ln -s /nonexistent "$REPO_ROOT/untracked-dir/leaked-link"
    assert_eq a a "何もしない"
  }'
  _run_runner
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_contains "$RUNNER_OUT" "リポジトリ本体を変更した" "ランナー出力"
  assert_contains "$RUNNER_OUT" "install.sh" "追跡ファイルの書き換えを検出"
  assert_contains "$RUNNER_OUT" "untracked-dir/leaked-inside.txt" \
    "既存の未追跡ディレクトリの中の増加を検出（-uall が無ければ dir/ の1行に畳まれて見えない）"
  # git の枝が実際に走ったことを porcelain の形で確かめる（フォールバックとは
  # 形が違うタブ無しの "?? path" 形式）。
  assert_contains "$RUNNER_OUT" "?? untracked-dir/leaked-inside.txt" \
    "git 経路（porcelain 形式）で検出したことの確認"
}

# git の指紋には `.gitignore` の死角がある。無視されたパスは
# `git status --porcelain -uall` に一切現れないため、git の指紋だけでは
# 「本体が汚れたのに何も検出しない」まま緑になりうる。これはこのリポジトリが
# 最も嫌う形（守りが黙って no-op になる）そのものであり、この死角を塞ぐために
# 存在確認（_repo_pollution_probe）を並走させた。その存在確認自身が働いている
# ことを、`.gitignore` で実際に隠したうえで確かめる。
test_gitignoreに隠れた汚染も存在確認で検出する() {
  _make_runner_dir
  ( cd "$TEST_TMP" &&
    git init -q . &&
    printf '.token-saver/\n' >.gitignore &&
    git add install.sh .gitignore &&
    git -c user.email=t@example.com -c user.name=t commit -qm '種まき'
  ) >/dev/null 2>&1 || _fail "複製先の git init に失敗した"
  _put_test_file subject '  test_gitignoreで隠れた場所を汚す() {
    mkdir -p "$REPO_ROOT/.token-saver"
    : >"$REPO_ROOT/.token-saver/leaked.json"
    @A@eq a a "何もしない"
  }'
  _run_runner
  # git の指紋だけを見ていれば、.gitignore が隠すため何も検出できず緑になる
  # （このアサーションが無くても以降の3本で赤は確認できるが、「なぜこの
  # 存在確認が要るのか」を裏づけるために明示しておく）。
  assert_not_contains "$RUNNER_OUT" "?? .token-saver" \
    "git の指紋は .gitignore に隠れて何も拾わない（前提の確認）"
  assert_ne "0" "$RUNNER_STATUS" "ランナーの終了コード（存在確認が拾って赤になる）"
  assert_contains "$RUNNER_OUT" ".gitignore 越しの見逃し" "存在確認の側が打ち切ったことを示す文言"
  assert_contains "$RUNNER_OUT" ".token-saver" "汚染したパス"
}

# このゲート自体が誤検知しないこと。本体を汚さない健全なテストでは
# 打ち切らない。
test_本体が汚れていなければ打ち切らない() {
  _make_runner_dir
  _put_test_file subject '  test_ok() { @A@eq a a; }'
  _run_runner
  assert_eq "0" "$RUNNER_STATUS" "ランナーの終了コード"
  assert_not_contains "$RUNNER_OUT" "リポジトリ本体を変更した" "ランナー出力"
}
