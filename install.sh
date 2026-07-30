#!/usr/bin/env bash
# claude-token-saver を導入先リポジトリへインストールする。
#
#   cd <導入先リポジトリ> && /path/to/claude-token-saver/install.sh
#   install.sh <導入先ディレクトリ>
#
# 冪等である。二度実行しても設定は重複しない。
# 環境変数 CTS_NO_SYMLINK=1 でスキルのリンクをコピーへ強制的に退避できる。

set -uo pipefail

# 物理パスで解決する。シンボリックリンク経由で呼ばれたときに綴りの違う
# パスが登録され、実パス経由の再実行で二重登録になるのを防ぐ。
CTS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET="$(cd "${1:-$PWD}" 2>/dev/null && pwd -P)" || {
  printf 'エラー: 導入先ディレクトリが見つからない: %s\n' "${1:-$PWD}" >&2
  exit 1
}

SETTINGS="$TARGET/.claude/settings.local.json"
BACKUP="$SETTINGS.cts-backup"
GITIGNORE="$TARGET/.gitignore"

# ここまでに適用した作業。途中で失敗したときに、何が残っているかを伝える。
applied=()
warnings=()
backup_path=""

die() {
  printf 'エラー: %s\n' "$*" >&2
  if [ "${#applied[@]}" -gt 0 ]; then
    printf 'ここまで適用した:\n' >&2
    printf '  - %s\n' "${applied[@]}" >&2
    printf '復旧するには uninstall.sh を実行せよ: %s/uninstall.sh %s\n' "$CTS_HOME" "$TARGET" >&2
  fi
  exit 1
}
info() { printf '%s\n' "$*"; }
warn() {
  warnings+=("$*")
  printf '  警告: %s\n' "$*"
}

command -v python3 >/dev/null 2>&1 ||
  die "python3 が必要である（settings.local.json を壊さずに編集するため）。フック自体は python3 に依存しない。"

info "claude-token-saver を導入する: $TARGET"

# --- 1. ディレクトリ ---------------------------------------------------------

mkdir -p "$TARGET/.claude/.handoff/pending" \
         "$TARGET/.claude/.handoff/consumed" \
         "$TARGET/.claude/.token-saver" ||
  die "ディレクトリを作成できない"
applied+=(".claude 配下のディレクトリを作成")

# --- 2. フックの登録 ---------------------------------------------------------

# 実体のあるスクリプトだけを登録する。存在しないコマンドを登録すると、
# 導入先のセッションでフックが毎回失敗する。
hook_specs=()
[ -f "$CTS_HOME/scripts/handoff-check.sh" ] &&
  hook_specs+=("SessionStart:$CTS_HOME/scripts/handoff-check.sh")
[ -f "$CTS_HOME/scripts/suggest-session-cut.sh" ] &&
  hook_specs+=("Stop:$CTS_HOME/scripts/suggest-session-cut.sh")

if [ "${#hook_specs[@]}" -gt 0 ]; then
  # settings.local.json は通常 git 管理外の個人設定である。git から復元でき
  # ないので、最初の書き換え前に控えを取る。既にあれば上書きしない（原状の
  # 控えを、再実行で自分の書いた内容へ塗り替えては意味がない）。
  if [ -f "$SETTINGS" ] && [ ! -e "$BACKUP" ]; then
    cp -p "$SETTINGS" "$BACKUP" || die "settings.local.json の控えを作れない"
    backup_path="$BACKUP"
  fi

  python3 "$CTS_HOME/lib/settings-hooks.py" install "$SETTINGS" "${hook_specs[@]}" ||
    die "settings.local.json を更新できない"
  applied+=("settings.local.json へフックを登録")
fi

# --- 3. スキルのリンク -------------------------------------------------------

# 実体はクローン先に1つだけ置く。複数プロジェクトへ導入しても更新は git pull 1回で全体へ届く。
mkdir -p "$TARGET/.claude/skills" || die "skills ディレクトリを作成できない"

# 実際に設置したスキルだけを .gitignore へ書くため、名前を集める。
installed_skills=()

for skill_dir in "$CTS_HOME"/skills/*/; do
  [ -d "$skill_dir" ] || continue
  name="$(basename "$skill_dir")"
  dest="$TARGET/.claude/skills/$name"
  src="${skill_dir%/}"

  # 既に正しくリンクされているなら何もしない。
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    installed_skills+=("$name")
    continue
  fi

  # 実ディレクトリがあり、それが install.sh のコピーでないなら触らない。
  # 導入先が自前で置いたスキルを上書きすると、他人の作業を消す。
  if [ -d "$dest" ] && [ ! -L "$dest" ] && [ ! -f "$dest/.claude-token-saver" ]; then
    warn "スキル $name は導入先に既存のディレクトリがあるため触らない（.gitignore にも書かない）"
    continue
  fi

  rm -rf "$dest"
  if [ -z "${CTS_NO_SYMLINK:-}" ] && ln -s "$src" "$dest" 2>/dev/null; then
    info "  スキルをリンクした: $name"
  else
    cp -R "$src" "$dest" || die "スキル $name を配置できない"
    # コピーであることを記録する。次回の install.sh が更新してよいと判断できるようにする。
    printf 'claude-token-saver が配置したコピー。手で編集しない。\n' >"$dest/.claude-token-saver"
    info "  スキルをコピーで配置した（シンボリックリンクが使えない環境）: $name"
    info "    リポジトリを更新したら install.sh を再実行してコピーを更新せよ。"
  fi
  installed_skills+=("$name")
  applied+=("スキル $name を設置")
done

# --- 4. .gitignore -----------------------------------------------------------

# 引き継ぎと状態ファイルは利用実績であり、既定では版管理しない。
# スキルのリンクは絶対パスを指す環境依存の産物であり、版管理へ入れると
# 他の開発者のクローンで壊れたリンクになる。
#
# ブロックは毎回作り直す。存在確認だけで済ませると、スキルが増えたときに
# 無視行が追加されず、リンクが版管理対象として現れる。
# 無視行を書くのは実際に設置したスキルだけに限る。触らなかったスキル
# （導入先が自前で持っているもの）を無視すると、その版管理を静かに壊す。
{
  printf '.claude/.handoff/\n'
  printf '.claude/.token-saver/\n'
  for name in ${installed_skills[@]+"${installed_skills[@]}"}; do
    printf '.claude/skills/%s\n' "$name"
  done
} | python3 "$CTS_HOME/lib/gitignore-block.py" apply "$GITIGNORE"
gitignore_status=$?
case "$gitignore_status" in
  0) applied+=(".gitignore を更新") ;;
  2) warnings+=(".gitignore の claude-token-saver ブロックが壊れているため更新していない") ;;
  *) die ".gitignore を更新できない" ;;
esac

# --- 5. まとめ ---------------------------------------------------------------

[ -n "$backup_path" ] && info "  既存の settings.local.json の控え: $backup_path"

if [ "${#warnings[@]}" -gt 0 ]; then
  info ""
  info "警告 ${#warnings[@]} 件（未適用の項目がある）:"
  printf '  - %s\n' "${warnings[@]}"
  info "内容を確認せよ。取り消すには uninstall.sh を実行する。"
else
  info "完了。新しいセッションを開始すると引き継ぎフックが有効になる。"
fi
