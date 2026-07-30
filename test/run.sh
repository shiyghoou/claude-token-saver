#!/usr/bin/env bash
# 依存ゼロの bash テストランナー。
#
#   test/run.sh              全テストを実行
#   test/run.sh handoff      ファイル名に handoff を含むテストのみ実行
#
# テストファイルは test/test-*.sh。中で test_ で始まる関数を定義する。
# 各テスト関数はサブシェルで、専用の一時ディレクトリ（$TEST_TMP）を CWD として実行される。

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
export TEST_DIR REPO_ROOT

# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"

PATTERN="${1:-}"

pass_count=0
fail_count=0
failed_names=()

for test_file in "$TEST_DIR"/test-*.sh; do
  [ -f "$test_file" ] || continue
  base="$(basename "$test_file")"
  if [ -n "$PATTERN" ]; then
    case "$base" in
      *"$PATTERN"*) ;;
      *) continue ;;
    esac
  fi

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
  mapfile -t fns < <(
    # shellcheck disable=SC1090
    . "$test_file" >/dev/null 2>&1
    declare -F | awk '{print $3}' | grep '^test_' | sort
  )

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

printf '\n'
if [ "$fail_count" -eq 0 ]; then
  printf '成功 %d 件 / 失敗 0 件\n' "$pass_count"
  exit 0
fi

printf '成功 %d 件 / 失敗 %d 件\n' "$pass_count" "$fail_count"
printf '失敗したテスト:\n'
for name in "${failed_names[@]}"; do
  printf '  - %s\n' "$name"
done
exit 1
