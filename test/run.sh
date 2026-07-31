#!/usr/bin/env bash
# 依存ゼロの bash テストランナー。
#
#   test/run.sh              全テストを実行
#   test/run.sh handoff      ファイル名に handoff を含むテストのみ実行
#
# テストファイルは test/test-*.sh。中で test_ で始まる関数を定義する。
# 各テスト関数はサブシェルで、専用の一時ディレクトリ（$TEST_TMP）を CWD として実行される。
#
# 実行件数の下限は test/expected-min-count に置く（総件数とファイル別件数）。
# 全件実行時は総件数とファイル別件数の両方を、パターン指定時は選んだファイルの
# ファイル別件数のみを検査する。台帳が無ければエラーである（黙って無検査にしない）。
# 環境変数 CTS_MIN_TESTS で総件数を上書きでき、0 を指定したときだけ無検査になる。

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
export TEST_DIR REPO_ROOT

# この実行に固有の作業ディレクトリ。テスト間で受け渡しが必要な痕跡（隔離の検証など）は
# 共有の /tmp に固定名で置かず、ここへ置く。固定名だと並行実行が互いのファイルを
# 奪い合って偽の赤になり、事前に張られたシンボリックリンクを追従して
# 無関係なファイルを上書きしうる。
CTS_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cts-run.XXXXXX")"
export CTS_RUN_DIR
trap 'rm -rf "$CTS_RUN_DIR"' EXIT

# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"

# ---- アサーション層の生存確認 --------------------------------------------
# ここから _check_assert_layer までは、意図して assert_* を一切使わない。
# アサーションが壊れているかどうかをアサーションで検べると、検べる側も同時に
# 壊れるため何も検出できない（実測: _fail を「常に成功」に改変すると、
# アサーションを 191 件すべて無効化しても全件緑になった）。
# 独立したオラクルとして、素の条件式で終了コードとその副作用を確かめる。

_assert_layer_error() {
  printf 'エラー: アサーション層が壊れている: %s\n' "$1" >&2
  printf '       この状態では全テストの緑が信用できないため、実行を打ち切る。\n' >&2
  exit 1
}

# 使い捨てシェルでアサーションを1つ実行し、終了コードだけを返す。
_probe_assert_rc() {
  ( . "$TEST_DIR/lib/assert.sh"; "$@" ) >/dev/null 2>&1
  printf '%s' "$?"
}

# $1: 期待（pass / fail）, $2: 説明, 残り: 実行するアサーション呼び出し
_expect_assert() {
  local want="$1" what="$2" st
  shift 2
  st="$(_probe_assert_rc "$@")"
  case "$want" in
    pass)
      [ "$st" = "0" ] ||
        _assert_layer_error "$what: 成功すべき呼び出しが終了コード ${st} で失敗した"
      ;;
    fail)
      [ "$st" = "0" ] &&
        _assert_layer_error "$what: 失敗すべき呼び出しが成功した（終了コード 0）"
      ;;
  esac
  return 0
}

_check_assert_layer() {
  local probe="$CTS_RUN_DIR/assert-layer"
  mkdir -p "$probe"
  : >"$probe/present"

  # 失敗すべきときに失敗すること。1つでも通ってしまえば、そのアサーションを
  # 使っている検証はすべて無意味である。
  _expect_assert fail assert_eq            assert_eq a b
  _expect_assert fail assert_ne            assert_ne a a
  _expect_assert fail assert_empty         assert_empty x
  _expect_assert fail assert_contains      assert_contains abc z
  _expect_assert fail assert_not_contains  assert_not_contains abc b
  _expect_assert fail assert_file_exists   assert_file_exists "$probe/absent"
  _expect_assert fail assert_file_missing  assert_file_missing "$probe/present"
  _expect_assert fail assert_count         assert_count 2 abc a
  _expect_assert fail assert_count_空needle assert_count 0 abc ""

  # 成功すべきときに成功すること。「常に失敗」への改変は全件赤で気づけるが、
  # ここで理由付きで落としたほうが原因の切り分けが早い。
  _expect_assert pass assert_eq            assert_eq a a
  _expect_assert pass assert_ne            assert_ne a b
  _expect_assert pass assert_empty         assert_empty ""
  _expect_assert pass assert_contains      assert_contains abc b
  _expect_assert pass assert_not_contains  assert_not_contains abc z
  _expect_assert pass assert_file_exists   assert_file_exists "$probe/present"
  _expect_assert pass assert_file_missing  assert_file_missing "$probe/absent"
  _expect_assert pass assert_count         assert_count 1 abc a

  # _fail は呼び出し元のシェルを終了させること。exit が return に化けると、
  # 失敗したあとの文が実行され続け、最後の文が成功すればテストは緑になる。
  # 終了コードだけを見る検査ではこの改変を捕まえられない。
  rm -f "$probe/after-fail"
  ( . "$TEST_DIR/lib/assert.sh"; assert_eq a b; : >"$probe/after-fail" ) >/dev/null 2>&1
  if [ -e "$probe/after-fail" ]; then
    _assert_layer_error "_fail が呼び出し元を終了させていない（失敗したあとの文が実行された）"
  fi

  # 失敗の理由が標準エラーへ出ること。出ないと FAIL の原因が追えない。
  local msg
  msg="$( ( . "$TEST_DIR/lib/assert.sh"; assert_eq expected_marker actual_marker ) 2>&1 )"
  case "$msg" in
    *expected_marker*) ;;
    *) _assert_layer_error "失敗の理由が標準エラーへ出ていない" ;;
  esac

  rm -rf "$probe"
}

