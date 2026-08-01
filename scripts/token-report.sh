#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE="$SCRIPT_DIR/measure-token-usage.py"
# shellcheck source=scripts/lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh" || exit 1

explicit_out=0
expect_out_value=0
out_path=""
tmp_out=""
report_path=""
default_output=0

cleanup() {
  rm -f "$marker"
  if [ -n "$tmp_out" ]; then
    rm -f "$tmp_out"
  fi
}

for arg in "$@"; do
  if [ "$expect_out_value" -eq 1 ]; then
    out_path="$arg"
    expect_out_value=0
    continue
  fi
  case "$arg" in
    --out)
      explicit_out=1
      expect_out_value=1
      ;;
    --out=*)
      explicit_out=1
      out_path="${arg#--out=}"
      ;;
  esac
done

if [ "$explicit_out" -eq 0 ]; then
  default_output=1
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'python3 が見つかりません: %s を実行できません\n' "$ENGINE" >&2
  exit 1
fi

marker="$(mktemp "${TMPDIR:-/tmp}/cts-token-report.XXXXXX")" || {
  printf '更新検査用の一時ファイルを作成できません\n' >&2
  exit 1
}
trap cleanup EXIT

if [ "$default_output" -eq 1 ]; then
  tmp_out="$(mktemp "${TMPDIR:-/tmp}/cts-token-report-output.XXXXXX")" || {
    printf '一時レポートを作成できません\n' >&2
    exit 1
  }
  report_path="$tmp_out"
  set -- "$@" --out "$report_path"
else
  report_path="$out_path"
fi

python3 -B "$ENGINE" "$@"
status=$?
if [ "$status" -ne 0 ]; then
  exit "$status"
fi

if [ -z "$report_path" ]; then
  printf 'レポート出力先を特定できませんでした\n' >&2
  exit 1
fi

if [ ! -e "$report_path" ] && [ ! -L "$report_path" ]; then
  printf 'レポートが作成されていません: %s\n' "$report_path" >&2
  exit 1
fi

if [ ! -s "$report_path" ]; then
  printf 'レポートが空です: %s\n' "$report_path" >&2
  exit 1
fi

if [ ! "$report_path" -nt "$marker" ]; then
  printf 'レポートがこの実行で更新されていません: %s\n' "$report_path" >&2
  exit 1
fi

head_lines="$(sed -n '1,40p' "$report_path")"
case "$head_lines" in
  *"## 計測条件"*) ;;
  *)
    printf 'レポート先頭に計測条件セクションがありません: %s\n' "$report_path" >&2
    exit 1
    ;;
esac

if [ "$default_output" -eq 1 ]; then
  report_dir="$REPO_ROOT/$(cts_base_rel)/token-reports"
  mkdir -p "$report_dir" || {
    printf 'レポート出力先を作成できません: %s\n' "$report_dir" >&2
    exit 1
  }
  stamp="$(date +%Y%m%d-%H%M%S)" || exit 1
  out_path="$report_dir/$stamp.md"
  suffix=2
  while [ -e "$out_path" ] || [ -L "$out_path" ]; do
    out_path="$report_dir/$stamp-$suffix.md"
    suffix=$((suffix + 1))
  done
  mv -- "$report_path" "$out_path" || {
    printf '検証済みレポートを移動できません: %s\n' "$out_path" >&2
    exit 1
  }
  tmp_out=""
  report_path="$out_path"
fi

printf '書き出しました: %s\n' "$out_path"
