#!/usr/bin/env python3
# 「導入先に何を設置したか」の台帳を読み書きする。
#
#   ledger.py add-skill  <ledger> <name> <src> <link|copy>
#   ledger.py get-skill  <ledger> <name>          # "src<US>mode" を1行、無ければ何も出さない
#   ledger.py list-skills <ledger>                # "name<US>src<US>mode" を行ごと
#                                                 # <US> は 0x1f。理由は FS の定義を見よ。
#   ledger.py set-flag   <ledger> <name> <0|1>
#   ledger.py get-flag   <ledger> <name>          # 0 か 1 を出す
#   ledger.py check-writable <path>               # atomic write 前の安全確認
#   ledger.py has-record <ledger> <skills|hooks|any>   # 記録が在れば 0、無ければ 1
#
# 台帳が無いと uninstall.sh は「自分が置いたもの」を推測するしかなく、
# 利用者が自分で張った同名のリンクまで巻き込んで消してしまう。設置した側が
# 記録を残し、取り外す側はそれを正とする。
#
# 「台帳ファイルが在る」と「台帳に記録が在る」は別である。壊れた台帳や
# 記録の無い台帳を「在る」と数えると、uninstall は記録ゼロを「設置物ゼロ」と
# 取り違えて取り残す。has-record はその区別のためにある。
#
# 記録するもの:
#   skills            設置したスキル（名前・リンク先・リンクかコピーか）
#   hooks             settings.local.json へ登録したコマンド文字列そのもの
#   gitignore_created install.sh が .gitignore を新規作成したか
#
# 台帳自身の置き場所は install.sh が決める（scripts/lib/paths.sh を正とする）。
# .gitignore の対象であり、版管理へは入らない。