_check_assert_layer

PATTERN="${1:-}"

# テスト1本あたりの上限時間（秒）。環境変数 CTS_TEST_TIMEOUT で変えられる。
TEST_TIMEOUT="${CTS_TEST_TIMEOUT:-120}"
TIMEOUT_BIN="$(command -v timeout || true)"

pass_count=0
fail_count=0
run_count=0
failed_names=()

# 先に対象ファイルを確定させる。0 件を「成功」にしないため、実行より前に判定する。
test_files=()
for test_file in "$TEST_DIR"/test-*.sh; do
  [ -f "$test_file" ] || continue
  base="$(basename "$test_file")"
  if [ -n "$PATTERN" ]; then
    case "$base" in
      *"$PATTERN"*) ;;
      *) continue ;;
    esac
  fi
  test_files+=("$test_file")
done

# 綴りを間違えたパターン指定や、テストファイルの消失・改名は「成功 0 件」ではなく
# エラーである。ここで落とさないと CI 上で何も走らないまま緑になる。
if [ "${#test_files[@]}" -eq 0 ]; then
  if [ -n "$PATTERN" ]; then
    printf 'エラー: パターン [%s] に一致するテストファイルが無い\n' "$PATTERN" >&2
  else
    printf 'エラー: テストファイルが1つも無い: %s/test-*.sh\n' "$TEST_DIR" >&2
  fi
  exit 1
fi

# ファイル本文から「関数定義の行」を拾って関数名を取り出す。
# 関数名には日本語が含まれるため、文字クラスは「使えない文字」の否定で書く。
# 行頭ちょうどに限定するのは、テストファイルへ埋め込まれた「細工したテスト本文」の
# 文字列を関数定義と数え違えないためである（埋め込む側は字下げする規約）。
_declared_function_names() {
  grep -oE '^(function[[:space:]]+)?[^[:space:]()=]+[[:space:]]*\(\)' "$1" \
    | sed -E 's/^(function[[:space:]]+)?//; s/[[:space:]]*\(\)$//'
}

# test に似た接頭辞（tets_ / tset_ / tst_ など）を疑う。綴りを間違えた関数は
# 一度も実行されないのに、件数が1つ減るだけで誰も気づかない。
# 判定は「test の文字を並べ替えた 4 文字」と「t を落とした tst」に限る。
# set_ のような正当な接頭辞まで巻き込まないための線引きである。
_is_typo_of_test() {
  local prefix sorted
  prefix="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  [ "$prefix" = "test" ] && return 1
  sorted="$(printf '%s' "$prefix" | grep -o . | LC_ALL=C sort | tr -d '\n')"
  case "$sorted" in
    estt | esstt | stt) return 0 ;;
  esac
  return 1
}

