#!/usr/bin/env bash
# 依存ゼロの bash テストランナー。
#
#   test/run.sh              全テストを実行
#   test/run.sh handoff      ファイル名に handoff を含むテストのみ実行
#
# テストファイルは test/test-*.sh。中で test_ で始まる関数を定義する。
# 各テスト関数はサブシェルで、専用の一時ディレクトリ（$TEST_TMP）を CWD として実行される。
#
# 全件実行時は test/expected-min-count（1行の整数）を下限として実行件数を検査する。
# 環境変数 CTS_MIN_TESTS が優先される。どちらも無ければ検査しない。

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
export TEST_DIR REPO_ROOT

# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"

PATTERN="${1:-}"

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

for test_file in "${test_files[@]}"; do
  base="$(basename "$test_file")"

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

  for fn in "${fns[@]}"; do
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/cts-test.XXXXXX")"
    out_file="$tmp/.stderr"

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
    run_count=$((run_count + 1))

    if [ "$status" -eq 0 ]; then
      printf '  ok   %s\n' "$fn"
      pass_count=$((pass_count + 1))
    else
      printf '  FAIL %s\n' "$fn"
      [ -s "$out_file" ] && cat "$out_file"
      fail_count=$((fail_count + 1))
      failed_names+=("$base::$fn")
    fi

    rm -rf "$tmp"
  done
done

# 全件実行のときだけ、実行件数の下限を検査する。ファイルが丸ごと消えても
# 「成功 N 件」としか出ないため、N が減ったこと自体を検出する必要がある。
# 件数はスクリプトに埋めない（テストは日々増減するため）。
min_tests=""
if [ -n "${CTS_MIN_TESTS:-}" ]; then
  min_tests="$CTS_MIN_TESTS"
elif [ -f "$TEST_DIR/expected-min-count" ]; then
  min_tests="$(grep -vE '^[[:space:]]*(#|$)' "$TEST_DIR/expected-min-count" | head -1 | tr -d '[:space:]')"
fi

shortfall=""
if [ -z "$PATTERN" ] && [ -n "$min_tests" ]; then
  case "$min_tests" in
    '' | *[!0-9]*)
      printf 'エラー: 実行件数の下限が整数でない: [%s]\n' "$min_tests" >&2
      exit 1
      ;;
  esac
  if [ "$run_count" -lt "$min_tests" ]; then
    shortfall="実行件数が下限を下回る: 実行 ${run_count} 件 / 下限 ${min_tests} 件"
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
