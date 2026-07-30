#!/usr/bin/env python3
# .gitignore の claude-token-saver ブロックを読み書きする。
#
#   gitignore-block.py apply  <path>   # 本文を標準入力から受け取り、無ければ追記・あれば差し替え
#   gitignore-block.py remove <path>   # ブロックを削除する
#
# install.sh と uninstall.sh の双方がこれを呼ぶ。ブロックの境界判定を2箇所に
# 書くと、片方だけが綴りを変えたときに「END が見つからず EOF まで削除」という
# 破壊的な取り違えが起きる。判定はここ1箇所に閉じる。

import os
import sys
import tempfile

START = "# claude-token-saver (install.sh が追記。uninstall.sh で削除される)"
END = "# claude-token-saver end"


def find_block(lines):
    """START と END の対が揃っている区間 (start, end) を返す。揃わなければ None。

    前方一致ではなく完全一致で判定する。前方一致にすると、利用者が書いた
    「# claude-token-saver は便利」のような1行を START と誤認し、そこから
    EOF までを削除してしまう。
    """
    start = None
    for i, line in enumerate(lines):
        s = line.strip()
        if s == END and start is not None:
            return (start, i)
        if s == START and start is None:
            start = i
    return None


def has_marker(lines):
    return any(line.strip() in (START, END) for line in lines)


def read_text(path):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return f.read()


def write_atomic(path, text):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".gitignore-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def render(lines):
    return "\n".join(lines) + "\n" if lines else ""


def cmd_apply(path):
    original = read_text(path)
    lines = (original or "").splitlines()
    body = sys.stdin.read().splitlines()
    block = [START] + body + [END]

    span = find_block(lines)
    if span is not None:
        # 中身は毎回作り直す。存在確認だけで済ませると、スキルが増えたときや
        # 出力先が増えたときに追記が永久に反映されない。
        out = lines[: span[0]] + block + lines[span[1] + 1 :]
        verb = "更新した"
    elif has_marker(lines):
        sys.stderr.write(
            "  警告: %s の claude-token-saver ブロックが START/END の対になっていない。\n"
            "        取り違えて削除しないよう、.gitignore は変更しない。手で直せ。\n" % path
        )
        return 2
    else:
        out = list(lines)
        # 既存の行と1行だけ空けて区切る。末尾の空行の数は元の状態に依らず揃える。
        while out and out[-1].strip() == "":
            out.pop()
        if out:
            out.append("")
        out += block
        verb = "追記した"

    new_text = render(out)
    if new_text == original:
        print("  .gitignore は最新である")
        return 0

    write_atomic(path, new_text)
    print("  .gitignore へ%s" % verb)
    return 0


def cmd_remove(path):
    original = read_text(path)
    if original is None:
        return 0
    lines = original.splitlines()

    span = find_block(lines)
    if span is None:
        if has_marker(lines):
            sys.stderr.write(
                "  警告: %s の claude-token-saver ブロックが START/END の対になっていない。\n"
                "        巻き込んで削除しないよう、何も削除しない。手で直せ。\n" % path
            )
        else:
            print("  .gitignore に追記は無い")
        return 0

    start, end = span
    out = lines[:start] + lines[end + 1 :]
    # install.sh が区切りに入れた空行1行だけを、消した位置の直前から取り除く。
    # 末尾の空行を一律に削ると、ブロックと無関係な空行まで失われる。
    if start > 0 and out[start - 1].strip() == "":
        del out[start - 1]

    write_atomic(path, render(out))
    print("  .gitignore の追記を削除した")
    return 0


def main(argv):
    if len(argv) != 3 or argv[1] not in ("apply", "remove"):
        sys.stderr.write("usage: gitignore-block.py {apply|remove} <path>\n")
        return 64
    return cmd_apply(argv[2]) if argv[1] == "apply" else cmd_remove(argv[2])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