# 検証を1つも含まないテスト関数を探す。空の本文でも「ok」と出てしまうため、
# 件数の下限だけでは「実テストを空のテストで置き換えて件数を満たす」詐称を
# 見抜けない（実測: 39 件を `{ :; }` 39 件に置換して 191 件緑になった）。
# アサーションを直接呼ばず _fail で落とすテストもあるため、どちらかを要求する。
# 本文の抽出は行頭の定義から行頭の `}` まで。埋め込み本文は字下げの規約により
# 行頭に来ないので、ここには掛からない。
#
# ヒアドキュメントを読み飛ばすこと。テストは設定ファイルを `cat > ... <<EOF` で
# 流し込むため、その中の JSON の閉じ括弧が行頭に来る。これを関数本文の終端と
# 数え違えると、本文が途中で切れて「検証を含まない」と誤検出する。
_tests_without_assertion() {
  awk '
    function verdict() { if (body !~ /assert_|_fail/) print name }
    # ヒアドキュメントの開始タグを拾う。<<< はヒアストリングなので対象外。
    function scan_heredoc(line,   p, tok) {
      p = index(line, "<<")
      if (p == 0) return
      tok = substr(line, p + 2)
      if (substr(tok, 1, 1) == "<") return
      dash = (substr(tok, 1, 1) == "-")
      sub(/[ \t;|&<>()].*$/, "", tok)
      gsub(/[^A-Za-z0-9_]/, "", tok)
      if (tok != "") heredoc = tok
    }
    heredoc != "" {
      if (inbody) body = body "\n" $0
      line = $0
      if (dash) sub(/^[ \t]+/, "", line)
      if (line == heredoc) heredoc = ""
      next
    }
    /^(function[[:space:]]+)?test_[^[:space:]()=]*[[:space:]]*\(\)/ && !inbody {
      name = $0
      sub(/[[:space:]]*\(\).*/, "", name)
      sub(/^function[[:space:]]+/, "", name)
      body = $0
      inbody = 1
      if (index($0, "}") > 0) { verdict(); inbody = 0; next }
      scan_heredoc($0)
      next
    }
    inbody && /^\}/ { verdict(); inbody = 0; next }
    inbody { body = body "\n" $0; scan_heredoc($0); next }
    END { if (inbody) verdict() }
  ' "$1"
}

# アサーションの失敗が飲まれる書き方を探す。assert_* は _fail の exit で抜けるため、
# パイプやコマンド置換や明示のサブシェルの中で呼ぶと、失敗しても最内シェルしか
# 終了せず、テストは緑のまま進む（run.sh はテスト関数に set -e を掛けていない）。
# 意図してそう書く箇所（終了コード自体を検証するヘルパー）は、その行か直前の行に
# runner-allow と書いて除外する。行が継続行で終わって末尾コメントを置けない場合が
# あるため、直前の行でも認める。
_smothered_assertions() {
  local file="$1" ln rest prev
  grep -nE '\$\([[:space:]]*assert_|\([[:space:]]*(set[[:space:]]+-e;[[:space:]]*)?\.?[^)]*;[[:space:]]*assert_' "$file" \
    | while IFS=: read -r ln rest; do
        prev=$((ln - 1))
        [ "$prev" -lt 1 ] && prev=1
        if sed -n "${prev}p;${ln}p" "$file" | grep -q 'runner-allow'; then
          continue
        fi
        printf '%s:%s\n' "$ln" "$rest"
      done
}

declare -A file_run_count=()

