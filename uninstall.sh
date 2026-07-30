#!/usr/bin/env bash
# install.sh を取り消す。
#
#   cd <導入先リポジトリ> && /path/to/claude-token-saver/uninstall.sh
#   uninstall.sh <導入先ディレクトリ>
#
# .claude/.handoff/ 配下の実ファイルは消さない。引き継ぎは作業の記録であり、
# アンインストールで失われてよいものではない。

set -uo pipefail

CTS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(cd "${1:-$PWD}" 2>/dev/null && pwd)" || {
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
if [ -f "$SETTINGS" ]; then
  python3 - "$SETTINGS" handoff-check.sh suggest-session-cut.sh <<'PY' || die "settings.local.json を更新できない"
import json, os, sys, tempfile

settings_path, basenames = sys.argv[1], set(sys.argv[2:])

try:
    with open(settings_path, encoding="utf-8") as f:
        text = f.read().strip()
    data = json.loads(text) if text else {}
except (json.JSONDecodeError, UnicodeDecodeError) as e:
    sys.stderr.write(
        "既存の %s が妥当な JSON でない (%s)。設定は変更していない。\n" % (settings_path, e)
    )
    sys.exit(1)

if not isinstance(data, dict) or not isinstance(data.get("hooks"), dict):
    print("  登録済みのフックは無い")
    sys.exit(0)

def is_ours(hook):
    return isinstance(hook, dict) and os.path.basename(str(hook.get("command", ""))) in basenames

removed = 0
hooks = data["hooks"]
for event in list(hooks):
    groups = hooks.get(event)
    if not isinstance(groups, list):
        continue

    kept_groups = []
    for group in groups:
        if not isinstance(group, dict):
            kept_groups.append(group)
            continue
        inner = group.get("hooks")
        if not isinstance(inner, list):
            kept_groups.append(group)
            continue
        kept = [h for h in inner if not is_ours(h)]
        removed += len(inner) - len(kept)
        # 中身が空になったグループは、install.sh が作ったものなので落とす。
        if kept:
            group["hooks"] = kept
            kept_groups.append(group)

    if kept_groups:
        hooks[event] = kept_groups
    else:
        del hooks[event]

if not hooks:
    del data["hooks"]

d = os.path.dirname(settings_path)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings-", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, settings_path)
except Exception:
    os.path.exists(tmp) and os.unlink(tmp)
    raise

print("  フックの登録を %d 件外した" % removed)
PY
else
  info "  settings.local.json が無い"
fi

# --- 2. .gitignore -----------------------------------------------------------

if [ -f "$GITIGNORE" ]; then
  python3 - "$GITIGNORE" <<'PY' || die ".gitignore を更新できない"
import os, sys, tempfile

path = sys.argv[1]
START, END = "# claude-token-saver", "# claude-token-saver end"

with open(path, encoding="utf-8") as f:
    lines = f.read().splitlines()

out, skipping, removed = [], False, 0
for line in lines:
    s = line.strip()
    if not skipping and s.startswith(START) and not s.startswith(END):
        skipping = True
        removed += 1
        continue
    if skipping:
        removed += 1
        if s.startswith(END):
            skipping = False
        continue
    out.append(line)

if removed == 0:
    print("  .gitignore に追記は無い")
    sys.exit(0)

# ブロックの直前に install.sh が入れた空行が残るので落とす。
while out and out[-1].strip() == "":
    out.pop()

d = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".gitignore-", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        if out:
            f.write("\n".join(out) + "\n")
    os.replace(tmp, path)
except Exception:
    os.path.exists(tmp) and os.unlink(tmp)
    raise

print("  .gitignore の追記を削除した")
PY
fi

# --- 3. スキル ---------------------------------------------------------------

for skill_dir in "$CTS_HOME"/skills/*/; do
  [ -d "$skill_dir" ] || continue
  name="$(basename "$skill_dir")"
  dest="$TARGET/.claude/skills/$name"

  if [ -L "$dest" ]; then
    rm -f "$dest"
    info "  スキルのリンクを外した: $name"
  elif [ -d "$dest" ] && [ -f "$dest/.claude-token-saver" ]; then
    rm -rf "$dest"
    info "  スキルのコピーを削除した: $name"
  elif [ -e "$dest" ]; then
    # 導入先が自前で置いたものは触らない。
    info "  スキル $name は導入先のものなので残す"
  fi
done

# 空になった skills ディレクトリは片付ける。中身があるなら触らない。
rmdir "$TARGET/.claude/skills" 2>/dev/null || true

# --- 4. 残したものの通知 -----------------------------------------------------

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

info "完了。"
