#!/usr/bin/env bash
# install.sh を取り消す。
#
#   cd <導入先リポジトリ> && /path/to/claude-token-saver/uninstall.sh
#   uninstall.sh <導入先ディレクトリ>
#
# .claude/.handoff/ 配下の実ファイルは消さない。引き継ぎは作業の記録であり、
# アンインストールで失われてよいものではない。

set -uo pipefail

CTS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET="$(cd "${1:-$PWD}" 2>/dev/null && pwd -P)" || {
  printf 'エラー: 導入先ディレクトリが見つからない: %s\n' "${1:-$PWD}" >&2
  exit 1
}

SETTINGS="$TARGET/.claude/settings.local.json"
GITIGNORE="$TARGET/.gitignore"

die() { printf 'エラー: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

command -v python3 >/dev/null 2>&1 ||
  die "python3 が必要である（settings.local.json を壊さずに編集するため）。"

info "claude-token-saver を取り外す: $TARGET"

# --- 1. フックの登録解除 -----------------------------------------------------

# コマンドのファイル名で判定する。別のクローンから導入されていても外せるようにするため。
# 判定は install.sh と共有する（lib/settings-hooks.py）。
if [ -f "$SETTINGS" ]; then
  python3 "$CTS_HOME/lib/settings-hooks.py" remove "$SETTINGS" ||
    die "settings.local.json を更新できない"
else
  info "  settings.local.json が無い"
fi

# --- 2. .gitignore -----------------------------------------------------------

if [ -f "$GITIGNORE" ]; then
  python3 "$CTS_HOME/lib/gitignore-block.py" remove "$GITIGNORE" ||
    die ".gitignore を更新できない"
fi

# --- 3. スキル ---------------------------------------------------------------

# 導入先の skills を走査する。CTS_HOME 側を基準にすると、導入時とは別の
# クローン（スキルの構成が違う）で実行したときに取り残しが出る。
if [ -d "$TARGET/.claude/skills" ]; then
  for dest in "$TARGET/.claude/skills"/*; do
    [ -e "$dest" ] || [ -L "$dest" ] || continue
    name="$(basename "$dest")"

    if [ -L "$dest" ]; then
      # どこかのクローンの skills/<同名> を指すリンクだけを外す。
      # 導入先が自分で張った別のリンクは触らない。
      link="$(readlink "$dest")"
      if [ "$(basename "$link")" = "$name" ] &&
         [ "$(basename "$(dirname "$link")")" = "skills" ]; then
        rm -f "$dest"
        info "  スキルのリンクを外した: $name"
      else
        info "  スキル $name は導入先のものなので残す"
      fi
    elif [ -d "$dest" ] && [ -f "$dest/.claude-token-saver" ]; then
      rm -rf "$dest"
      info "  スキルのコピーを削除した: $name"
    fi
  done
fi

# 空になった skills ディレクトリは片付ける。中身があるなら触らない。
rmdir "$TARGET/.claude/skills" 2>/dev/null || true

# --- 4. 残したものの通知と後片付け -------------------------------------------

handoff_dir="$TARGET/.claude/.handoff"
if [ -d "$handoff_dir" ] && [ -n "$(find "$handoff_dir" -type f -print -quit 2>/dev/null)" ]; then
  info ""
  info "引き継ぎのファイルは残した: .claude/.handoff"
  info "  作業の記録であるため、アンインストールでは削除しない。不要なら手で削除せよ。"
  info "  .gitignore の除外は外れているので、版管理から外したいなら注意せよ。"
fi

state_dir="$TARGET/.claude/.token-saver"
if [ -d "$state_dir" ] && [ -n "$(find "$state_dir" -type f -print -quit 2>/dev/null)" ]; then
  info "状態ファイルは残した: .claude/.token-saver"
fi

# install.sh が作った空の器を残さない。rmdir は空でなければ何もしないので、
# 実ファイルのある .handoff は従来どおり残る。
rmdir "$handoff_dir/pending" "$handoff_dir/consumed" 2>/dev/null || true
rmdir "$handoff_dir" "$state_dir" 2>/dev/null || true

# 中身が無くなったファイルは、install.sh より前には存在しなかったものである。
[ -f "$GITIGNORE" ] && [ ! -s "$GITIGNORE" ] && rm -f "$GITIGNORE"
if [ -f "$SETTINGS" ] &&
   [ "$(tr -d ' \t\n\r' <"$SETTINGS")" = "{}" ]; then
  rm -f "$SETTINGS"
fi
rmdir "$TARGET/.claude" 2>/dev/null || true

info "完了。"