for test_file in "${test_files[@]}"; do
  base="$(basename "$test_file")"
  file_run_count["$base"]=0

  printf '%s\n' "$base"

  # 先に構文検査する。列挙は source のエラーを捨てるため、関数定義より前に
  # 構文エラーがあると「テスト関数 0 件」に化け、壊れたテストが緑になる。
  syntax_rc=0
  syntax_err="$(bash -n "$test_file" 2>&1)" || syntax_rc=$?
  if [ "$syntax_rc" -ne 0 ]; then
    printf '  FAIL (構文エラー)\n'
    printf '%s\n' "$syntax_err"
    fail_count=$((fail_count + 1))
    failed_names+=("$base::(構文エラー)")
    continue
  fi

  # テスト関数名を列挙する。source は各関数の実行時に行うため、ここでは
  # 別プロセスで宣言を取り出すだけに留める（ファイル間の汚染を防ぐ）。
  # 実行順を安定させるため、ソートはロケールに依存しないバイト順で行う。
  enum_err="$(mktemp "${TMPDIR:-/tmp}/cts-enum.XXXXXX")"
  mapfile -t fns < <(
    {
      # shellcheck disable=SC1090
      . "$test_file" >/dev/null
      declare -F | awk '{print $3}' | grep '^test_' | LC_ALL=C sort
    } 2>"$enum_err"
  )
  enum_err_text="$(cat "$enum_err")"
  rm -f "$enum_err"

  # source した時点で出たエラーを捨てない。シェルを終了させないエラー
  # （存在しないコマンドの実行など）は構文検査を素通りし、テストが緑のままだと
  # 表示すらされない。何か言ってきたら、それは壊れているということである。
  if [ -n "$enum_err_text" ]; then
    printf '  FAIL (source 時にエラー出力)\n'
    printf '%s\n' "$enum_err_text"
    fail_count=$((fail_count + 1))
    failed_names+=("$base::(source 時にエラー出力)")
    continue
  fi

  mapfile -t declared_fns < <(_declared_function_names "$test_file")

  text_test_count=0
  typo_names=()
  for name in ${declared_fns[@]+"${declared_fns[@]}"}; do
    case "$name" in
      test_*)
        text_test_count=$((text_test_count + 1))
        continue
        ;;
    esac
    case "$name" in
      *_*) ;;
      *) continue ;;
    esac
    if _is_typo_of_test "${name%%_*}"; then
      typo_names+=("$name")
    fi
  done

  # 本文にある test_ 関数の数と、実際に定義された関数の数が食い違うなら、
  # 同名の関数が後勝ちで潰し合っている（＝検証が1つ静かに消えている）。
  if [ "$text_test_count" -ne "${#fns[@]}" ]; then
    printf '  FAIL (テスト関数の重複または列挙の食い違い: 本文 %d 件 / 実際 %d 件)\n' \
      "$text_test_count" "${#fns[@]}"
    fail_count=$((fail_count + 1))
    failed_names+=("$base::(テスト関数の重複)")
    continue
  fi

  if [ "${#typo_names[@]}" -ne 0 ]; then
    printf '  FAIL (test_ の綴り間違いらしき関数: %s)\n' "${typo_names[*]}"
    fail_count=$((fail_count + 1))
    failed_names+=("$base::(綴り間違い)")
    continue
  fi

  # 0 件は成功ではない。テストを書いたつもりで1つも走っていない状態を
  # 黙って通すと、他のテストの緑も信用できなくなる。
  if [ "${#fns[@]}" -eq 0 ]; then
    printf '  FAIL (テスト関数なし)\n'
    fail_count=$((fail_count + 1))
    failed_names+=("$base::(テスト関数なし)")
    continue
  fi

  mapfile -t no_assert_fns < <(_tests_without_assertion "$test_file")
  if [ "${#no_assert_fns[@]}" -ne 0 ]; then
    printf '  FAIL (検証を含まないテスト関数: %s)\n' "${no_assert_fns[*]}"
    fail_count=$((fail_count + 1))
    failed_names+=("$base::(検証を含まないテスト関数)")
    continue
  fi

  smothered="$(_smothered_assertions "$test_file")"
  if [ -n "$smothered" ]; then
    printf '  FAIL (失敗が飲まれる位置でアサーションを呼んでいる)\n'
    printf '%s\n' "$smothered"
    fail_count=$((fail_count + 1))
    failed_names+=("$base::(飲まれるアサーション)")
    continue
  fi

  for fn in "${fns[@]}"; do
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/cts-test.XXXXXX")"
    out_file="$tmp/.stderr"

    # 1本あたりの上限時間を掛ける。テストは背景ジョブと wait を使うため、
    # wait が返らないとスイート全体が無言で止まり、CI ではジョブの制限時間まで
    # 何が起きたか分からない。timeout が無い環境では素のサブシェルで走らせる。
    if [ -n "$TIMEOUT_BIN" ]; then
      TEST_TMP="$tmp" "$TIMEOUT_BIN" "$TEST_TIMEOUT" bash -c '
        set -uo pipefail
        cd "$TEST_TMP" || exit 1
        # shellcheck disable=SC1090
        . "$TEST_DIR/lib/assert.sh"
        # shellcheck disable=SC1090
        . "$1"
        "$2"
      ' _ "$test_file" "$fn" 2>"$out_file"
      status=$?
    else
      (
        set -uo pipefail
        export TEST_TMP="$tmp"
        cd "$tmp" || exit 1
        # shellcheck disable=SC1090
        . "$TEST_DIR/lib/assert.sh"
        # shellcheck disable=SC1090
        . "$test_file"
        "$fn"
      ) 2>"$out_file"
      status=$?
    fi
    run_count=$((run_count + 1))
    file_run_count["$base"]=$((file_run_count["$base"] + 1))

    if [ "$status" -eq 0 ]; then
      printf '  ok   %s\n' "$fn"
      pass_count=$((pass_count + 1))
    elif [ "$status" -eq 124 ] && [ -n "$TIMEOUT_BIN" ]; then
      printf '  FAIL %s (制限時間 %s 秒を超えた)\n' "$fn" "$TEST_TIMEOUT"
      [ -s "$out_file" ] && cat "$out_file"
      fail_count=$((fail_count + 1))
      failed_names+=("$base::$fn(時間切れ)")
    else
      printf '  FAIL %s\n' "$fn"
      [ -s "$out_file" ] && cat "$out_file"
      fail_count=$((fail_count + 1))
      failed_names+=("$base::$fn")
    fi

    rm -rf "$tmp"
  done
