#!/usr/bin/env python3
# settings.local.json のフック登録を書き換える。
#
#   settings-hooks.py install <path> --ledger <ledger> <event>:<command> ...
#   settings-hooks.py remove  <path> [--ledger <ledger>] [--guess]
#   settings-hooks.py same    <path> <other>   # 2つの設定がデータとして同値か
#
# 終了コード: 0=処理した / 1=失敗（何も変更していない） / 2=警告（何も変更していない）
#
# install も remove も、まず「自分のフック」を全部外す。install はそのうえで
# 入れ直す。コマンド文字列の完全一致だけで冪等性を取ると、シンボリックリンク
# 経由と実パス経由で二重登録され、クローンを移動すれば存在しないパスを指す
# 登録が残る。総入れ替えすれば、綴り違いも移動後の残骸も同時に消える。
#
# 「自分のもの」の同定は台帳（置き場所は scripts/lib/paths.sh が決める）を正とする。
# 台帳に記録が無いときは既定で何もしない（fail-closed）。ファイル名での推測は
# 利用者が自作した同名スクリプトを巻き込んで消しうるため、明示的な --guess を
# 与えたときだけ通す。「台帳ファイルが在る」ことを「記録が在る」と取り違えると、
# 記録ゼロの台帳で推測へ落ち、利用者のフックを消してしまう。
#
# 判定を install/uninstall で二重に実装しないため、双方がこれを呼ぶ。

import json
import os
import shlex
import sys

# 導入先から呼ばれる道具である。クローンに __pycache__ を書き散らさない。
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger  # noqa: E402  (同ディレクトリの小道具)

# 台帳が無いときに、自分のものと推測するフックスクリプトのファイル名。
OURS = {"handoff-check.sh", "suggest-session-cut.sh"}


def looks_like_ours(command):
    """台帳が無いときの推測。コマンド文字列に自分のスクリプトが現れるか見る。

    先頭トークンの basename だけでは取りこぼす:
      - 空白入りパスが非クォートで登録されている（旧版の登録）
      - `bash /path/handoff-check.sh` のようにインタプリタ経由
      - Windows のバックスラッシュ区切り
    分解の仕方を変えた候補すべてを見て、どれかで一致すれば自分のものとする。
    取りこぼすと「外した」と言いながら残り、毎セッション失敗し続けるため、
    取りこぼしより誤検出を選ぶ。誤検出の側は台帳で防ぐ。
    """
    text = str(command).replace("\\", "/")

    candidates = [text.split()]
    for posix in (True, False):
        try:
            candidates.append(shlex.split(text, posix=posix))
        except ValueError:
            pass

    for parts in candidates:
        for part in parts:
            if os.path.basename(part.strip("'\"")) in OURS:
                return True
    return False


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


def recorded_hooks(ledger_path):
    """台帳に記録された登録コマンドを返す。記録が無ければ None を返す。

    空リスト（「登録すべきフックが1つも無かった」という記録）と、記録そのものが
    無い状態を区別する。前者は「外すものは無い」で正しく、後者は推測しか
    残っていない状態であり、既定では何もしてはならない。
    """
    if not ledger_path or not ledger.has_record(ledger_path, "hooks"):
        return None
    return [
        h for h in ledger.get_list(ledger.load(ledger_path), "hooks") if isinstance(h, str)
    ]


def purge(data, known, guess=False):
    """自分のフック登録をすべて外し、外した件数を返す。

    known が None でなければ（＝台帳に記録が在れば）、それとの完全一致だけを
    外す。台帳がある以上、自分が書いていないものへ手を出す理由が無い。
    記録が無いときは、guess を明示されたときだけ推測へ落ちる。

    グループ単位ではなくフック単位で外す。matcher 付きのグループに利用者が
    自分のフックを同居させている場合、グループごと落とすとそれを巻き込む。
    """
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return 0

    def is_ours(entry):
        if not isinstance(entry, dict):
            return False
        command = entry.get("command", "")
        if known is not None:
            return str(command) in known
        return guess and looks_like_ours(command)

    removed = 0
    for event in list(hooks):
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue

        event_removed = 0
        kept_groups = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept_groups.append(group)
                continue
            inner = group["hooks"]
            kept = [h for h in inner if not is_ours(h)]
            event_removed += len(inner) - len(kept)
            # 中身が空になったグループは install.sh が作ったものなので落とす。
            if kept:
                group["hooks"] = kept
                kept_groups.append(group)

        removed += event_removed
        if kept_groups:
            hooks[event] = kept_groups
        elif event_removed:
            del hooks[event]
        # 元から空だったイベントは残す。明示的な空は利用者の設定意図である。

    if not hooks and removed:
        del data["hooks"]
    return removed


