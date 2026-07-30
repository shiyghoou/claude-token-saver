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

  # テスト関数名を列挙する。source は各関数の実行時に行うため、ここでは
  # 別プロセスで宣言を取り出すだけに留める（ファイル間の汚染を防ぐ）。
  mapfile -t fns < <(
    # shellcheck disable=SC1090
    . "$test_file" >/dev/null 2>&1
    declare -F | awk '{print $3}' | grep '^test_' | sort
  )

  if [ "${#fns[@]}" -eq 0 ]; then
    printf '  (テスト関数なし)\n'
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