done

# 実行件数の下限を検査する。ファイルが丸ごと消えても「成功 N 件」としか出ないため、
# N が減ったこと自体を検出する必要がある。件数はスクリプトに埋めない（日々増減するため）。
#
# 台帳の書式は1行につき「整数」＝総件数、「ファイル名 整数」＝そのファイルの件数。
# 総件数だけでは、実テストを空のテストや別ファイルで置き換えた詐称を見抜けないため、
# ファイル別の件数も持つ。
#
# 台帳が無いことを「無検査」で通してはならない。台帳ひとつの消失で、件数が減った
# ことを知る唯一の手段が無言で失われる（実測: 台帳を消すと 39 件の消滅が無警告で
# 緑になった）。無検査にしたいときは CTS_MIN_TESTS=0 を明示させる。
ledger="$TEST_DIR/expected-min-count"
min_tests=""
declare -A file_min=()
skip_count_check=0

if [ "${CTS_MIN_TESTS:-}" = "0" ]; then
  skip_count_check=1
  printf '注意: CTS_MIN_TESTS=0 のため実行件数を検査しない\n'
elif [ ! -f "$ledger" ]; then
  printf 'エラー: 実行件数の台帳が無い: %s\n' "$ledger" >&2
  printf '       件数が減ったことを検出できないため実行を失敗させる。\n' >&2
  printf '       意図して無検査にするなら CTS_MIN_TESTS=0 を指定すること。\n' >&2
  exit 1
else
  while read -r field1 field2 _rest; do
    [ -n "$field1" ] || continue
    case "$field1" in
      '#'*) continue ;;
    esac
    if [ -n "$field2" ]; then
      file_min["$field1"]="$field2"
    else
      min_tests="$field1"
    fi
  done < <(grep -vE '^[[:space:]]*(#|$)' "$ledger")

  if [ -n "${CTS_MIN_TESTS:-}" ]; then
    min_tests="$CTS_MIN_TESTS"
  fi
fi

shortfall=""
if [ "$skip_count_check" -eq 0 ]; then
  # ファイル別の下限は、パターン指定で一部だけ回すときにも検査できる。
  # 台帳に載っているのに今回まったく走らなかったファイルは、全件実行のときだけ
  # 「消えた」と判断する（パターン指定なら選ばれなかっただけである）。
  for name in "${!file_min[@]}"; do
    want="${file_min[$name]}"
    case "$want" in
      '' | *[!0-9]*)
        printf 'エラー: 台帳のファイル別下限が整数でない: [%s %s]\n' "$name" "$want" >&2
        exit 1
        ;;
    esac
    got="${file_run_count[$name]:-}"
    if [ -z "$got" ]; then
      if [ -z "$PATTERN" ]; then
        shortfall="台帳にあるテストファイルが実行されていない: ${name}（下限 ${want} 件）"
      fi
      continue
    fi
    if [ "$got" -lt "$want" ]; then
      shortfall="${name} の実行件数が下限を下回る: 実行 ${got} 件 / 下限 ${want} 件"
    fi
  done

  # 総件数は全件実行のときだけ意味を持つ（一部だけ回せば常に下回る）。
  if [ -z "$PATTERN" ] && [ -n "$min_tests" ]; then
    case "$min_tests" in
      '' | *[!0-9]*)
        printf 'エラー: 実行件数の下限が整数でない: [%s]\n' "$min_tests" >&2
        exit 1
        ;;
    esac
    printf '実行件数の下限: 総 %s 件 / ファイル別 %s 件分\n' "$min_tests" "${#file_min[@]}"
    if [ "$run_count" -lt "$min_tests" ]; then
      shortfall="実行件数が下限を下回る: 実行 ${run_count} 件 / 下限 ${min_tests} 件"
    fi
  fi
fi

printf '\n'
if [ "$fail_count" -eq 0 ] && [ -z "$shortfall" ]; then
  printf '成功 %d 件 / 失敗 0 件\n' "$pass_count"
  exit 0
fi

printf '成功 %d 件 / 失敗 %d 件\n' "$pass_count" "$fail_count"
if [ "${#failed_names[@]}" -ne 0 ]; then
  printf '失敗したテスト:\n'
  for name in "${failed_names[@]}"; do
    printf '  - %s\n' "$name"
  done
fi
if [ -n "$shortfall" ]; then
  printf 'エラー: %s\n' "$shortfall" >&2
fi
exit 1
