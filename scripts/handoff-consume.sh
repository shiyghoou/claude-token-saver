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
# 名前に改行を含むファイルでも壊れないよう Bash 配列で受け渡す。
# -L はシンボリックリンクをたどる（handoff-check.sh と揃える）。
rc=0
export LC_ALL=C
entries=()
for f in "$pending_dir"/* "$pending_dir"/.[!.]* "$pending_dir"/..?*; do
  [ -f "$f" ] && entries+=("$f")
done

i=1
while [ "$i" -lt "${#entries[@]}" ]; do
  key="${entries[$i]}"
  j=$((i - 1))
  while [ "$j" -ge 0 ] && [[ "${entries[$j]}" > "$key" ]]; do
    entries[$((j + 1))]="${entries[$j]}"
    j=$((j - 1))
  done
  entries[$((j + 1))]="$key"
  i=$((i + 1))
done

for f in ${entries[@]+"${entries[@]}"}; do
  if ! cts_consume_file "$f" "$consumed_dir"; then
    printf '消費できなかった: %s\n' "$f" >&2
    rc=1
  fi
done
exit "$rc"
