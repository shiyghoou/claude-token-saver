#!/usr/bin/env python3
# settings.local.json のフック登録を書き換える。
#
#   settings-hooks.py install <path> <event>:<command> ...
#   settings-hooks.py remove  <path>
#
# install も remove も、まず「自分のフック」を全部外す。install はそのうえで
# 1件だけ入れ直す。コマンド文字列の完全一致で冪等性を取ると、シンボリック
# リンク経由と実パス経由で二重登録され、クローンを移動すれば存在しないパスを
# 指す登録が残る。ファイル名で同定して総入れ替えすれば、綴り違いも移動後の
# 残骸も同時に消える。
#
# 判定を install/uninstall で二重に実装しないため、双方がこれを呼ぶ。

import json
import os
import shlex
import sys
import tempfile

# 自分のものと同定するフックスクリプトのファイル名。
OURS = {"handoff-check.sh", "suggest-session-cut.sh"}


def hook_basename(command):
    """登録コマンドの先頭トークンのファイル名を返す。

    空白を含むパスはクォート付きで登録されるため、素の basename では
    "x.sh'" のようになって同定に失敗する。クォート済み・非クォートの
    どちらでも外せるよう、shlex で分解してから見る。
    """
    text = str(command)
    try:
        parts = shlex.split(text)
    except ValueError:
        parts = text.split()
    return os.path.basename(parts[0]) if parts else ""


def load(path):
    """(data, original_text) を返す。読めない・壊れている場合は落ちる。"""
    if not os.path.exists(path):
        return {}, None
    try:
        with open(path, encoding="utf-8") as f:
            original = f.read()
        text = original.strip()
        data = json.loads(text) if text else {}
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        # 壊れたファイルを上書きすると、利用者の既存設定を失う。何もせず落ちる。
        sys.stderr.write(
            "既存の %s が妥当な JSON でない (%s)。\n"
            "手で直してから実行せよ。設定は変更していない。\n" % (path, e)
        )
        sys.exit(1)
    if not isinstance(data, dict):
        sys.stderr.write("既存の %s の最上位がオブジェクトでない。設定は変更していない。\n" % path)
        sys.exit(1)
    if "hooks" in data and not isinstance(data["hooks"], dict):
        sys.stderr.write("既存の %s の hooks がオブジェクトでない。設定は変更していない。\n" % path)
        sys.exit(1)
    return data, original


def purge(data):
    """自分のフック登録をすべて外し、外した件数を返す。

    グループ単位ではなくフック単位で外す。matcher 付きのグループに利用者が
    自分のフックを同居させている場合、グループごと落とすとそれを巻き込む。
    """
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return 0

    removed = 0
    for event in list(hooks):
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue

        kept_groups = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept_groups.append(group)
                continue
            inner = group["hooks"]
            kept = [
                h
                for h in inner
                if not (isinstance(h, dict) and hook_basename(h.get("command", "")) in OURS)
            ]
            removed += len(inner) - len(kept)
            # 中身が空になったグループは install.sh が作ったものなので落とす。
            if kept:
                group["hooks"] = kept
                kept_groups.append(group)

        if kept_groups:
            hooks[event] = kept_groups
        else:
            del hooks[event]

    if not hooks:
        del data["hooks"]
    return removed


def save_if_changed(path, data, original):
    """内容が変わったときだけ書き戻す。毎回書くと JSON が全面再整形され、
    往復しても原状に戻らないうえ mtime が動く。"""
    new_text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    if new_text == original:
        return False
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(new_text)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return True


def cmd_install(path, specs):
    data, original = load(path)
    removed = purge(data)

    added = []
    hooks = data.setdefault("hooks", {})
    for spec in specs:
        event, command = spec.split(":", 1)
        # 空白を含むパスをそのまま入れると、シェルが単語分割して毎セッション
        # rc=127 で失敗する。クォートしてから登録する。
        quoted = shlex.quote(command)
        hooks.setdefault(event, []).append(
            {"hooks": [{"type": "command", "command": quoted}]}
        )
        added.append("%s → %s" % (event, os.path.basename(command)))

    if not save_if_changed(path, data, original):
        print("  フックは既に登録済み")
        return 0

    for line in added:
        print("  フックを登録した: %s" % line)
    stale = removed - len(added)
    if stale > 0:
        print("  古い・重複したフックの登録を %d 件整理した" % stale)
    return 0


def cmd_remove(path):
    if not os.path.exists(path):
        print("  settings.local.json が無い")
        return 0
    data, original = load(path)
    removed = purge(data)
    save_if_changed(path, data, original)
    print("  フックの登録を %d 件外した" % removed)
    return 0


def main(argv):
    if len(argv) < 3 or argv[1] not in ("install", "remove"):
        sys.stderr.write("usage: settings-hooks.py {install|remove} <path> [event:command ...]\n")
        return 64
    return cmd_install(argv[2], argv[3:]) if argv[1] == "install" else cmd_remove(argv[2])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