import json
import errno
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
    if os.path.islink(path):
        raise OSError(errno.ELOOP, "シンボリックリンクを置き換えない", path)

    if mode is None:
        try:
            stat_result = os.stat(path)
            if stat_result.st_mode & 0o222 == 0:
                raise PermissionError(errno.EACCES, "書き込み権限が無い", path)
            mode = stat_result.st_mode & 0o7777
        except FileNotFoundError:
            umask = os.umask(0)
            os.umask(umask)
            mode = 0o666 & ~umask

    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".cts-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def load(path):
    """台帳を読む。無い・壊れている場合は空として扱う。

    ここで落ちないのは、install を進められねばならないからである。
    「読めなかった」を「記録が無い」と取り違えないための判定は has_record が持つ。
    uninstall は has_record が偽なら何もしない（推測へ落ちない）。
    """
    try:
        with open(path, encoding="utf-8-sig", errors="surrogateescape", newline="") as f:
            data = json.loads(f.read() or "{}")
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save(path, data):
    write_atomic(path, json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def check_writable(path):
    """atomic write 前に対象と既存の親ディレクトリを書き込めるか確認する。"""
    if os.path.islink(path):
        raise OSError(errno.ELOOP, "シンボリックリンクを置き換えない", path)
    if os.path.lexists(path):
        if os.stat(path).st_mode & 0o222 == 0:
            raise PermissionError(errno.EACCES, "書き込み権限が無い", path)

    parent = os.path.abspath(os.path.dirname(path) or ".")
    while not os.path.lexists(parent):
        next_parent = os.path.dirname(parent)
        if next_parent == parent:
            break
        parent = next_parent
    if os.path.islink(parent):
        raise OSError(errno.ELOOP, "親ディレクトリのシンボリックリンクを辿らない", parent)
    if os.stat(parent).st_mode & 0o222 == 0:
        raise PermissionError(errno.EACCES, "親ディレクトリに書き込み権限が無い", parent)


def get_list(data, key):
    value = data.get(key)
    return value if isinstance(value, list) else []


def has_record(path, kind):
    """台帳が有効に読めて、その種類の記録を持つかを返す。

    「ファイルが在る」ではなく「記録が在る」を答える。install が hooks を
    1つも登録しなかった場合（クローンが不完全など）は hooks キー自体が
    作られないため、キーの有無で「記録したか」を判別できる。
    空のリストは「登録すべきものが無かった」という記録であり、記録は在る。
    """
    data = load(path)
    if not data:
        return False
    if kind == "skills":
        return isinstance(data.get("skills"), list)
    if kind == "hooks":
        return isinstance(data.get("hooks"), list)
    # any: 認識できるキーが1つでも在れば、この導入先へ install した記録である。
    return (
        isinstance(data.get("skills"), list)
        or isinstance(data.get("hooks"), list)
        or "gitignore_created" in data
    )


# 行プロトコルの区切り。フィールドは US(0x1f)、レコードは改行で区切る。
#
# tab で区切ってはならない。tab は IFS の空白文字であるため、読む側の
# `IFS=$'\t' read` が連続する区切りを1つに畳み、空フィールドが表現できない。
# 空の src が「次のフィールドの値」へ化けると、記録の欠損が黙って別の値として
# 読まれる。US は空白文字でないので畳まれず、空フィールドがそのまま残る。
FS = "\x1f"


def line_safe_name(name):
    """行プロトコルに載せられる名前かを返す。

    JSON は表現できるのに行プロトコルは表現できない、という構造的な不整合を
    ここで閉じる。区切りに使う文字（US・改行・CR・tab）を含む名前は、行や
    フィールドの境界そのものを壊し、別名のスキルを対象にしたり .gitignore へ
    2行生成したりできる。スキルのディレクトリ名としては在り得ない文字なので、
    弾いて失うものが無い。
    """
    if not isinstance(name, str) or not name:
        return False
    return not (set("\t\n\r" + FS) & set(name))


def path_safe_name(name):
    """パスへ連結しても導入先の外へ出ない名前かを返す。

    台帳の name はそのまま .claude/skills/<name> へ連結される。.. を通せば
    導入先の外のリンクを削除できてしまう。
    書くときに弾く。読むときの防御は uninstall.sh 側に置く（パスを組み立てる
    のは向こうであり、組み立てる場所で検べるのが筋である）。
    """
    return isinstance(name, str) and name not in ("", ".", "..") and "/" not in name


def cmd_add_skill(path, name, src, mode):
    if not line_safe_name(name) or not path_safe_name(name):
        sys.stderr.write("スキル名が台帳に載せられない: %r\n" % (name,))
        return 1
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
            print(FS.join([line_safe(s.get("src", "")), line_safe(s.get("mode", ""))]))
            return 0
    return 0


def line_safe(value):
    """行プロトコルに載せられない文字を落とす。

    src は導入元のパスであり、名前と違って弾くと導入自体ができなくなる。
    改行や区切り文字を含むパスは実在しうるが、それを行プロトコルへ素通しすると
    読む側が別のフィールドとして解釈する。落として不一致にするほうが安全
    である（不一致なら uninstall は「差し替えられている」と判断して残す）。
    """
    text = str(value)
    for ch in ("\t", "\n", "\r", FS):
        text = text.replace(ch, " ")
    return text


def cmd_list_skills(path):
    for s in get_list(load(path), "skills"):
        if not isinstance(s, dict):
            continue
        name = s.get("name")
        # 手で書き換えられた台帳を信用しない。行プロトコルで表現できない名前は
        # 読む側へ渡すこと自体ができない（渡すと境界が壊れる）ので落とす。
        # パスとして危ない名前（.. など）はそのまま渡し、パスを組み立てる
        # uninstall.sh 側で弾く。ここで両方やると、どちらの層が効いているのか
        # 検証できなくなる。
        if not line_safe_name(name):
            if name:
                sys.stderr.write("台帳のスキル名が行プロトコルに載せられないので無視する: %r\n" % (name,))
            continue
        print(FS.join([name, line_safe(s.get("src", "")), line_safe(s.get("mode", ""))]))
    return 0


def cmd_has_record(path, kind):
    return 0 if has_record(path, kind) else 1


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
        if cmd == "check-writable" and not rest:
            check_writable(path)
            return 0
        if cmd == "has-record" and len(rest) == 1 and rest[0] in ("skills", "hooks", "any"):
            return cmd_has_record(path, rest[0])
    except OSError as e:
        sys.stderr.write("台帳を書けない (%s): %s\n" % (path, e))
        return 1
    sys.stderr.write("usage: ledger.py <command> <ledger> [args...]\n")
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