def save_if_changed(path, data, original):
    """内容が変わったときだけ書き戻す。

    テキストの一致ではなくデータの同値で判定する。正規形と違うだけで書くと、
    一度も導入していない利用者のファイルを取り外しのついでに再整形してしまう。
    """
    if original is not None:
        try:
            if json.loads(original.strip() or "{}") == data:
                return False
        except json.JSONDecodeError:
            pass
    new_text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    if new_text == original:
        return False
    ledger.write_atomic(path, new_text)
    return True


def cmd_install(path, ledger_path, specs):
    data, original = load(path)
    # install だけは、記録が無いときも推測で掃除する（guess=True）。
    # 掃除したうえで必ず入れ直すため、誤検出しても登録は残る（自分の綴りへ
    # 置き換わるだけである）。ここを fail-closed にすると、台帳の無い旧版から
    # 上げた環境で二重登録が永久に残る。
    # 消したまま戻さない uninstall 側は、同じ理由で fail-closed である。
    removed = purge(data, recorded_hooks(ledger_path), guess=True)

    added = []
    commands = []
    hooks = data.setdefault("hooks", {})
    for spec in specs:
        event, command = spec.split(":", 1)
        # 空白を含むパスをそのまま入れると、シェルが単語分割して毎セッション
        # rc=127 で失敗する。クォートしてから登録する。
        quoted = shlex.quote(command)
        hooks.setdefault(event, []).append(
            {"hooks": [{"type": "command", "command": quoted}]}
        )
        commands.append(quoted)
        added.append("%s → %s" % (event, os.path.basename(command)))

    # 台帳には、登録した文字列そのものを残す。次回の同定を推測に頼らせない。
    if ledger_path:
        led = ledger.load(ledger_path)
        led["hooks"] = commands
        try:
            ledger.save(ledger_path, led)
        except OSError as e:
            # 台帳が書けないなら、次回の取り外しは推測しか残らない。
            # 設定だけ書いて先へ進めるのは、取り外せない状態を作ることである。
            sys.stderr.write("台帳を書けない (%s): %s\n" % (ledger_path, e))
            return 1

    if not save_if_changed(path, data, original):
        print("  フックは既に登録済み")
        return 0

    for line in added:
        print("  フックを登録した: %s" % line)
    stale = removed - len(added)
    if stale > 0:
        print("  古い・重複したフックの登録を %d 件整理した" % stale)
    return 0


def cmd_remove(path, ledger_path, guess=False):
    if not os.path.exists(path):
        print("  settings.local.json が無い")
        return 0
    # 壊れた JSON はここで落とす。fail-closed の判定より先に読むのは、
    # 「記録が無いから何もしない」で壊れたファイルを見逃さないためである。
    data, original = load(path)
    known = recorded_hooks(ledger_path)
    if known is None and not guess:
        sys.stderr.write(
            "  警告: 台帳にフックの記録が無いため settings.local.json を変更しない。\n"
            "        どれが自分の登録か分からない状態で消すと、利用者のフックを\n"
            "        巻き込む。台帳の無い旧版で導入した環境では --guess を付けて\n"
            "        実行せよ（ファイル名で推測する）。\n"
        )
        return 2
    removed = purge(data, known, guess=guess)
    # 1件も外していないなら書かない。書けば利用者の書式を黙って変えてしまう。
    if removed:
        save_if_changed(path, data, original)
    print("  フックの登録を %d 件外した" % removed)
    return 0


def cmd_same(path, other):
    """2つの設定ファイルがデータとして同値なら 0 を返す。

    uninstall.sh が「控えと原状が同じか」を判断するために使う。書式の違いで
    残す判断をすると、控えが永久に片付かない。
    """
    def read(p):
        if not os.path.exists(p):
            return {}
        try:
            with open(p, encoding="utf-8") as f:
                text = f.read().strip()
            return json.loads(text) if text else {}
        except (OSError, ValueError):
            return None

    a, b = read(path), read(other)
    return 0 if a is not None and a == b else 1


def main(argv):
    if len(argv) >= 4 and argv[1] == "same":
        return cmd_same(argv[2], argv[3])
    if len(argv) < 3 or argv[1] not in ("install", "remove"):
        sys.stderr.write(
            "usage: settings-hooks.py {install|remove} <path> "
            "[--ledger <ledger>] [--guess] [event:command ...]\n"
        )
        return 64

    rest = argv[3:]
    ledger_path = ""
    if rest and rest[0] == "--ledger":
        if len(rest) < 2:
            sys.stderr.write("--ledger には台帳のパスが要る\n")
            return 64
        ledger_path = rest[1]
        rest = rest[2:]
    guess = False
    if rest and rest[0] == "--guess":
        guess = True
        rest = rest[1:]

    if argv[1] == "install":
        return cmd_install(argv[2], ledger_path, rest)
    return cmd_remove(argv[2], ledger_path, guess)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except OSError as e:
        # 書き込めない・読めない環境で python のトレースバックを生で見せない。
        # 利用者にとっては「何が起きたか」だけが要る情報である。
        sys.stderr.write("ファイルを操作できない (%s)\n" % e)
        sys.exit(1)
