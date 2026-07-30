#!/usr/bin/env bash
# install.sh を取り消す。
#
#   cd <導入先リポジトリ> && /path/to/claude-token-saver/uninstall.sh
#   uninstall.sh <導入先ディレクトリ>
#
# .claude/.handoff/ 配下の実ファイルは消さない。引き継ぎは作業の記録であり、
# アンインストールで失われてよいものではない。
#
# 何を外すかは台帳（.claude/.token-saver/installed.json）を正とする。
# 台帳が無い旧環境向けの推測は残すが、条件を厳しくしてある。
# 環境変数 CTS_STRICT=1 で、警告があれば終了コードを非 0 にする（CI 向け）。

set -uo pipefail

CTS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET="$(cd "${1:-$PWD}" 2>/dev/null && pwd -P)" || {
  printf 'エラー: 導入先ディレクトリが見つからない: %s\n' "${1:-$PWD}" >&2
  exit 1
}

SETTINGS="$TARGET/.claude/settings.local.json"
BACKUP="$SETTINGS.cts-backup"
GITIGNORE="$TARGET/.gitignore"
LEDGER="$TARGET/.claude/.token-saver/installed.json"

warnings=()

die() { printf 'エラー: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
warn() {
  warnings+=("$*")
  printf '  警告: %s\n' "$*"
}

command -v python3 >/dev/null 2>&1 ||
  die "python3 が必要である（settings.local.json を壊さずに編集するため）。"

info "claude-token-saver を取り外す: $TARGET"

have_ledger=0
[ -f "$LEDGER" ] && have_ledger=1

# --- 1. フックの登録解除 -----------------------------------------------------

# 台帳に記録した登録コマンドと一致するものを外す。台帳が無ければファイル名で
# 推測する（利用者の自作を巻き込みうるフォールバックである）。
# 判定は install.sh と共有する（lib/settings-hooks.py）。
if [ -f "$SETTINGS" ]; then
  python3 "$CTS_HOME/lib/settings-hooks.py" remove "$SETTINGS" --ledger "$LEDGER" ||
    die "settings.local.json を更新できない"
else
  info "  settings.local.json が無い"
fi

# --- 2. .gitignore -----------------------------------------------------------

if [ -f "$GITIGNORE" ]; then
  python3 "$CTS_HOME/lib/gitignore-block.py" remove "$GITIGNORE"
  case "$?" in
    0) ;;
    2) warnings+=(".gitignore の claude-token-saver ブロックが壊れているため削除していない") ;;
    *) die ".gitignore を更新できない" ;;
  esac
fi

# --- 3. スキル ---------------------------------------------------------------

# 台帳が無い旧環境向けの推測。リンク先が「どこかのクローンの skills/<同名>」で
# あり、その親に install.sh が実在するときだけ自分のものとみなす。
# basename と親ディレクトリ名だけで判定すると、利用者が社内共有の skills/ へ
# 張ったリンクまで削除してしまう。
looks_like_our_link() {
  local link="$1" name="$2" home
  [ "$(basename "$link")" = "$name" ] || return 1
  [ "$(basename "$(dirname "$link")")" = "skills" ] || return 1
  home="$(dirname "$(dirname "$link")")"
  [ -f "$home/install.sh" ]
}

# 設置したものだけを外す。dest が記録どおりでなければ、導入後に導入先が
# 差し替えたということなので触らない。
remove_skill() {
  local name="$1" src="$2" dest="$TARGET/.claude/skills/$1"
  if [ -L "$dest" ]; then
    if [ -z "$src" ] || [ "$(readlink "$dest")" = "$src" ]; then
      rm -f "$dest"
      info "  スキルのリンクを外した: $name"
      return 0
    fi
  elif [ -d "$dest" ] && [ -f "$dest/.claude-token-saver" ]; then
    rm -rf "$dest"
    info "  スキルのコピーを削除した: $name"
    return 0
  elif [ ! -e "$dest" ]; then
    return 0
  fi
  info "  スキル $name は導入後に差し替えられているので残す"
}

if [ "$have_ledger" = 1 ]; then
  while IFS=$'\t' read -r name src _mode; do
    [ -n "$name" ] || continue
    remove_skill "$name" "$src"
  done < <(python3 "$CTS_HOME/lib/ledger.py" list-skills "$LEDGER")
elif [ -d "$TARGET/.claude/skills" ]; then
  # 台帳が無い。導入先の skills を走査して推測する。
  for dest in "$TARGET/.claude/skills"/*; do
    [ -e "$dest" ] || [ -L "$dest" ] || continue
    name="$(basename "$dest")"

    if [ -L "$dest" ]; then
      if looks_like_our_link "$(readlink "$dest")" "$name"; then
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

# .gitignore を消してよいかは、install.sh が作ったかどうかで決まる。
# 追跡済みの空の .gitignore を消すと、利用者のコミットから勝手に消える。
gitignore_created=0
[ "$have_ledger" = 1 ] &&
  gitignore_created="$(python3 "$CTS_HOME/lib/ledger.py" get-flag "$LEDGER" gitignore_created)"

# 台帳はここで役目を終える。以降の「状態ファイルが残っている」判定に
# 自分の記録を数えさせない。
rm -f "$LEDGER"

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

# 中身が無くなったファイルのうち、install.sh より前には無かったものを消す。
if [ "$gitignore_created" = 1 ] && [ -f "$GITIGNORE" ] && [ ! -s "$GITIGNORE" ]; then
  rm -f "$GITIGNORE"
fi
if [ -f "$SETTINGS" ] &&
   [ "$(tr -d ' \t\n\r' <"$SETTINGS")" = "{}" ]; then
  rm -f "$SETTINGS"
fi

# 控えは、原状へ戻っているなら不要である。個人設定のコピーを黙って
# 置き去りにすると、.claude/ を版管理している利用者が誤ってコミットしうる。
if [ -e "$BACKUP" ]; then
  if python3 "$CTS_HOME/lib/settings-hooks.py" same "$SETTINGS" "$BACKUP"; then
    rm -f "$BACKUP"
  else
    info "  settings.local.json が控えと異なるため、控えを残した: $BACKUP"
    info "    導入後に設定を変えている。不要なら手で削除せよ。"
  fi
fi

rmdir "$TARGET/.claude" 2>/dev/null || true

if [ "${#warnings[@]}" -gt 0 ]; then
  info ""
  info "警告 ${#warnings[@]} 件（外し切れていない項目がある）:"
  printf '  - %s\n' "${warnings[@]}"
  info "内容を確認せよ。"
  [ -n "${CTS_STRICT:-}" ] && exit 1
else
  info "完了。"
fi
exit 0
