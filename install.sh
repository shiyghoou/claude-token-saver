#!/usr/bin/env bash
# claude-token-saver を導入先リポジトリへインストールする。
#
#   cd <導入先リポジトリ> && /path/to/claude-token-saver/install.sh
#   install.sh <導入先ディレクトリ>
#
# 冪等である。二度実行しても設定は重複しない。
# 環境変数 CTS_NO_SYMLINK=1 でスキルのリンクをコピーへ強制的に退避できる。

set -uo pipefail

CTS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(cd "${1:-$PWD}" 2>/dev/null && pwd)" || {
  printf 'エラー: 導入先ディレクトリが見つからない: %s\n' "${1:-$PWD}" >&2
  exit 1
}

SETTINGS="$TARGET/.claude/settings.local.json"
GITIGNORE="$TARGET/.gitignore"
GITIGNORE_MARKER="# claude-token-saver"

die() { printf 'エラー: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

command -v python3 >/dev/null 2>&1 ||
  die "python3 が必要である（settings.local.json を壊さずに編集するため）。フック自体は python3 に依存しない。"

info "claude-token-saver を導入する: $TARGET"

# --- 1. ディレクトリ ---------------------------------------------------------

mkdir -p "$TARGET/.claude/.handoff/pending" \
         "$TARGET/.claude/.handoff/consumed" \
         "$TARGET/.claude/.token-saver" ||
  die "ディレクトリを作成できない"

# --- 2. フックの登録 ---------------------------------------------------------

# 実体のあるスクリプトだけを登録する。存在しないコマンドを登録すると、
# 導入先のセッションでフックが毎回失敗する。
hook_specs=()
[ -f "$CTS_HOME/scripts/handoff-check.sh" ] &&
  hook_specs+=("SessionStart:$CTS_HOME/scripts/handoff-check.sh")
[ -f "$CTS_HOME/scripts/suggest-session-cut.sh" ] &&
  hook_specs+=("Stop:$CTS_HOME/scripts/suggest-session-cut.sh")

if [ "${#hook_specs[@]}" -gt 0 ]; then
  python3 - "$SETTINGS" "${hook_specs[@]}" <<'PY' || die "settings.local.json を更新できない"
import json, os, sys, tempfile

settings_path, specs = sys.argv[1], sys.argv[2:]

data = {}
if os.path.exists(settings_path):
    try:
        with open(settings_path, encoding="utf-8") as f:
            text = f.read().strip()
        data = json.loads(text) if text else {}
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        # 壊れたファイルを上書きすると、ユーザーの既存設定を失う。何もせず落ちる。
        sys.stderr.write(
            "既存の %s が妥当な JSON でない (%s)。\n"
            "手で直してから install.sh を再実行せよ。設定は変更していない。\n"
            % (settings_path, e)
        )
        sys.exit(1)
    if not isinstance(data, dict):
        sys.stderr.write("既存の %s の最上位がオブジェクトでない。設定は変更していない。\n" % settings_path)
        sys.exit(1)

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    sys.stderr.write("既存の %s の hooks がオブジェクトでない。設定は変更していない。\n" % settings_path)
    sys.exit(1)

added = []
for spec in specs:
    event, command = spec.split(":", 1)
    groups = hooks.setdefault(event, [])

    # 同じコマンドが既にあれば何もしない（冪等性）。
    already = any(
        h.get("command") == command
        for g in groups if isinstance(g, dict)
        for h in g.get("hooks", []) if isinstance(h, dict)
    )
    if already:
        continue

    groups.append({"hooks": [{"type": "command", "command": command}]})
    added.append("%s → %s" % (event, os.path.basename(command)))

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(settings_path), prefix=".settings-", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, settings_path)
except Exception:
    os.path.exists(tmp) and os.unlink(tmp)
    raise

for line in added:
    print("  フックを登録した: %s" % line)
if not added:
    print("  フックは既に登録済み")
PY
fi

# --- 3. .gitignore -----------------------------------------------------------

# 引き継ぎと状態ファイルは利用実績であり、既定では版管理しない。
# スキルのリンクは絶対パスを指す環境依存の産物であり、版管理へ入れると
# 他の開発者のクローンで壊れたリンクになる。
if ! grep -qF "$GITIGNORE_MARKER" "$GITIGNORE" 2>/dev/null; then
  {
    if [ -s "$GITIGNORE" ]; then
      # 末尾に改行が無ければ足す。無いまま追記すると行が結合する。
      [ -n "$(tail -c 1 "$GITIGNORE" 2>/dev/null)" ] && printf '\n'
      printf '\n'
    fi
    printf '%s (install.sh が追記。uninstall.sh で削除される)\n' "$GITIGNORE_MARKER"
    printf '.claude/.handoff/\n'
    printf '.claude/.token-saver/\n'
    for skill_dir in "$CTS_HOME"/skills/*/; do
      [ -d "$skill_dir" ] && printf '.claude/skills/%s\n' "$(basename "$skill_dir")"
    done
    printf '%s end\n' "$GITIGNORE_MARKER"
  } >>"$GITIGNORE" || die ".gitignore へ追記できない"
  info "  .gitignore へ追記した"
else
  info "  .gitignore は既に追記済み"
fi

# --- 4. スキルのリンク -------------------------------------------------------

# 実体はクローン先に1つだけ置く。複数プロジェクトへ導入しても更新は git pull 1回で全体へ届く。
mkdir -p "$TARGET/.claude/skills" || die "skills ディレクトリを作成できない"

for skill_dir in "$CTS_HOME"/skills/*/; do
  [ -d "$skill_dir" ] || continue
  name="$(basename "$skill_dir")"
  dest="$TARGET/.claude/skills/$name"
  src="${skill_dir%/}"

  # 既に正しくリンクされているなら何もしない。
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    continue
  fi

  # 実ディレクトリがあり、それが install.sh のコピーでないなら触らない。
  # 導入先が自前で置いたスキルを上書きすると、他人の作業を消す。
  if [ -d "$dest" ] && [ ! -L "$dest" ] && [ ! -f "$dest/.claude-token-saver" ]; then
    info "  スキル $name は導入先に既存のディレクトリがあるため触らない"
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
done

info "完了。新しいセッションを開始すると引き継ぎフックが有効になる。"
