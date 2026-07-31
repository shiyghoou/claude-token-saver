#!/usr/bin/env python3
# .gitignore の claude-token-saver ブロックを読み書きする。
#
#   gitignore-block.py apply  <path>   # 本文を標準入力から受け取り、無ければ追記・あれば差し替え
#   gitignore-block.py remove <path>   # ブロックを削除する
#
# 終了コード: 0=変更した / 2=警告（何も変更していない） / 3=変更不要
#
# install.sh と uninstall.sh の双方がこれを呼ぶ。ブロックの境界判定を2箇所に
# 書くと、片方だけが綴りを変えたときに「END が見つからず EOF まで削除」という
# 破壊的な取り違えが起きる。判定はここ1箇所に閉じる。

import os
import sys

# 導入先から呼ばれる道具である。クローンに __pycache__ を書き散らさない。
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger  # noqa: E402  (write_atomic を共有する)

START = "# claude-token-saver (install.sh が追記。uninstall.sh で削除される)"
END = "# claude-token-saver end"

EXIT_OK = 0
EXIT_WARN = 2
EXIT_UNCHANGED = 3


def find_blocks(lines):
    """START と END の対が揃っている区間 (start, end) をすべて返す。

    1つ目で打ち切らない。別クローンからの旧 install やマージ衝突の両採用で
    ブロックが2つになることがあり、1つしか見ないと片方が永久に残る。
    残ったブロックは対が揃っているため警告にも引っかからない。

    前方一致ではなく完全一致で判定する。前方一致にすると、利用者が書いた
    「# claude-token-saver は便利」のような1行を START と誤認し、そこから
    EOF までを削除してしまう。
    """
    spans = []
    start = None
    for i, line in enumerate(lines):
        s = line.strip()
        if s == END and start is not None:
            spans.append((start, i))
            start = None
        elif s == START and start is None:
            start = i
    return spans


def stray_markers(lines, spans):
    """対になっていないマーカーの (行番号, 行) を返す。行番号は1始まり。

    区間の内側に現れた START も対になっていない。START が2つ・END が1つの
    形（マージ衝突の両採用で容易に生じる）では find_blocks が外側の START から
    END までを1区間と数えるため、内側の START とその上にある利用者の行が
    区間へ飲み込まれる。START 1つ・END 2つは警告するのに、こちらを黙って
    消すのは非対称であり、消される側のほうが害が大きい。
    """
    owner = {}
    for span in spans:
        for i in range(span[0], span[1] + 1):
            owner[i] = span

    strays = []
    for i, line in enumerate(lines):
        s = line.strip()
        if s not in (START, END):
            continue
        span = owner.get(i)
        if span is None:
            strays.append((i + 1, s))
        elif s == START and i != span[0]:
            strays.append((i + 1, s))
    return strays


def warn_unpaired(path, strays, action):
    sys.stderr.write(
        "  警告: %s の claude-token-saver ブロックが START/END の対になっていない。\n" % path
    )
    for lineno, text in strays:
        sys.stderr.write("        %d 行目: %s\n" % (lineno, text))
    sys.stderr.write(
        "        %s。手で直せ。対にすべき2行は次のとおり:\n"
        "          START: %s\n"
        "          END:   %s\n" % (action, START, END)
    )


def read_text(path):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return f.read()


def render(lines):
    return "\n".join(lines) + "\n" if lines else ""


def cmd_apply(path):
    original = read_text(path)
    lines = (original or "").splitlines()
    body = sys.stdin.read().splitlines()
    block = [START] + body + [END]

    spans = find_blocks(lines)
    strays = stray_markers(lines, spans)
    if strays:
        warn_unpaired(path, strays, "取り違えて削除しないよう、.gitignore は変更しない")
        return EXIT_WARN

    if spans:
        # 中身は毎回作り直す。存在確認だけで済ませると、スキルが増えたときや
        # 出力先が増えたときに追記が永久に反映されない。
        # 先頭のブロックを差し替え、残りは削除して1つに畳む。
        out = lines[: spans[0][0]] + block + lines[spans[0][1] + 1 :]
        offset = len(block) - (spans[0][1] - spans[0][0] + 1)
        for start, end in reversed(spans[1:]):
            del out[start + offset : end + offset + 1]
            # 畳んだ跡に、区切りとして入っていた空行1行だけを取り除く。
            if start + offset > 0 and out[start + offset - 1].strip() == "":
                del out[start + offset - 1]
        verb = "更新した"
    else:
        out = list(lines)
        # 既存の行と1行空けて区切る。末尾の空行を一律に潰すと、利用者が
        # 意図して空けた行が失われ、remove しても元へ戻らない。
        # 区切りの空行はここで必ず1行だけ足し、remove がその1行だけを外す。
        if out:
            out.append("")
        out += block
        verb = "追記した"

    new_text = render(out)
    if new_text == original:
        print("  .gitignore は最新である")
        return EXIT_UNCHANGED

    ledger.write_atomic(path, new_text)
    print("  .gitignore へ%s" % verb)
    return EXIT_OK


def cmd_remove(path):
    original = read_text(path)
    if original is None:
        return EXIT_OK
    lines = original.splitlines()

    spans = find_blocks(lines)
    strays = stray_markers(lines, spans)
    if strays:
        warn_unpaired(path, strays, "巻き込んで削除しないよう、何も削除しない")
        return EXIT_WARN
    if not spans:
        print("  .gitignore に追記は無い")
        return EXIT_OK

    out = list(lines)
    # 後ろから消す。前から消すと以降の行番号がずれる。
    for start, end in reversed(spans):
        del out[start : end + 1]
        # install.sh が区切りに入れた空行1行だけを、消した位置の直前から取り除く。
        # 末尾の空行を一律に削ると、ブロックと無関係な空行まで失われる。
        if start > 0 and out[start - 1].strip() == "":
            del out[start - 1]

    ledger.write_atomic(path, render(out))
    print("  .gitignore の追記を削除した")
    return EXIT_OK


def main(argv):
    if len(argv) != 3 or argv[1] not in ("apply", "remove"):
        sys.stderr.write("usage: gitignore-block.py {apply|remove} <path>\n")
        return 64
    return cmd_apply(argv[2]) if argv[1] == "apply" else cmd_remove(argv[2])


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except OSError as e:
        # 書き込めない環境で python のトレースバックを生で見せない。
        sys.stderr.write("  .gitignore を操作できない (%s)\n" % e)
        sys.exit(1)
