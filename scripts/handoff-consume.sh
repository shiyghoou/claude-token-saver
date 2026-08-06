#!/usr/bin/env bash
# pending の引き継ぎを consumed へ移す。
#
#   handoff-consume.sh              pending の全ファイルを移す
#   handoff-consume.sh <path>...    指定したファイルのみ移す
#
# handoff-check.sh が自動で行う消費と同じ処理を、手からも呼べるようにしたもの。
# 逆（consumed → pending への差し戻し）は mv で足りるため用意しない。
#
# 移動元は handoff-check と同じ境界に従う:
# - .token-saver / handoff / pending の親 symlink を拒否する
# - handoff は project 配下、pending は handoff 配下であること
# - エントリ自身の絶対パス（最終 symlink はたどらない）が pending_real 配下であること

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

project_dir="$(cts_project_dir)"
state_dir="$project_dir/$(cts_base_rel)"
handoff_dir="$state_dir/handoff"
pending_dir="$handoff_dir/pending"
consumed_dir="$handoff_dir/consumed"
pending_real=""

# エラー表示でもファイル名・パスは攻撃者制御値である。属性と同じ byte-level
# エンコーダーを通し、エンコードできない場合は値を含まない固定文へ倒す。
cts_consume_diagnostic() {
  local label="$1" path="$2" encoded
  if encoded="$(cts_encode_attribute "$path" 2>/dev/null)"; then
    printf '%s: %s\n' "$label" "$encoded" >&2
  else
    printf '%s。\n' "$label" >&2
  fi
}

# 親 symlink / 置き場境界を handoff-check と同じ順で確認する。
# 成功時は pending_real を設定する。失敗理由は CTS_CONSUME_BOUNDARY_KIND に入れる。
CTS_CONSUME_BOUNDARY_KIND=""
cts_consume_prepare_boundaries() {
  local project_real handoff_real
  CTS_CONSUME_BOUNDARY_KIND=""
  pending_real=""

  if [ -L "$state_dir" ] || [ -L "$handoff_dir" ] || [ -L "$pending_dir" ]; then
    CTS_CONSUME_BOUNDARY_KIND="parent-symlink"
    return 1
  fi
  if [ ! -d "$pending_dir" ]; then
    CTS_CONSUME_BOUNDARY_KIND="missing-pending"
    return 1
  fi

  project_real="$(cd -P -- "$project_dir" 2>/dev/null && pwd -P)" || project_real=""
  handoff_real="$(cd -P -- "$handoff_dir" 2>/dev/null && pwd -P)" || handoff_real=""
  pending_real="$(cd -P -- "$pending_dir" 2>/dev/null && pwd -P)" || {
    CTS_CONSUME_BOUNDARY_KIND="pending-unresolvable"
    pending_real=""
    return 1
  }
  if [ -z "$project_real" ] || ! cts_path_is_within "$handoff_real" "$project_real"; then
    CTS_CONSUME_BOUNDARY_KIND="handoff-outside-project"
    pending_real=""
    return 1
  fi
  if ! cts_path_is_within "$pending_real" "$handoff_real"; then
    CTS_CONSUME_BOUNDARY_KIND="pending-outside-handoff"
    pending_real=""
    return 1
  fi
  return 0
}

# 最終シンボリックリンクはたどらず、親ディレクトリだけを実パス解決したうえで
# エントリ自身が pending_real 配下かを見る。リンク先が pending 外でも、
# pending 直下のリンクエントリ自体は消費対象にできる（handoff-check と同じ）。
cts_consume_entry_under_pending() {
  local src="$1" dir base entry
  [ -n "$pending_real" ] || return 1
  cts_path_parts "$src"
  dir="$CTS_PATH_DIRNAME"
  base="$CTS_PATH_BASENAME"
  dir="$(cd -P -- "$dir" 2>/dev/null && pwd -P && printf '\001')" || return 1
  dir="${dir%$'\001'}"
  dir="${dir%$'\n'}"
  [ -n "$dir" ] || return 1
  case "$dir" in
    */) entry="$dir$base" ;;
    *) entry="$dir/$base" ;;
  esac
  cts_path_is_within "$entry" "$pending_real"
}

cts_consume_one() {
  local f="$1"
  if [ -L "$f" ]; then
    :
  elif [ ! -f "$f" ]; then
    cts_consume_diagnostic "通常ファイルではない" "$f"
    return 1
  fi
  if ! cts_consume_entry_under_pending "$f"; then
    cts_consume_diagnostic "pending 配下ではない" "$f"
    return 1
  fi
  cts_consume_file "$f" "$consumed_dir" || {
    cts_consume_diagnostic "消費できなかった" "$f"
    return 1
  }
  return 0
}

# ハイフンで始まるパスを引数として渡せるようにする。
if [ "$#" -gt 0 ] && [ "$1" = "--" ]; then
  shift
fi

if ! cts_consume_prepare_boundaries; then
  case "$CTS_CONSUME_BOUNDARY_KIND" in
    missing-pending)
      # 一括は pending が無ければ成功扱い。明示指定は後段で個別に拒否する。
      if [ "$#" -eq 0 ]; then
        exit 0
      fi
      ;;
    parent-symlink)
      printf 'handoff 置き場の親が symlink のため消費しない。\n' >&2
      exit 1
      ;;
    *)
      printf 'handoff 置き場の境界を確認できないため消費しない。\n' >&2
      exit 1
      ;;
  esac
fi

if [ "$#" -gt 0 ]; then
  # 明示的に指定されたものは黙って飛ばさない。無音で成功扱いにすると、
  # タイプミスやディレクトリ指定が「消費できたつもり」に化ける。
  # 引数なしの一括処理とは違い、ここでは対象が存在するはずである。
  rc=0
  for f in "$@"; do
    cts_consume_one "$f" || rc=1
  done
  exit "$rc"
fi

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
  cts_consume_one "$f" || rc=1
done
exit "$rc"
