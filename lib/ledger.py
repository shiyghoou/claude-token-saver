#!/usr/bin/env python3
# 「導入先に何を設置したか」の台帳を読み書きする。
#
#   ledger.py add-skill  <ledger> <name> <src> <link|copy>
#   ledger.py get-skill  <ledger> <name>          # "src<TAB>mode" を1行、無ければ何も出さない
#   ledger.py list-skills <ledger>                # "name<TAB>src<TAB>mode" を行ごと
#   ledger.py set-flag   <ledger> <name> <0|1>
#   ledger.py get-flag   <ledger> <name>          # 0 か 1 を出す
#
# 台帳が無いと uninstall.sh は「自分が置いたもの」を推測するしかなく、
# 利用者が自分で張った同名のリンクまで巻き込んで消してしまう。設置した側が
# 記録を残し、取り外す側はそれを正とする。
#
# 記録するもの:
#   skills            設置したスキル（名前・リンク先・リンクかコピーか）
#   hooks             settings.local.json へ登録したコマンド文字列そのもの
#   gitignore_created install.sh が .gitignore を新規作成したか
#
# 台帳自身は .claude/.token-saver/ に置く。既に .gitignore の対象である。

import json
import os
import sys
import tempfile


def write_atomic(path, text, mode=None):
    """一時ファイル経由で書き換える。パーミッションは元のファイルを引き継ぐ。

    mkstemp は 0600 で作るため、そのまま os.replace すると追跡ファイルの
    パーミッションを 0600 へ落としてしまう（共有ワークツリーや CI で読めなくなる）。
    元が無いときは umask を尊重した既定値にする。

    hyphen を含むスクリプト名（gitignore-block.py など）は import できないため、
    共有する小道具はこのモジュールに置く。
    """
    if mode is None:
        try:
            mode = os.stat(path).st_mode & 0o7777
        except OSError:
            umask = os.umask(0)
            os.umask(umask)
            mode = 0o666 & ~umask

    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".cts-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def load(path):
    """台帳を読む。無い・壊れている場合は空として扱う。

    台帳が壊れていても導入や取り外しは進められねばならない（推測へ落ちるだけである）。
    """
    try:
        with open(path, encoding="utf-8") as f:
            data = json.loads(f.read() or "{}")
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save(path, data):
    write_atomic(path, json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def get_list(data, key):
    value = data.get(key)
    return value if isinstance(value, list) else []


def cmd_add_skill(path, name, src, mode):
    data = load(path)
    skills = [
        s
        for s in get_list(data, "skills")
        if not (isinstance(s, dict) and s.get("name") == name)
    ]
    skills.append({"name": name, "src": src, "mode": mode})
    data["skills"] = skills
    save(path, data)
    return 0


def cmd_get_skill(path, name):
    for s in get_list(load(path), "skills"):
        if isinstance(s, dict) and s.get("name") == name:
            print("%s\t%s" % (s.get("src", ""), s.get("mode", "")))
            return 0
    return 0


def cmd_list_skills(path):
    for s in get_list(load(path), "skills"):
        if isinstance(s, dict) and s.get("name"):
            print("%s\t%s\t%s" % (s["name"], s.get("src", ""), s.get("mode", "")))
    return 0


def cmd_set_flag(path, name, value):
    data = load(path)
    data[name] = value not in ("0", "", "false")
    save(path, data)
    return 0


def cmd_get_flag(path, name):
    print("1" if load(path).get(name) else "0")
    return 0


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: ledger.py <command> <ledger> [args...]\n")
        return 64
    cmd, path, rest = argv[1], argv[2], argv[3:]
    try:
        if cmd == "add-skill" and len(rest) == 3:
            return cmd_add_skill(path, *rest)
        if cmd == "get-skill" and len(rest) == 1:
            return cmd_get_skill(path, rest[0])
        if cmd == "list-skills" and not rest:
            return cmd_list_skills(path)
        if cmd == "set-flag" and len(rest) == 2:
            return cmd_set_flag(path, *rest)
        if cmd == "get-flag" and len(rest) == 1:
            return cmd_get_flag(path, rest[0])
    except OSError as e:
        sys.stderr.write("台帳を書けない (%s): %s\n" % (path, e))
        return 1
    sys.stderr.write("usage: ledger.py <command> <ledger> [args...]\n")
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
