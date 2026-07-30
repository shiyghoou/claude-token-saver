#!/usr/bin/env bash
# pending の引き継ぎを consumed へ移す。
#
#   handoff-consume.sh              pending の全ファイルを移す
#   handoff-consume.sh <path>...    指定したファイルのみ移す
#
# handoff-check.sh が自動で行う消費と同じ処理を、手からも呼べるようにしたもの。
# 逆（consumed → pending への差し戻し）は mv で足りるため用意しない。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

consumed_dir="$(cts_handoff_dir)/consumed"

# ハイフンで始まるパスを引数として渡せるようにする。
if [ "$#" -gt 0 ] && [ "$1" = "--" ]; then
  shift
fi

if [ "$#" -gt 0 ]; then
  # 明示的に指定されたものは黙って飛ばさない。無音で成功扱いにすると、
  # タイプミスやディレクトリ指定が「消費できたつもり」に化ける。
  # 引数なしの一括処理とは違い、ここでは対象が存在するはずである。
  rc=0
  for f in "$@"; do
    if [ ! -f "$f" ]; then
      printf '通常ファイルではない: %s\n' "$f" >&2
      rc=1
      continue
    fi
    cts_consume_file "$f" "$consumed_dir" || { printf '消費できなかった: %s\n' "$f" >&2; rc=1; }
  done
  exit "$rc"
fi

pending_dir="$(cts_handoff_dir)/pending"
[ -d "$pending_dir" ] || exit 0

# サブディレクトリは対象にしない。下書きを置く場所として使えるようにするため。
# 名前に改行を含むファイルで壊れないよう NUL 区切りで受け渡す。
# -L はシンボリックリンクをたどる（handoff-check.sh と揃える）。
while IFS= read -r -d '' f; do
  cts_consume_file "$f" "$consumed_dir" || exit 1
done < <(find -L "$pending_dir" -maxdepth 1 -type f -print0 2>/dev/null | LC_ALL=C sort -z)
