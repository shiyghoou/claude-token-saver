#!/usr/bin/env bash
# SessionStart フック。未消費の引き継ぎがあれば中身を注入し、consumed へ移す。
#
# 設計上の制約:
# - 未消費ゼロなら何も出力しない。未導入時と挙動が変わらないこと。
# - 何が起きても終了コード 0 で抜ける。セッション起動を妨げないこと。
# - compact では発火しない。圧縮のたびに引き継ぎが消費されるのを避ける。

set -uo pipefail

# 失敗してもセッション起動を止めない。
trap 'exit 0' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh" || exit 0

cts_read_payload

# 発火源を限定する。空はフックではなく手動実行とみなし、発火させる。
source_kind="$(cts_json_field source)"
case "$source_kind" in
  startup | clear | resume | "") ;;
  *) exit 0 ;;
esac

handoff_dir="$(cts_handoff_dir)"
pending_dir="$handoff_dir/pending"
consumed_dir="$handoff_dir/consumed"

[ -d "$pending_dir" ] || exit 0

# ファイル名の昇順で集める。引き継ぎ名は先頭がタイムスタンプであり（SKILL.md が規定）、
# 名前順がそのまま時刻の昇順になる。ロケールに左右されないよう LC_ALL=C で並べる。
pending_files=()
while IFS= read -r f; do
  [ -n "$f" ] && pending_files+=("$f")
done < <(find "$pending_dir" -maxdepth 1 -type f -print 2>/dev/null | LC_ALL=C sort)

[ "${#pending_files[@]}" -gt 0 ] || exit 0

printf '前のセッションからの引き継ぎが %d 件ある。\n' "${#pending_files[@]}"
printf '内容を要約してユーザーへ提示し、指示を待て。「次の一手」に自動で着手してはならない。\n'
printf '引き継ぎが古い、または現在の状況と食い違う場合は、その旨を指摘せよ。\n'

for f in "${pending_files[@]}"; do
  printf '\n--- %s ---\n' "$(basename "$f")"
  cat "$f" 2>/dev/null || true
done

# 出力し終えてから消費する。途中で落ちた場合に pending が残るほうが安全である。
for f in "${pending_files[@]}"; do
  cts_consume_file "$f" "$consumed_dir" 2>/dev/null || true
done

exit 0
