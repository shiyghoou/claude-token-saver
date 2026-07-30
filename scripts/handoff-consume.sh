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

if [ "$#" -gt 0 ]; then
  for f in "$@"; do
    [ -f "$f" ] || continue
    cts_consume_file "$f" "$consumed_dir" || exit 1
  done
  exit 0
fi

pending_dir="$(cts_handoff_dir)/pending"
[ -d "$pending_dir" ] || exit 0

# サブディレクトリは対象にしない。下書きを置く場所として使えるようにするため。
while IFS= read -r f; do
  [ -n "$f" ] || continue
  cts_consume_file "$f" "$consumed_dir" || exit 1
done < <(find "$pending_dir" -maxdepth 1 -type f -print 2>/dev/null | LC_ALL=C sort)
